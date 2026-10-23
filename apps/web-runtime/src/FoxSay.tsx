import { useCallback, useEffect, useMemo, useRef, useState } from "react";

type SaySessionState = "idle" | "listening" | "speech_detected" | "transcribing" | "speaking" | "cooldown";
type CorpusBucket = "short_command" | "training_feedback" | "equipment_context" | "mixed_utterance" | "noise_distance";
type VoiceEntryType = "meal" | "medical" | "workout" | "expense" | "note";
type SayView = "record" | "test" | "inbox";
type FlowStepStatus = "waiting" | "active" | "done" | "blocked";

interface SayCapture {
  id: string;
  contentType: string;
  bytes: number;
  sha256: string;
  audioPathShape: string;
  capturedAt: string;
}

interface SayCorpusSample {
  sampleId: string;
  bucket: CorpusBucket;
  expectedText: string;
  captureId: string;
  audioPath: string;
  bytes: number;
  sha256: string;
  device: string;
  environment: string;
  noiseNotes: string;
  speakerProfile: string;
  createdAt: string;
  rawAudioCommitted: boolean;
}

interface SayAsrResult {
  schema: "fox.say_asr_result.v0";
  id: string;
  captureId: string;
  provider: string;
  transcript: string;
  language?: string;
  confidence?: number;
  rawAudioCommitted: boolean;
}

interface SayAsrJob {
  schema: "fox.say_asr_job.v0";
  id: string;
  captureId: string;
  status: "queued" | "running" | "succeeded" | "failed";
  asrResultId?: string;
  errorCode?: string;
  errorMessage?: string;
}

interface SayMacInputJob {
  schema: "fox.say_mac_input_job.v0";
  id: string;
  asrResultId: string;
  captureId: string;
  target: "clipboard";
  status: "queued" | "claimed" | "completed" | "failed";
  textCharacters: number;
  errorCode?: string;
  errorMessage?: string;
}

interface VoiceDraft {
  schema: "fox.voice_draft.v0";
  id: string;
  asrResultId: string;
  captureId: string;
  entryType: VoiceEntryType;
  title: string;
  status: "needs_review" | "confirmed" | "discarded";
  rawText: string;
  extractedJson: Record<string, unknown>;
  extractionConfidence: number;
  confirmedEntryId?: string;
}

interface ConfirmedVoiceEntry {
  id: string;
  kind: VoiceEntryType;
  title: string;
  status: "confirmed";
  rawText: string;
  confirmedJson: Record<string, unknown>;
}

interface TestSeedSummary {
  captureId: string;
  asrResultIds: string[];
  draftIds: string[];
}

interface BrowserSpeechRecognitionAlternative {
  transcript: string;
}

interface BrowserSpeechRecognitionResult {
  isFinal?: boolean;
  [index: number]: BrowserSpeechRecognitionAlternative | undefined;
}

interface BrowserSpeechRecognitionEvent {
  resultIndex: number;
  results: ArrayLike<BrowserSpeechRecognitionResult>;
}

interface BrowserSpeechRecognition {
  lang: string;
  continuous: boolean;
  interimResults: boolean;
  onresult: ((event: BrowserSpeechRecognitionEvent) => void) | null;
  onerror: (() => void) | null;
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
}

interface SpeechRecognitionWindow extends Window {
  SpeechRecognition?: new () => BrowserSpeechRecognition;
  webkitSpeechRecognition?: new () => BrowserSpeechRecognition;
}

interface NativeCaptureResult {
  ok: boolean;
  event: "started" | "uploaded" | "error";
  backend?: "ios_native";
  error?: string;
  errorMessage?: string;
  error_message?: string;
  errorDomain?: string;
  errorCode?: number;
  context?: string;
  statusCode?: number;
  payload?: {
    capture?: SayCapture;
    error?: string;
  };
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        foxPadAudioCapture?: {
          postMessage: (message: unknown) => void;
        };
      };
    };
    __foxPadAudioCaptureResult?: (result: NativeCaptureResult) => void;
  }
}

const defaultText = "完成，休息九十秒。下一组开始前我会提醒你。";
const reminderMs = 10_000;
const silenceTimeoutMs = 20_000;
const apiBaseUrl = import.meta.env.VITE_FOX_API_URL ?? `${window.location.protocol}//${window.location.hostname}:4177`;
const corpusBuckets: Array<{ value: CorpusBucket; label: string }> = [
  { value: "short_command", label: "短命令" },
  { value: "training_feedback", label: "训练反馈" },
  { value: "equipment_context", label: "器材/上下文" },
  { value: "mixed_utterance", label: "混合输入" },
  { value: "noise_distance", label: "噪声/距离" }
];
const voiceEntryTypes: Array<{ value: VoiceEntryType; label: string }> = [
  { value: "note", label: "笔记" },
  { value: "workout", label: "健身" },
  { value: "meal", label: "饮食" },
  { value: "expense", label: "记账" },
  { value: "medical", label: "医疗" }
];
const sayViews: Array<{ value: SayView; label: string }> = [
  { value: "record", label: "日常记录" },
  { value: "test", label: "测试链路" },
  { value: "inbox", label: "收件箱" }
];

function speechRecognitionCtor() {
  return (window as SpeechRecognitionWindow).SpeechRecognition ?? (window as SpeechRecognitionWindow).webkitSpeechRecognition;
}

function formatSeconds(ms: number): string {
  return `${Math.max(0, Math.ceil(ms / 1000))}s`;
}

function selectMandarinVoice(voices: SpeechSynthesisVoice[]): SpeechSynthesisVoice | undefined {
  const normalized = voices.map((voice) => ({
    voice,
    name: voice.name.toLowerCase(),
    lang: voice.lang.toLowerCase()
  }));
  return (
    normalized.find(({ lang }) => lang === "zh-cn" || lang === "zh_hans")?.voice ??
    normalized.find(({ name, lang }) => lang.startsWith("zh") && (name.includes("ting") || name.includes("sinji") || name.includes("mei-jia") || name.includes("xiaoxiao")))?.voice ??
    normalized.find(({ lang }) => lang.startsWith("zh"))?.voice
  );
}

function formatDraftJson(value: Record<string, unknown>): string {
  return JSON.stringify(value, null, 2);
}

function parseDraftJson(text: string): Record<string, unknown> {
  const parsed = JSON.parse(text);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("draft_json_must_be_object");
  }
  return parsed as Record<string, unknown>;
}

function initialDraftNote(draft: VoiceDraft): string {
  const notes = draft.extractedJson.notes;
  const doctorNotes = draft.extractedJson.doctor_notes;
  if (typeof notes === "string") {
    return notes;
  }
  if (typeof doctorNotes === "string") {
    return doctorNotes;
  }
  return draft.rawText;
}

function flowStatusLabel(status: FlowStepStatus): string {
  if (status === "done") {
    return "完成";
  }
  if (status === "active") {
    return "进行中";
  }
  if (status === "blocked") {
    return "等待";
  }
  return "未开始";
}

function nativeCaptureErrorLabel(result: NativeCaptureResult): string {
  const diagnosticParts = [
    result.error ?? result.payload?.error ?? "native_capture_failed",
    result.errorMessage ?? result.error_message,
    result.errorDomain && result.errorCode !== undefined ? `${result.errorDomain}#${result.errorCode}` : result.errorDomain,
    result.statusCode !== undefined ? `http ${result.statusCode}` : "",
    result.context ? `context ${result.context}` : ""
  ].filter(Boolean);
  return diagnosticParts.join(" · ");
}

export function FoxSay() {
  const [activeView, setActiveView] = useState<SayView>("record");
  const [text, setText] = useState(defaultText);
  const [sessionState, setSessionState] = useState<SaySessionState>("idle");
  const [finalTranscript, setFinalTranscript] = useState("");
  const [interimTranscript, setInterimTranscript] = useState("");
  const [lastHeardAt, setLastHeardAt] = useState<number | null>(null);
  const [reminderIssued, setReminderIssued] = useState(false);
  const [firstAudioMs, setFirstAudioMs] = useState<number | null>(null);
  const [statusNote, setStatusNote] = useState("准备就绪。");
  const [now, setNow] = useState(Date.now());
  const [capture, setCapture] = useState<SayCapture | null>(null);
  const [corpusBucket, setCorpusBucket] = useState<CorpusBucket>("short_command");
  const [expectedText, setExpectedText] = useState("");
  const [environment, setEnvironment] = useState("quiet_room");
  const [noiseNotes, setNoiseNotes] = useState("");
  const [speakerProfile, setSpeakerProfile] = useState("owner");
  const [corpusSamples, setCorpusSamples] = useState<SayCorpusSample[]>([]);
  const [savedSample, setSavedSample] = useState<SayCorpusSample | null>(null);
  const [savingSample, setSavingSample] = useState(false);
  const [asrResult, setAsrResult] = useState<SayAsrResult | null>(null);
  const [asrJob, setAsrJob] = useState<SayAsrJob | null>(null);
  const [macInputJob, setMacInputJob] = useState<SayMacInputJob | null>(null);
  const [voiceDrafts, setVoiceDrafts] = useState<VoiceDraft[]>([]);
  const [voiceDraft, setVoiceDraft] = useState<VoiceDraft | null>(null);
  const [selectedDraftId, setSelectedDraftId] = useState("");
  const [draftFilter, setDraftFilter] = useState<"needs_review" | "all">("needs_review");
  const [draftEntryType, setDraftEntryType] = useState<VoiceEntryType>("note");
  const [draftTitle, setDraftTitle] = useState("");
  const [draftJsonText, setDraftJsonText] = useState("{}");
  const [draftJsonError, setDraftJsonError] = useState("");
  const [confirmedEntry, setConfirmedEntry] = useState<ConfirmedVoiceEntry | null>(null);
  const [confirmNotes, setConfirmNotes] = useState("");
  const [asrRunning, setAsrRunning] = useState(false);
  const [draftBusy, setDraftBusy] = useState(false);
  const [testBusy, setTestBusy] = useState(false);
  const [testSeedSummary, setTestSeedSummary] = useState<TestSeedSummary | null>(null);
  const [captureStarting, setCaptureStarting] = useState(false);
  const [recording, setRecording] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [voices, setVoices] = useState<SpeechSynthesisVoice[]>([]);
  const recognitionRef = useRef<BrowserSpeechRecognition | null>(null);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const recorderStreamRef = useRef<MediaStream | null>(null);
  const recorderChunksRef = useRef<Blob[]>([]);
  const nativeRecorderActiveRef = useRef(false);
  const speakStartedAt = useRef<number | null>(null);
  const recognitionSupported = Boolean(speechRecognitionCtor());
  const speechSupported = "speechSynthesis" in window;
  const browserRecorderSupported = "mediaDevices" in navigator && "MediaRecorder" in window;
  const nativeRecorderSupported = Boolean(window.webkit?.messageHandlers?.foxPadAudioCapture);
  const recorderSupported = browserRecorderSupported || nativeRecorderSupported;
  const idleForMs = lastHeardAt ? now - lastHeardAt : 0;
  const shouldShowReminder = sessionState === "listening" || sessionState === "speech_detected" || sessionState === "transcribing";
  useEffect(() => {
    const interval = window.setInterval(() => setNow(Date.now()), 250);
    return () => window.clearInterval(interval);
  }, []);

  useEffect(() => {
    if (!speechSupported) {
      return;
    }
    const updateVoices = () => setVoices(window.speechSynthesis.getVoices());
    updateVoices();
    window.speechSynthesis.addEventListener("voiceschanged", updateVoices);
    return () => window.speechSynthesis.removeEventListener("voiceschanged", updateVoices);
  }, [speechSupported]);

  const loadCorpusSamples = useCallback(async () => {
    try {
      const response = await fetch(`${apiBaseUrl}/say/corpus-samples`);
      if (!response.ok) {
        return;
      }
      const payload = (await response.json()) as { samples?: SayCorpusSample[] };
      setCorpusSamples(payload.samples ?? []);
    } catch {
      // Corpus mode remains usable even if listing fails.
    }
  }, []);

  useEffect(() => {
    void loadCorpusSamples();
  }, [loadCorpusSamples]);

  const applyVoiceDraft = useCallback((draft: VoiceDraft) => {
    setVoiceDraft(draft);
    setSelectedDraftId(draft.id);
    setDraftEntryType(draft.entryType);
    setDraftTitle(draft.title);
    setDraftJsonText(formatDraftJson(draft.extractedJson));
    setDraftJsonError("");
    setConfirmNotes(initialDraftNote(draft));
    setConfirmedEntry(null);
  }, []);

  const loadVoiceDrafts = useCallback(
    async (preferredDraftId?: string) => {
      try {
        const response = await fetch(`${apiBaseUrl}/say/drafts`);
        if (!response.ok) {
          throw new Error("voice_drafts_not_found");
        }
        const payload = (await response.json()) as { drafts?: VoiceDraft[] };
        const drafts = payload.drafts ?? [];
        setVoiceDrafts(drafts);
        const preferredDraft =
          (preferredDraftId ? drafts.find((draft) => draft.id === preferredDraftId) : null) ??
          drafts.find((draft) => draft.status === "needs_review") ??
          drafts[0];
        if (preferredDraft) {
          applyVoiceDraft(preferredDraft);
        } else {
          setVoiceDraft(null);
          setSelectedDraftId("");
          setDraftTitle("");
          setDraftJsonText("{}");
          setConfirmNotes("");
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : "voice_drafts_not_found";
        setStatusNote(`读取草稿收件箱失败：${message}`);
      }
    },
    [applyVoiceDraft]
  );

  useEffect(() => {
    void loadVoiceDrafts();
  }, [loadVoiceDrafts]);

  const prepareCorpusDraft = useCallback((uploadedCapture: SayCapture) => {
    setCapture(uploadedCapture);
    setSavedSample(null);
    const transcript = finalTranscript.trim();
    setExpectedText((current) => current.trim() || transcript);
  }, [finalTranscript]);

  const applyAsrResult = useCallback((result: SayAsrResult) => {
    setAsrResult(result);
    setVoiceDraft(null);
    setSelectedDraftId("");
    setConfirmedEntry(null);
    setMacInputJob(null);
    setConfirmNotes(result.transcript);
    setDraftTitle("");
    setDraftJsonText("{}");
    setDraftJsonError("");
  }, []);

  const refreshAsrJob = useCallback(
    async (jobId: string, expectedCaptureId: string) => {
      const response = await fetch(`${apiBaseUrl}/say/asr-jobs/${encodeURIComponent(jobId)}`);
      const payload = (await response.json()) as { job?: SayAsrJob; asrResult?: SayAsrResult; error?: string };
      if (!response.ok || !payload.job) {
        throw new Error(payload.error ?? "asr_job_not_found");
      }
      if (payload.job.captureId !== expectedCaptureId) {
        throw new Error("asr_job_capture_mismatch");
      }
      setAsrJob(payload.job);
      if (payload.job.status === "succeeded") {
        setAsrRunning(false);
        if (!payload.asrResult || payload.asrResult.captureId !== expectedCaptureId) {
          throw new Error("asr_result_capture_mismatch");
        }
        applyAsrResult(payload.asrResult);
        setStatusNote("当前录音 ASR 已完成。");
      } else if (payload.job.status === "failed") {
        setAsrRunning(false);
        setStatusNote(`当前录音 ASR 失败：${payload.job.errorMessage ?? payload.job.errorCode ?? "unknown"}`);
      } else {
        setAsrRunning(true);
      }
      return payload.job;
    },
    [applyAsrResult]
  );

  const restoreAsrJobForCapture = useCallback(
    async (targetCapture: SayCapture) => {
      const response = await fetch(`${apiBaseUrl}/say/asr-jobs?captureId=${encodeURIComponent(targetCapture.id)}`);
      const payload = (await response.json()) as { jobs?: SayAsrJob[]; error?: string };
      if (!response.ok) {
        throw new Error(payload.error ?? "asr_jobs_not_found");
      }
      const job = (payload.jobs ?? []).find((candidate) => candidate.status === "queued" || candidate.status === "running") ?? payload.jobs?.[0];
      if (!job) {
        return false;
      }
      if (job.captureId !== targetCapture.id) {
        throw new Error("asr_job_capture_mismatch");
      }
      setAsrJob(job);
      if (job.status === "succeeded") {
        await refreshAsrJob(job.id, targetCapture.id);
      } else if (job.status === "failed") {
        setAsrRunning(false);
        setStatusNote(`已恢复失败的 ASR job：${job.errorMessage ?? job.errorCode ?? "unknown"}`);
      } else {
        setAsrRunning(true);
        setStatusNote("已恢复当前录音的 Linux ASR job。");
      }
      return true;
    },
    [refreshAsrJob]
  );

  const queueCurrentCaptureAsr = useCallback(
    async (targetCapture: SayCapture | null = capture) => {
      if (!targetCapture) {
        setStatusNote("请先完成录音，或读取最近录音。");
        return;
      }
      setAsrResult(null);
      setMacInputJob(null);
      setAsrRunning(true);
      try {
        const response = await fetch(`${apiBaseUrl}/say/asr-jobs`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ captureId: targetCapture.id })
        });
        const payload = (await response.json()) as { job?: SayAsrJob; reused?: boolean; error?: string };
        if (!response.ok || !payload.job) {
          throw new Error(payload.error ?? "asr_job_enqueue_failed");
        }
        if (payload.job.captureId !== targetCapture.id) {
          throw new Error("asr_job_capture_mismatch");
        }
        setAsrJob(payload.job);
        setStatusNote(payload.reused ? "当前录音已在 Linux ASR 队列中。" : "录音已上传，Linux ASR 正在处理。");
        if (payload.job.status === "succeeded") {
          await refreshAsrJob(payload.job.id, targetCapture.id);
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : "asr_job_enqueue_failed";
        setAsrRunning(false);
        setStatusNote(`提交当前录音 ASR 失败：${message}`);
      }
    },
    [capture, refreshAsrJob]
  );

  useEffect(() => {
    if (!asrJob || !capture || asrJob.captureId !== capture.id || (asrJob.status !== "queued" && asrJob.status !== "running")) {
      return;
    }
    let cancelled = false;
    const poll = async () => {
      try {
        if (!cancelled) {
          await refreshAsrJob(asrJob.id, capture.id);
        }
      } catch (error) {
        if (!cancelled) {
          const message = error instanceof Error ? error.message : "asr_job_poll_failed";
          setAsrRunning(false);
          setStatusNote(`读取 ASR job 状态失败：${message}`);
        }
      }
    };
    void poll();
    const interval = window.setInterval(() => void poll(), 1_000);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [asrJob?.id, asrJob?.status, capture?.id, refreshAsrJob]);

  const loadLatestCapture = useCallback(async () => {
    try {
      const response = await fetch(`${apiBaseUrl}/say/captures/latest`);
      const payload = (await response.json()) as { capture?: SayCapture; error?: string };
      if (!response.ok || !payload.capture) {
        throw new Error(payload.error ?? "capture_not_found");
      }
      prepareCorpusDraft(payload.capture);
      setAsrResult(null);
      setAsrJob(null);
      setAsrRunning(false);
      setMacInputJob(null);
      const restored = await restoreAsrJobForCapture(payload.capture);
      if (!restored) {
        setStatusNote("已载入最近录音。可以开始识别，或读取已有 ASR 结果。");
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : "capture_not_found";
      setStatusNote(`读取最近录音失败：${message}`);
    }
  }, [prepareCorpusDraft, restoreAsrJobForCapture]);

  useEffect(() => {
    window.__foxPadAudioCaptureResult = (result) => {
      if (result.event === "started" && result.ok) {
        nativeRecorderActiveRef.current = true;
        setCaptureStarting(false);
        setRecording(true);
        setUploading(false);
        setStatusNote("正在通过 iPad 原生录音桥录音。");
        return;
      }
      if (result.event === "uploaded" && result.ok) {
        nativeRecorderActiveRef.current = false;
        setCaptureStarting(false);
        setRecording(false);
        setUploading(false);
        const uploadedCapture = result.payload?.capture;
        if (uploadedCapture) {
          prepareCorpusDraft(uploadedCapture);
          setAsrResult(null);
          setAsrJob(null);
          setMacInputJob(null);
          setStatusNote("iPad 原生录音已上传，正在提交 Linux ASR。");
          void queueCurrentCaptureAsr(uploadedCapture);
        } else {
          setStatusNote("iPad 原生录音已上传，但返回结果缺少 capture metadata。");
        }
        return;
      }
      nativeRecorderActiveRef.current = false;
      setCaptureStarting(false);
      setRecording(false);
      setUploading(false);
      setStatusNote(`iPad 原生录音失败：${nativeCaptureErrorLabel(result)}`);
    };
    return () => {
      delete window.__foxPadAudioCaptureResult;
    };
  }, [prepareCorpusDraft, queueCurrentCaptureAsr]);

  useEffect(() => {
    if (!shouldShowReminder || !lastHeardAt || reminderIssued || idleForMs < reminderMs) {
      return;
    }
    setReminderIssued(true);
    setStatusNote("我在听。");
  }, [idleForMs, lastHeardAt, reminderIssued, shouldShowReminder]);

  useEffect(() => {
    if (!shouldShowReminder || !lastHeardAt || idleForMs < silenceTimeoutMs) {
      return;
    }
    recognitionRef.current?.stop();
    recognitionRef.current = null;
    setSessionState("cooldown");
    setStatusNote("20 秒无人声，已自动结束本轮收听。");
  }, [idleForMs, lastHeardAt, shouldShowReminder]);

  const stopListening = useCallback(() => {
    recognitionRef.current?.stop();
    recognitionRef.current = null;
    setSessionState("idle");
    setStatusNote("已停止收听。");
  }, []);

  const startListening = useCallback(() => {
    const SpeechRecognition = speechRecognitionCtor();
    if (!SpeechRecognition) {
      setStatusNote("当前浏览器不支持语音识别。iPad WKWebView 可能需要后续原生桥接。");
      return;
    }
    recognitionRef.current?.stop();
    const recognition = new SpeechRecognition();
    recognition.lang = "zh-CN";
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.onresult = (event) => {
      let interim = "";
      let final = "";
      for (let index = event.resultIndex; index < event.results.length; index += 1) {
        const result = event.results[index];
        const transcript = typeof result?.[0] === "object" ? result[0]?.transcript ?? "" : "";
        if (result?.isFinal) {
          final += transcript;
        } else {
          interim += transcript;
        }
      }
      if (interim || final) {
        setLastHeardAt(Date.now());
        setReminderIssued(false);
        setSessionState(final ? "transcribing" : "speech_detected");
      }
      if (interim) {
        setInterimTranscript(interim);
      }
      if (final) {
        setFinalTranscript((current) => `${current}${current ? "\n" : ""}${final.trim()}`);
        setInterimTranscript("");
        setStatusNote("已写入一段识别结果。");
      }
    };
    recognition.onerror = () => {
      setStatusNote("语音识别出现错误，已保留当前文本。");
      setSessionState("cooldown");
    };
    recognition.onend = () => {
      if (recognitionRef.current === recognition) {
        recognitionRef.current = null;
        setSessionState("idle");
      }
    };
    try {
      recognition.start();
      recognitionRef.current = recognition;
      setLastHeardAt(Date.now());
      setReminderIssued(false);
      setSessionState("listening");
      setStatusNote("正在收听。");
    } catch {
      recognitionRef.current = null;
      setSessionState("idle");
      setStatusNote("浏览器拒绝启动语音识别。");
    }
  }, []);

  const speak = useCallback(() => {
    if (!speechSupported) {
      setStatusNote("当前浏览器不支持文字转语音。");
      return;
    }
    const trimmed = text.trim();
    if (!trimmed) {
      setStatusNote("请输入要朗读的内容。");
      return;
    }
    window.speechSynthesis.cancel();
    const utterance = new SpeechSynthesisUtterance(trimmed);
    utterance.lang = "zh-CN";
    const preferredVoice = selectMandarinVoice(voices);
    if (preferredVoice) {
      utterance.voice = preferredVoice;
    }
    utterance.rate = 0.96;
    utterance.pitch = 1;
    speakStartedAt.current = performance.now();
    setSessionState("speaking");
    setStatusNote("正在朗读。");
    utterance.onstart = () => {
      if (speakStartedAt.current !== null) {
        setFirstAudioMs(Math.max(1, Math.round(performance.now() - speakStartedAt.current)));
      }
    };
    utterance.onend = () => {
      setSessionState("idle");
      setStatusNote("朗读完成。");
    };
    utterance.onerror = () => {
      setSessionState("idle");
      setStatusNote("朗读失败。");
    };
    window.speechSynthesis.speak(utterance);
  }, [speechSupported, text, voices]);

  const clearTranscript = useCallback(() => {
    setFinalTranscript("");
    setInterimTranscript("");
    setStatusNote("识别文本已清空。");
  }, []);

  const cleanupRecorder = useCallback(() => {
    recorderRef.current = null;
    recorderStreamRef.current?.getTracks().forEach((track) => track.stop());
    recorderStreamRef.current = null;
    recorderChunksRef.current = [];
    setRecording(false);
  }, []);

  const uploadCapture = useCallback(async (blob: Blob) => {
    setUploading(true);
    try {
      const response = await fetch(`${apiBaseUrl}/say/capture`, {
        method: "POST",
        headers: {
          "content-type": blob.type || "audio/webm",
          "x-fox-say-source": "fox-say-ipad-preview"
        },
        body: blob
      });
      const payload = (await response.json()) as { capture?: SayCapture; error?: string };
      if (!response.ok || !payload.capture) {
        throw new Error(payload.error ?? "capture_upload_failed");
      }
      prepareCorpusDraft(payload.capture);
      setAsrResult(null);
      setAsrJob(null);
      setMacInputJob(null);
      setStatusNote("录音已上传，正在提交 Linux ASR。");
      await queueCurrentCaptureAsr(payload.capture);
    } catch (error) {
      const message = error instanceof Error ? error.message : "capture_upload_failed";
      setStatusNote(`停止并上传失败：${message}`);
    } finally {
      setUploading(false);
    }
  }, [prepareCorpusDraft, queueCurrentCaptureAsr]);

  const startCapture = useCallback(async () => {
    if (!recorderSupported) {
      setStatusNote("当前浏览器不支持麦克风录音。");
      return;
    }
    setSavedSample(null);
    setAsrResult(null);
    setAsrJob(null);
    setMacInputJob(null);
    setAsrRunning(false);
    setVoiceDraft(null);
    setSelectedDraftId("");
    setConfirmedEntry(null);
    if (nativeRecorderSupported) {
      try {
        setCapture(null);
        setCaptureStarting(true);
        setUploading(false);
        setRecording(false);
        nativeRecorderActiveRef.current = false;
        setStatusNote("正在请求 iPad 麦克风权限。");
        window.webkit?.messageHandlers?.foxPadAudioCapture?.postMessage({
          action: "start",
          uploadUrl: `${apiBaseUrl}/say/capture`
        });
      } catch (error) {
        nativeRecorderActiveRef.current = false;
        setCaptureStarting(false);
        setRecording(false);
        const message = error instanceof Error ? error.message : "native_capture_bridge_start_exception";
        setStatusNote(`iPad 原生录音桥启动失败：${message}`);
      }
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const recorder = new MediaRecorder(stream);
      recorderStreamRef.current = stream;
      recorderRef.current = recorder;
      recorderChunksRef.current = [];
      recorder.ondataavailable = (event) => {
        if (event.data.size > 0) {
          recorderChunksRef.current.push(event.data);
        }
      };
      recorder.onstop = () => {
        const chunks = recorderChunksRef.current;
        const contentType = chunks[0]?.type || "audio/webm";
        const blob = new Blob(chunks, { type: contentType });
        cleanupRecorder();
        if (blob.size === 0) {
          setStatusNote("录音为空，未上传。");
          return;
        }
        void uploadCapture(blob);
      };
      recorder.start();
      setCapture(null);
      setRecording(true);
      setStatusNote("正在录音，结束后会上传到 Fox API。");
    } catch {
      cleanupRecorder();
      setStatusNote("麦克风授权或录音启动失败。");
    }
  }, [browserRecorderSupported, cleanupRecorder, nativeRecorderSupported, recorderSupported, uploadCapture]);

  const saveCorpusSample = useCallback(async () => {
    if (!capture) {
      setStatusNote("请先完成一段录音。");
      return;
    }
    if (!expectedText.trim()) {
      setStatusNote("请填写 expected text；这是之后评测 ASR 的标准答案。");
      return;
    }
    setSavingSample(true);
    try {
      const response = await fetch(`${apiBaseUrl}/say/corpus-samples`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          captureId: capture.id,
          bucket: corpusBucket,
          expectedText: expectedText.trim(),
          device: "iPad",
          environment: environment.trim() || "unknown",
          noiseNotes: noiseNotes.trim(),
          speakerProfile: speakerProfile.trim() || "owner"
        })
      });
      const payload = (await response.json()) as { sample?: SayCorpusSample; error?: string };
      if (!response.ok || !payload.sample) {
        throw new Error(payload.error ?? "corpus_sample_failed");
      }
      setSavedSample(payload.sample);
      setStatusNote(`语料样本已保存：${payload.sample.sampleId}`);
      await loadCorpusSamples();
    } catch (error) {
      const message = error instanceof Error ? error.message : "corpus_sample_failed";
      setStatusNote(`语料样本保存失败：${message}`);
    } finally {
      setSavingSample(false);
    }
  }, [capture, corpusBucket, environment, expectedText, loadCorpusSamples, noiseNotes, speakerProfile]);

  const loadLatestAsrResult = useCallback(async () => {
    if (!capture) {
      setStatusNote("请先完成录音，或读取最近录音。");
      return;
    }
    try {
      const response = await fetch(`${apiBaseUrl}/say/asr-results/latest?captureId=${encodeURIComponent(capture.id)}`);
      const payload = (await response.json()) as { asrResult?: SayAsrResult; error?: string };
      if (!response.ok || !payload.asrResult) {
        throw new Error(payload.error ?? "asr_result_not_found");
      }
      if (payload.asrResult.captureId !== capture.id) {
        throw new Error("asr_result_capture_mismatch");
      }
      applyAsrResult(payload.asrResult);
      setAsrRunning(false);
      setStatusNote("已读取当前录音的 Linux ASR 结果。");
    } catch (error) {
      const message = error instanceof Error ? error.message : "asr_result_not_found";
      setStatusNote(`读取当前录音 ASR 失败：${message}。录音刚上传时，等待 job 完成或点击识别当前录音。`);
    }
  }, [applyAsrResult, capture]);

  const runCurrentCaptureAsr = useCallback(async () => {
    await queueCurrentCaptureAsr();
  }, [queueCurrentCaptureAsr]);

  const createVoiceDraft = useCallback(async () => {
    if (!asrResult) {
      setStatusNote("请先读取 Linux ASR 结果。");
      return;
    }
    setDraftBusy(true);
    try {
      const response = await fetch(`${apiBaseUrl}/say/drafts`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ asrResultId: asrResult.id })
      });
      const payload = (await response.json()) as { draft?: VoiceDraft; error?: string };
      if (!response.ok || !payload.draft) {
        throw new Error(payload.error ?? "voice_draft_failed");
      }
      applyVoiceDraft(payload.draft);
      await loadVoiceDrafts(payload.draft.id);
      setActiveView("inbox");
      setStatusNote("已生成待确认 Fox 草稿。");
    } catch (error) {
      const message = error instanceof Error ? error.message : "voice_draft_failed";
      setStatusNote(`生成草稿失败：${message}`);
    } finally {
      setDraftBusy(false);
    }
  }, [applyVoiceDraft, asrResult, loadVoiceDrafts]);

  const refreshMacInputJob = useCallback(async (jobId: string, asrResultId: string) => {
    const response = await fetch(`${apiBaseUrl}/say/mac-input-jobs?asrResultId=${encodeURIComponent(asrResultId)}`);
    const payload = (await response.json()) as { jobs?: SayMacInputJob[]; error?: string };
    if (!response.ok) {
      throw new Error(payload.error ?? "mac_input_jobs_not_found");
    }
    const job = (payload.jobs ?? []).find((candidate) => candidate.id === jobId);
    if (!job) {
      throw new Error("mac_input_job_not_found");
    }
    setMacInputJob(job);
    return job;
  }, []);

  const queueMacInput = useCallback(async () => {
    if (!asrResult) {
      setStatusNote("请先获得当前录音的 ASR 文本。");
      return;
    }
    try {
      const response = await fetch(`${apiBaseUrl}/say/asr-results/${encodeURIComponent(asrResult.id)}/mac-input-jobs`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ target: "clipboard" })
      });
      const payload = (await response.json()) as { job?: SayMacInputJob; reused?: boolean; error?: string };
      if (!response.ok || !payload.job) {
        throw new Error(payload.error ?? "mac_input_job_enqueue_failed");
      }
      if (payload.job.asrResultId !== asrResult.id || payload.job.captureId !== asrResult.captureId) {
        throw new Error("mac_input_job_binding_mismatch");
      }
      setMacInputJob(payload.job);
      setStatusNote(payload.reused ? "这条文本已经在等待 Mac bridge。" : "已发送到 Mac 剪贴板队列，等待本机 bridge。完成后到目标 App 按 Command-V。");
    } catch (error) {
      const message = error instanceof Error ? error.message : "mac_input_job_enqueue_failed";
      setStatusNote(`发送到 Mac 失败：${message}`);
    }
  }, [asrResult]);

  useEffect(() => {
    if (!macInputJob || !asrResult || macInputJob.asrResultId !== asrResult.id || (macInputJob.status !== "queued" && macInputJob.status !== "claimed")) {
      return;
    }
    let cancelled = false;
    const poll = async () => {
      try {
        if (!cancelled) {
          await refreshMacInputJob(macInputJob.id, asrResult.id);
        }
      } catch (error) {
        if (!cancelled) {
          const message = error instanceof Error ? error.message : "mac_input_job_poll_failed";
          setStatusNote(`读取 Mac bridge 状态失败：${message}`);
        }
      }
    };
    void poll();
    const interval = window.setInterval(() => void poll(), 750);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [asrResult?.id, macInputJob?.id, macInputJob?.status, refreshMacInputJob]);

  const seedTestDrafts = useCallback(async () => {
    setTestBusy(true);
    try {
      const captureResponse = await fetch(`${apiBaseUrl}/say/capture`, {
        method: "POST",
        headers: {
          "content-type": "audio/mp4",
          "x-fox-say-source": "fox-say-guided-test"
        },
        body: new Blob([`fox-say-guided-test-${Date.now()}`], { type: "audio/mp4" })
      });
      const capturePayload = (await captureResponse.json()) as { capture?: SayCapture; error?: string };
      if (!captureResponse.ok || !capturePayload.capture) {
        throw new Error(capturePayload.error ?? "test_capture_failed");
      }

      const testTranscripts = [
        {
          entryType: "expense" as VoiceEntryType,
          title: "测试：午饭现金支出",
          transcript: "午饭花了四十二元，吃了鸡胸肉和米饭。",
          extractedJson: {
            amount: 42,
            currency: "CNY",
            notes: "午饭：鸡胸肉和米饭"
          }
        },
        {
          entryType: "workout" as VoiceEntryType,
          title: "测试：哑铃飞鸟记录",
          transcript: "哑铃飞鸟二点五千克十次，感觉偏难。",
          extractedJson: {
            status: "completed",
            notes: "哑铃飞鸟 2.5kg x 10，感觉偏难。"
          }
        }
      ];

      const asrResultIds: string[] = [];
      const draftIds: string[] = [];
      let firstDraft: VoiceDraft | null = null;

      for (const item of testTranscripts) {
        const asrResponse = await fetch(`${apiBaseUrl}/say/asr-results`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            captureId: capturePayload.capture.id,
            provider: "guided-test",
            language: "zh-CN",
            confidence: 0.99,
            transcript: item.transcript,
            rawResult: {
              schema: "fox.say_guided_test_asr_raw.v0",
              raw_audio_committed: false
            }
          })
        });
        const asrPayload = (await asrResponse.json()) as { asrResult?: SayAsrResult; error?: string };
        if (!asrResponse.ok || !asrPayload.asrResult) {
          throw new Error(asrPayload.error ?? "test_asr_failed");
        }
        asrResultIds.push(asrPayload.asrResult.id);

        const draftResponse = await fetch(`${apiBaseUrl}/say/drafts`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            asrResultId: asrPayload.asrResult.id,
            entryType: item.entryType,
            title: item.title,
            extractedJson: item.extractedJson,
            extractionConfidence: 0.99
          })
        });
        const draftPayload = (await draftResponse.json()) as { draft?: VoiceDraft; error?: string };
        if (!draftResponse.ok || !draftPayload.draft) {
          throw new Error(draftPayload.error ?? "test_draft_failed");
        }
        draftIds.push(draftPayload.draft.id);
        firstDraft = firstDraft ?? draftPayload.draft;
      }

      setCapture(capturePayload.capture);
      setAsrResult(null);
      setTestSeedSummary({
        captureId: capturePayload.capture.id,
        asrResultIds,
        draftIds
      });
      if (firstDraft) {
        applyVoiceDraft(firstDraft);
        await loadVoiceDrafts(firstDraft.id);
      } else {
        await loadVoiceDrafts();
      }
      setActiveView("inbox");
      setStatusNote(`测试草稿已生成：${draftIds.length} 条待确认。`);
    } catch (error) {
      const message = error instanceof Error ? error.message : "test_seed_failed";
      setStatusNote(`测试链路失败：${message}`);
    } finally {
      setTestBusy(false);
    }
  }, [applyVoiceDraft, loadVoiceDrafts]);

  const persistVoiceDraftEditor = useCallback(async (): Promise<VoiceDraft> => {
    if (!voiceDraft) {
      throw new Error("voice_draft_required");
    }
    const extractedJson = parseDraftJson(draftJsonText);
    const response = await fetch(`${apiBaseUrl}/say/drafts/${voiceDraft.id}`, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        entryType: draftEntryType,
        title: draftTitle.trim() || voiceDraft.title,
        extractedJson
      })
    });
    const payload = (await response.json()) as { draft?: VoiceDraft; error?: string };
    if (!response.ok || !payload.draft) {
      throw new Error(payload.error ?? "voice_draft_update_failed");
    }
    applyVoiceDraft(payload.draft);
    await loadVoiceDrafts(payload.draft.id);
    return payload.draft;
  }, [applyVoiceDraft, draftEntryType, draftJsonText, draftTitle, loadVoiceDrafts, voiceDraft]);

  const saveVoiceDraft = useCallback(async () => {
    if (!voiceDraft) {
      setStatusNote("请先选择草稿。");
      return;
    }
    if (voiceDraft.status !== "needs_review") {
      setStatusNote("只有待确认草稿可以编辑。");
      return;
    }
    setDraftBusy(true);
    try {
      const currentConfirmNotes = confirmNotes;
      const saved = await persistVoiceDraftEditor();
      setConfirmNotes(currentConfirmNotes);
      setDraftJsonError("");
      setStatusNote(`已保存草稿 ${saved.id}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : "voice_draft_update_failed";
      setDraftJsonError(message);
      setStatusNote(`保存草稿失败：${message}`);
    } finally {
      setDraftBusy(false);
    }
  }, [confirmNotes, persistVoiceDraftEditor, voiceDraft]);

  const discardVoiceDraft = useCallback(async () => {
    if (!voiceDraft) {
      setStatusNote("请先选择草稿。");
      return;
    }
    if (voiceDraft.status !== "needs_review") {
      setStatusNote("只有待确认草稿可以丢弃。");
      return;
    }
    setDraftBusy(true);
    try {
      const response = await fetch(`${apiBaseUrl}/say/drafts/${voiceDraft.id}`, {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ status: "discarded" })
      });
      const payload = (await response.json()) as { draft?: VoiceDraft; error?: string };
      if (!response.ok || !payload.draft) {
        throw new Error(payload.error ?? "voice_draft_discard_failed");
      }
      applyVoiceDraft(payload.draft);
      await loadVoiceDrafts(payload.draft.id);
      setStatusNote(`已丢弃草稿 ${payload.draft.id}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : "voice_draft_discard_failed";
      setStatusNote(`丢弃草稿失败：${message}`);
    } finally {
      setDraftBusy(false);
    }
  }, [applyVoiceDraft, loadVoiceDrafts, voiceDraft]);

  const confirmVoiceDraft = useCallback(async () => {
    if (!voiceDraft) {
      setStatusNote("请先选择草稿。");
      return;
    }
    if (voiceDraft.status !== "needs_review") {
      setStatusNote("只有待确认草稿可以入库。");
      return;
    }
    setDraftBusy(true);
    try {
      const savedDraft = await persistVoiceDraftEditor();
      const savedJson = parseDraftJson(formatDraftJson(savedDraft.extractedJson));
      const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || "Asia/Bangkok";
      const response = await fetch(`${apiBaseUrl}/say/drafts/${savedDraft.id}/confirm`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          title: savedDraft.title,
          timezone,
          confirmedJson: {
            ...savedJson,
            notes: confirmNotes.trim() || initialDraftNote(savedDraft),
            user_confirmation_status: "confirmed"
          }
        })
      });
      const payload = (await response.json()) as { draft?: VoiceDraft; entry?: ConfirmedVoiceEntry; error?: string };
      if (!response.ok || !payload.draft || !payload.entry) {
        throw new Error(payload.error ?? "voice_draft_confirm_failed");
      }
      await loadVoiceDrafts(payload.draft.id);
      setVoiceDraft(payload.draft);
      setSelectedDraftId(payload.draft.id);
      setConfirmedEntry(payload.entry);
      setStatusNote(`已确认 ${payload.entry.id}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : "voice_draft_confirm_failed";
      setDraftJsonError(message);
      setStatusNote(`确认入库失败：${message}`);
    } finally {
      setDraftBusy(false);
    }
  }, [confirmNotes, loadVoiceDrafts, persistVoiceDraftEditor, voiceDraft]);

  const stopCapture = useCallback(() => {
    if (nativeRecorderActiveRef.current) {
      setUploading(true);
      setStatusNote("正在结束 iPad 原生录音并上传。");
      window.webkit?.messageHandlers?.foxPadAudioCapture?.postMessage({ action: "stop" });
      return;
    }
    if (recorderRef.current?.state === "recording") {
      recorderRef.current.stop();
      setStatusNote("正在结束录音并上传。");
    }
  }, []);

  const policySummary = useMemo(
    () => [
      `提醒 ${formatSeconds(reminderMs)}`,
      `静默结束 ${formatSeconds(silenceTimeoutMs)}`,
      recognitionSupported ? "浏览器听写可用" : "浏览器听写不可用",
      speechSupported ? "浏览器朗读可用" : "浏览器朗读不可用",
      nativeRecorderSupported ? "iPad 原生录音桥可用" : browserRecorderSupported ? "浏览器录音可用" : "录音不可用"
    ],
    [browserRecorderSupported, nativeRecorderSupported, recognitionSupported, speechSupported]
  );
  const visibleDrafts = useMemo(
    () => (draftFilter === "needs_review" ? voiceDrafts.filter((draft) => draft.status === "needs_review") : voiceDrafts),
    [draftFilter, voiceDrafts]
  );
  const pendingDraftCount = useMemo(() => voiceDrafts.filter((draft) => draft.status === "needs_review").length, [voiceDrafts]);
  const flowSteps = useMemo(
    () => [
      {
        key: "capture",
        label: "录音",
        detail: capture ? `${Math.round(capture.bytes / 1024)} KB` : captureStarting ? "请求权限" : recording ? "收音中" : "等待录音",
        status: (capture ? "done" : captureStarting || recording || uploading ? "active" : "waiting") as FlowStepStatus
      },
      {
        key: "asr",
        label: "识别",
        detail: asrResult ? asrResult.provider : asrJob?.status === "failed" ? "失败，可重试" : asrJob ? asrJob.status : asrRunning ? "运行中" : capture ? "未运行" : "等待录音",
        status: (asrResult ? "done" : asrJob?.status === "failed" ? "blocked" : asrRunning ? "active" : capture ? "blocked" : "waiting") as FlowStepStatus
      },
      {
        key: "draft",
        label: "草稿",
        detail: voiceDraft ? voiceDraft.status : asrResult ? "可生成" : "等待识别",
        status: (voiceDraft ? "done" : draftBusy ? "active" : asrResult ? "blocked" : "waiting") as FlowStepStatus
      },
      {
        key: "review",
        label: "确认",
        detail: confirmedEntry ? confirmedEntry.kind : voiceDraft?.status === "needs_review" ? "待处理" : "等待草稿",
        status: (confirmedEntry ? "done" : voiceDraft?.status === "needs_review" ? "active" : "waiting") as FlowStepStatus
      },
      {
        key: "entry",
        label: "入库",
        detail: confirmedEntry ? confirmedEntry.id.replace(/^entry_/, "entry_") : "等待确认",
        status: (confirmedEntry ? "done" : "waiting") as FlowStepStatus
      }
    ],
    [asrJob, asrResult, asrRunning, capture, captureStarting, confirmedEntry, draftBusy, recording, uploading, voiceDraft]
  );

  return (
    <main className="screen say-screen" data-mode="fox-say">
      <section className="say-header" aria-label="Fox Say 状态">
        <div>
          <span className="eyebrow">FOX SAY</span>
          <h1>Fox Say</h1>
        </div>
        <div className={`say-state ${sessionState}`} aria-label="当前语音状态">
          <strong>{sessionState}</strong>
          <span>{statusNote}</span>
        </div>
      </section>

      <nav className="say-tabs" aria-label="Fox Say 工作区">
        {sayViews.map((view) => (
          <button key={view.value} className={activeView === view.value ? "selected" : ""} type="button" onClick={() => setActiveView(view.value)}>
            {view.label}
          </button>
        ))}
      </nav>

      {activeView === "record" ? (
        <section className="say-flow-panel" aria-label="日常记录流程">
          <div className="say-panel-heading">
            <div>
              <h2>日常语音记录</h2>
              <p>{confirmedEntry ? "本条记录已完成。" : voiceDraft?.status === "needs_review" ? "草稿等待确认。" : asrResult ? "识别结果可发送到 Mac 或生成草稿。" : asrJob?.status === "failed" ? "识别失败，可重试。" : asrJob ? "Linux 正在识别当前录音。" : capture ? "录音已就绪。" : "等待开始。"}</p>
            </div>
            <span>{confirmedEntry ? "done" : pendingDraftCount ? `${pendingDraftCount} 待确认` : "ready"}</span>
          </div>

          <div className="say-flow-steps" aria-label="记录步骤">
            {flowSteps.map((step) => (
              <article key={step.key} className={step.status}>
                <span>{flowStatusLabel(step.status)}</span>
                <strong>{step.label}</strong>
                <small>{step.detail}</small>
              </article>
            ))}
          </div>

          <div className="say-capture-strip" aria-label="iPad 到 Linux roundtrip capture">
            <div>
              <h2>录音</h2>
              <p>{capture ? `当前 ${capture.id} / ${Math.round(capture.bytes / 1024)} KB / sha256 ${capture.sha256.slice(0, 12)}` : "等待录音。"}</p>
            </div>
            <div className="actions">
              <button className="primary" type="button" disabled={!recorderSupported || captureStarting || recording || uploading} onClick={startCapture}>
                开始录音
              </button>
              <button className="ghost" type="button" disabled={!recording} onClick={stopCapture}>
                停止并上传
              </button>
              <button className="ghost" type="button" onClick={loadLatestCapture}>
                读取最近录音
              </button>
              {capture ? (
                <audio controls src={`${apiBaseUrl}/say/captures/${capture.id}/audio`} aria-label="已上传录音回放" />
              ) : null}
            </div>
          </div>

          <div className="say-guided-grid">
            <article>
              <span>ASR</span>
              <strong>{asrResult ? `${asrResult.provider} / ${asrResult.confidence ?? "?"}` : asrJob ? `job / ${asrJob.status}` : "等待识别"}</strong>
              <p>{asrResult?.transcript ?? (asrJob?.status === "failed" ? `Linux ASR 失败：${asrJob.errorMessage ?? asrJob.errorCode ?? "unknown"}` : asrRunning ? "Linux ASR 正在处理当前录音。" : capture ? "当前录音尚未运行 ASR。" : "录音后再识别。")}</p>
              <div className="actions">
                <button className="primary" type="button" disabled={!capture || asrRunning} onClick={runCurrentCaptureAsr}>
                  {asrJob?.status === "failed" ? "重新识别当前录音" : "识别当前录音"}
                </button>
                <button className="ghost" type="button" onClick={loadLatestAsrResult}>
                  读取当前录音 ASR
                </button>
              </div>
            </article>
            <article>
              <span>Draft</span>
              <strong>{voiceDraft ? `${voiceDraft.entryType} / ${voiceDraft.status}` : "等待草稿"}</strong>
              <p>{voiceDraft?.title ?? "识别文本会先进入收件箱。"}</p>
              <div className="actions">
                <button className="ghost" type="button" disabled={!asrResult || draftBusy} onClick={createVoiceDraft}>
                  生成草稿
                </button>
                <button className="primary" type="button" onClick={() => setActiveView("inbox")}>
                  打开收件箱
                </button>
              </div>
            </article>
            <article>
              <span>Mac</span>
              <strong>{macInputJob?.status === "completed" ? "已复制到 Mac" : macInputJob ? `clipboard / ${macInputJob.status}` : "等待发送"}</strong>
              <p>{macInputJob?.status === "completed" ? "文本已写入 Mac 剪贴板。到目标 App 按 Command-V。" : macInputJob ? "本机 bridge 正在处理。不会自动粘贴或改写 Fox。" : "可把当前 ASR 文本交给 Mac 剪贴板；Fox 入库仍须单独确认。"}</p>
              <div className="actions">
                <button className="primary" type="button" disabled={!asrResult || macInputJob?.status === "queued" || macInputJob?.status === "claimed"} onClick={queueMacInput}>
                  {macInputJob?.status === "completed" ? "再次发送到 Mac" : "发送到 Mac"}
                </button>
              </div>
            </article>
          </div>

          <section className="say-receipt" aria-label="完成回执">
            <div>
              <span>Entry</span>
              <strong>{confirmedEntry?.id ?? "尚未入库"}</strong>
            </div>
            <div>
              <span>类型</span>
              <strong>{confirmedEntry?.kind ?? voiceDraft?.entryType ?? "未确定"}</strong>
            </div>
            <div>
              <span>Mac</span>
              <strong>{macInputJob?.status ?? "未发送"}</strong>
            </div>
            <div>
              <span>Workout state</span>
              <strong>false</strong>
            </div>
          </section>
        </section>
      ) : null}

      {activeView === "test" ? (
        <section className="say-test-panel" aria-label="Fox Say 测试链路">
          <div className="say-panel-heading">
            <div>
              <h2>测试链路</h2>
              <p>{testSeedSummary ? "本地测试草稿已生成。" : "本地 smoke 就绪。"}</p>
            </div>
            <span>{testSeedSummary ? "pass" : "idle"}</span>
          </div>
          <div className="say-test-grid">
            <article>
              <span>UI Smoke</span>
              <strong>不依赖 iPad / Linux</strong>
              <p>生成 fake capture、ASR result 和两条待确认草稿。</p>
              <button className="primary" type="button" disabled={testBusy} onClick={seedTestDrafts}>
                生成测试草稿
              </button>
            </article>
            <article>
              <span>Real ASR</span>
              <strong>staged</strong>
              <p>真实录音后在终端运行 npm run say:linux-asr，再回到这里读取当前录音 ASR。</p>
              <button className="ghost" type="button" onClick={loadLatestAsrResult}>
                读取当前录音 ASR
              </button>
            </article>
          </div>
          <section className="say-receipt" aria-label="测试结果">
            <div>
              <span>Capture</span>
              <strong>{testSeedSummary?.captureId ?? capture?.id ?? "none"}</strong>
            </div>
            <div>
              <span>ASR</span>
              <strong>{testSeedSummary ? `${testSeedSummary.asrResultIds.length}` : asrResult?.id ?? "none"}</strong>
            </div>
            <div>
              <span>Drafts</span>
              <strong>{testSeedSummary ? `${testSeedSummary.draftIds.length}` : `${pendingDraftCount}`}</strong>
            </div>
            <div>
              <span>Next</span>
              <button className="ghost" type="button" onClick={() => setActiveView("inbox")}>
                收件箱
              </button>
            </div>
          </section>
        </section>
      ) : null}

      {activeView === "inbox" ? (
        <section className="say-draft-panel" aria-label="ASR to Fox draft">
          <div className="say-panel-heading">
            <div>
              <h2>Review Inbox</h2>
              <p>{pendingDraftCount ? "处理待确认草稿。" : "没有待确认草稿。"}</p>
            </div>
            <span>{pendingDraftCount ? `${pendingDraftCount} 待确认` : voiceDraft ? voiceDraft.status : asrResult ? "asr_ready" : "waiting_asr"}</span>
          </div>
          <div className="draft-flow-grid">
            <article>
              <strong>{asrResult ? `${asrResult.provider} / ${asrResult.confidence ?? "?"}` : "尚未读取 ASR"}</strong>
              <p>{asrResult?.transcript ?? "Linux ASR 结果会显示在这里。"}</p>
            </article>
            <article>
              <strong>{voiceDraft ? `${voiceDraft.entryType} / ${voiceDraft.status}` : "尚未生成草稿"}</strong>
              <p>{voiceDraft ? voiceDraft.title : "草稿会等待人工确认，不会自动修改训练状态。"}</p>
            </article>
          </div>
          <div className="draft-inbox-layout">
            <aside className="draft-inbox-list" aria-label="语音草稿收件箱">
              <div className="draft-inbox-toolbar">
                <label>
                  显示
                  <select value={draftFilter} onChange={(event) => setDraftFilter(event.target.value as "needs_review" | "all")}>
                    <option value="needs_review">待确认</option>
                    <option value="all">全部</option>
                  </select>
                </label>
                <button className="ghost" type="button" disabled={draftBusy} onClick={() => void loadVoiceDrafts(selectedDraftId || undefined)}>
                  刷新
                </button>
              </div>
              <div className="draft-list-items">
                {visibleDrafts.length ? (
                  visibleDrafts.slice(0, 10).map((draft) => (
                    <button
                      key={draft.id}
                      className={draft.id === selectedDraftId ? "selected" : ""}
                      type="button"
                      onClick={() => applyVoiceDraft(draft)}
                    >
                      <span>{draft.status}</span>
                      <strong>{draft.title}</strong>
                      <small>{draft.entryType}</small>
                    </button>
                  ))
                ) : (
                  <p>没有待确认草稿。</p>
                )}
              </div>
            </aside>

            <div className="draft-editor" aria-label="草稿详情">
              <div className="draft-editor-grid">
                <label>
                  草稿类型
                  <select value={draftEntryType} disabled={!voiceDraft || voiceDraft.status !== "needs_review"} onChange={(event) => setDraftEntryType(event.target.value as VoiceEntryType)}>
                    {voiceEntryTypes.map((entryType) => (
                      <option key={entryType.value} value={entryType.value}>
                        {entryType.label}
                      </option>
                    ))}
                  </select>
                </label>
                <label>
                  草稿标题
                  <input value={draftTitle} disabled={!voiceDraft || voiceDraft.status !== "needs_review"} onChange={(event) => setDraftTitle(event.target.value)} placeholder="确认前可改标题" />
                </label>
              </div>
              <label className="draft-confirm-field">
                确认内容
                <textarea
                  value={confirmNotes}
                  disabled={!voiceDraft || voiceDraft.status !== "needs_review"}
                  onChange={(event) => setConfirmNotes(event.target.value)}
                  placeholder="确认或修正 ASR 内容后再入库"
                />
              </label>
              <label className="draft-json-field">
                结构化 JSON
                <textarea
                  value={draftJsonText}
                  disabled={!voiceDraft || voiceDraft.status !== "needs_review"}
                  onChange={(event) => {
                    setDraftJsonText(event.target.value);
                    setDraftJsonError("");
                  }}
                  placeholder='{"notes":"..."}'
                />
              </label>
              {draftJsonError ? <p className="draft-error">{draftJsonError}</p> : null}
            </div>
          </div>
          <div className="corpus-footer">
            <div>
              <strong>{confirmedEntry ? `已确认 ${confirmedEntry.id}` : voiceDraft?.id ?? asrResult?.id ?? "等待输入"}</strong>
              <span>{confirmedEntry ? confirmedEntry.title : "ASR result -> needs_review draft -> confirmed Entry"}</span>
            </div>
            <div className="actions">
              <button className="ghost" type="button" onClick={loadLatestAsrResult}>
                读取当前录音 ASR
              </button>
              <button className="ghost" type="button" disabled={!asrResult || draftBusy} onClick={createVoiceDraft}>
                生成草稿
              </button>
              <button className="ghost" type="button" disabled={!voiceDraft || draftBusy || voiceDraft.status !== "needs_review"} onClick={saveVoiceDraft}>
                保存修改
              </button>
              <button className="ghost" type="button" disabled={!voiceDraft || draftBusy || voiceDraft.status !== "needs_review"} onClick={discardVoiceDraft}>
                丢弃草稿
              </button>
              <button className="primary" type="button" disabled={!voiceDraft || draftBusy || voiceDraft.status !== "needs_review"} onClick={confirmVoiceDraft}>
                确认入库
              </button>
            </div>
          </div>
        </section>
      ) : null}

      <details className="say-debug-panel">
        <summary>调试详情</summary>
        <section className="say-layout">
          <article className="say-panel" aria-label="文字转语音">
            <div className="say-panel-heading">
              <h2>文字转语音</h2>
              <span>{firstAudioMs ? `首音频 ${firstAudioMs}ms` : "等待朗读"}</span>
            </div>
            <textarea value={text} onChange={(event) => setText(event.target.value)} aria-label="要朗读的文字" />
            <div className="actions">
              <button className="primary" type="button" disabled={!speechSupported} onClick={speak}>
                朗读
              </button>
              <button className="ghost" type="button" onClick={() => setText(defaultText)}>
                恢复示例
              </button>
            </div>
          </article>

          <article className="say-panel" aria-label="语音转文字">
            <div className="say-panel-heading">
              <h2>语音转文字</h2>
              <span>{lastHeardAt ? `静默 ${formatSeconds(idleForMs)}` : "尚未收音"}</span>
            </div>
            <div className="transcript-box" aria-live="polite">
              <strong>{interimTranscript || "等待语音输入"}</strong>
              <p>{finalTranscript || "识别完成的文本会显示在这里。"}</p>
            </div>
            <div className="actions">
              <button className="primary" type="button" disabled={!recognitionSupported || Boolean(recognitionRef.current)} onClick={startListening}>
                开始听
              </button>
              <button className="ghost" type="button" onClick={stopListening}>
                停止
              </button>
              <button className="ghost" type="button" onClick={clearTranscript}>
                清空
              </button>
            </div>
          </article>
        </section>

        <section className="say-corpus-panel" aria-label="Corpus capture mode">
          <div className="say-panel-heading">
            <div>
              <h2>Corpus Capture</h2>
              <p>保存 shape-only manifest。raw audio 保持在 runtime storage，不进入 git。</p>
            </div>
            <span>{savedSample ? `已保存 ${savedSample.sampleId}` : `${corpusSamples.length} samples`}</span>
          </div>
          <div className="corpus-grid">
            <label>
              Bucket
              <select value={corpusBucket} onChange={(event) => setCorpusBucket(event.target.value as CorpusBucket)}>
                {corpusBuckets.map((bucket) => (
                  <option key={bucket.value} value={bucket.value}>
                    {bucket.label}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Environment
              <input value={environment} onChange={(event) => setEnvironment(event.target.value)} placeholder="quiet_room / treadmill / fan_noise" />
            </label>
            <label>
              Speaker
              <input value={speakerProfile} onChange={(event) => setSpeakerProfile(event.target.value)} placeholder="owner" />
            </label>
            <label className="corpus-wide">
              Expected Text
              <textarea value={expectedText} onChange={(event) => setExpectedText(event.target.value)} placeholder="例如：完成本组" />
            </label>
            <label className="corpus-wide">
              Noise Notes
              <input value={noiseNotes} onChange={(event) => setNoiseNotes(event.target.value)} placeholder="例如：iPad 距离 2 米，风扇噪声" />
            </label>
          </div>
          <div className="corpus-footer">
            <div>
              <strong>{capture ? capture.id : "尚未选择 capture"}</strong>
              <span>
                {capture
                  ? `${capture.contentType} / ${Math.round(capture.bytes / 1024)} KB / sha256 ${capture.sha256.slice(0, 12)}`
                  : "先录音，或读取最近录音。"}
              </span>
            </div>
            <button className="primary" type="button" disabled={!capture || savingSample} onClick={saveCorpusSample}>
              保存样本
            </button>
          </div>
          {corpusSamples.length ? (
            <div className="corpus-samples" aria-label="最近 corpus 样本">
              {corpusSamples.slice(0, 5).map((sample) => (
                <article key={sample.sampleId}>
                  <strong>{sample.sampleId}</strong>
                  <span>{sample.bucket}</span>
                  <p>{sample.expectedText}</p>
                </article>
              ))}
            </div>
          ) : null}
        </section>

        <section className="say-policy-strip" aria-label="会话策略">
          {policySummary.map((item) => (
            <span key={item}>{item}</span>
          ))}
        </section>
      </details>
    </main>
  );
}
