import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  getCurrentExercise,
  getCurrentTarget,
  getProgress,
  recommendedCountingMethod,
  estimateSetTimerSeconds,
  type AiFeedbackOption,
  type EquipmentInventory,
  type EquipmentItem,
  type EquipmentKind,
  type DailyCheckIn,
  type SensorCapabilitySnapshot,
  type FeedbackKind,
  type SetRecord,
  type TempoPhase,
  type WorkoutEvent,
  type WorkoutSession
} from "@fox/core";
import { foxApi, type EntryRecord } from "./api";

const feedbackOptions: Array<{ kind: FeedbackKind; label: string }> = [
  { kind: "completed", label: "正常完成" },
  { kind: "not_followed", label: "没跟上" },
  { kind: "too_hard", label: "太重了" },
  { kind: "too_easy", label: "太轻了" },
  { kind: "note", label: "速度不稳定" },
  { kind: "note", label: "不确定动作是否正确" },
  { kind: "pain", label: "疼痛或不舒服" },
  { kind: "skip", label: "跳过或提前停止" }
];

interface FeedbackSelection {
  key: string;
  kind: FeedbackKind;
  label: string;
  message: string;
}

interface PostWorkoutReview {
  informationSupplement?: Record<string, unknown>;
  workoutCorrections?: string[];
  productFeedback?: string[];
  trainingFeedback?: string[];
}

function defaultFeedbackSelection(): FeedbackSelection {
  return { key: "completed-正常完成", kind: "completed", label: "正常完成", message: "" };
}

type SpeechCommand = "finish_set" | "ready" | "emergency_stop";

interface BrowserSpeechRecognitionAlternative {
  transcript: string;
}

interface BrowserSpeechRecognitionResult {
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
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
}

interface SpeechRecognitionWindow extends Window {
  SpeechRecognition?: new () => BrowserSpeechRecognition;
  webkitSpeechRecognition?: new () => BrowserSpeechRecognition;
}

function defaultCheckIn(): DailyCheckIn {
  return {
    sleep: "ok",
    fatigue: "medium",
    hunger: "not_hungry",
    stress: "low",
    painAreas: [],
    availableMinutes: 40
  };
}

function formatTarget(target: ReturnType<typeof getCurrentTarget>): string {
  if (!target) {
    return "等待计划";
  }
  const weight =
    target.targetWeight !== undefined
      ? `${target.targetWeight}${target.weightUnit === "kg" ? "kg" : ""}`
      : target.weightUnit === "kg" || target.weightUnit === "lb" || target.weightUnit === "machine_level"
        ? "重量待测试"
        : "自重";
  if (target.targetDurationSeconds) {
    return `${target.targetDurationSeconds} 秒 · ${weight}`;
  }
  return `${weight} x ${target.targetReps ?? "?"}`;
}

function secondsSince(iso: string | undefined): number | undefined {
  if (!iso) {
    return undefined;
  }
  return Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
}

function estimateDefaultRecord(
  target: ReturnType<typeof getCurrentTarget>,
  session: WorkoutSession,
  durationSeconds = secondsSince(session.activeSetStartedAt) ?? target?.targetDurationSeconds
): Omit<SetRecord, "setIndex" | "plannedSetIndex"> {
  return {
    status: "completed",
    reps: target?.targetReps,
    durationSeconds,
    weight: target?.targetWeight,
    weightUnit: target?.weightUnit,
    pain: false,
    countingMethod: target?.targetDurationSeconds ? "timer" : "manual"
  };
}

function parseOptionalNumber(value: string): number | undefined {
  if (value.trim() === "") {
    return undefined;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function tempoCycleSeconds(tempo: TempoPhase[]): number {
  return tempo.reduce((total, phase) => total + phase.seconds, 0) || 4;
}

function phaseLabel(phase: TempoPhase["phase"] | undefined): string {
  switch (phase) {
    case "lift":
      return "发力";
    case "peak":
      return "顶峰";
    case "lower":
      return "控制";
    case "hold":
      return "保持";
    case "rest":
      return "停顿";
    default:
      return "节奏";
  }
}

function activeRepSnapshot(target: ReturnType<typeof getCurrentTarget>, tempo: TempoPhase[], remaining: number, total: number) {
  if (!target?.targetReps || total <= 0) {
    return undefined;
  }
  const elapsed = Math.max(0, total - remaining);
  const cycleSeconds = total / target.targetReps || tempoCycleSeconds(tempo);
  const currentRep = remaining <= 0 ? target.targetReps : Math.min(target.targetReps, Math.floor(elapsed / cycleSeconds) + 1);
  const phaseElapsed = elapsed % cycleSeconds;
  let cursor = 0;
  const currentPhase =
    tempo.find((phase) => {
      cursor += phase.seconds;
      return phaseElapsed <= cursor;
    }) ?? tempo.at(-1);
  return {
    currentRep,
    targetReps: target.targetReps,
    phase: phaseLabel(currentPhase?.phase)
  };
}

function getWorkoutReviewFromRecord(record: unknown): PostWorkoutReview | undefined {
  if (!record || typeof record !== "object") {
    return undefined;
  }
  const review = (record as { postWorkoutReview?: unknown }).postWorkoutReview;
  if (!review || typeof review !== "object") {
    return undefined;
  }
  return review as PostWorkoutReview;
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string" && item.trim().length > 0) : [];
}

function formatSupplement(value: unknown): string {
  if (Array.isArray(value)) {
    return value.join("、");
  }
  if (value && typeof value === "object") {
    return JSON.stringify(value);
  }
  return String(value);
}

function sortedUniqueNumbers(values: Array<number | undefined>): number[] {
  return [...new Set(values.filter((value): value is number => typeof value === "number" && Number.isFinite(value)))]
    .filter((value) => value >= 0)
    .sort((left, right) => left - right);
}

function matchingEquipmentItem(exerciseName: string | undefined, inventory: EquipmentInventory | null): EquipmentItem | undefined {
  const normalized = (exerciseName ?? "").toLowerCase();
  if (normalized.includes("哑铃") || normalized.includes("dumbbell")) {
    return inventory?.items.find((item) => item.available && item.kind === "dumbbell");
  }
  if (normalized.includes("跑步") || normalized.includes("running")) {
    return inventory?.items.find((item) => item.available && (item.id === "running" || item.name.toLowerCase().includes("running")));
  }
  if (normalized.includes("下拉")) {
    return inventory?.items.find((item) => item.available && item.id.includes("lat_pulldown"));
  }
  if (normalized.includes("胸推") || normalized.includes("推举") || normalized.includes("press")) {
    return inventory?.items.find((item) => item.available && item.id.includes("press"));
  }
  return undefined;
}

function weightOptionsForFeedback(session: WorkoutSession, inventory: EquipmentInventory | null): number[] {
  const exercise = getCurrentExercise(session);
  const target = getCurrentTarget(session);
  const pending = session.pendingSet?.record;
  const equipment = matchingEquipmentItem([exercise?.exerciseId, exercise?.name].filter(Boolean).join(" "), inventory);
  if (equipment?.fixedWeights?.length) {
    return sortedUniqueNumbers([...equipment.fixedWeights, target?.targetWeight, pending?.weight]);
  }
  const lastWeight = [...(exercise?.completedSets ?? [])].reverse().find((set) => typeof set.weight === "number")?.weight;
  const base = pending?.weight ?? target?.targetWeight ?? lastWeight;
  if (typeof base !== "number") {
    return [];
  }
  const increment = equipment?.increment ?? (target?.weightUnit === "kg" || pending?.weightUnit === "kg" ? 2.5 : 1);
  return sortedUniqueNumbers([base - increment * 2, base - increment, base, base + increment, base + increment * 2]);
}

function currentSetTimerSeconds(session: WorkoutSession): number | undefined {
  const exercise = getCurrentExercise(session);
  const target = getCurrentTarget(session);
  return estimateSetTimerSeconds(target, exercise?.tempo ?? []);
}

function useActiveSetCountdown(session: WorkoutSession): { remaining: number; total: number } {
  const total = currentSetTimerSeconds(session) ?? 0;
  const [remaining, setRemaining] = useState(total);

  useEffect(() => {
    if (session.status !== "active_exercise" || !session.activeSetStartedAt || total <= 0) {
      setRemaining(total);
      return;
    }

    let frame = 0;
    const endsAt = new Date(session.activeSetStartedAt).getTime() + total * 1000;
    const tick = () => {
      setRemaining(Math.max(0, Math.ceil((endsAt - Date.now()) / 1000)));
      frame = window.requestAnimationFrame(tick);
    };
    frame = window.requestAnimationFrame(tick);
    return () => window.cancelAnimationFrame(frame);
  }, [session.status, session.activeSetStartedAt, total]);

  return { remaining, total };
}

function useRestCountdown(session: WorkoutSession): number {
  const [remaining, setRemaining] = useState(0);

  useEffect(() => {
    if (session.status !== "rest_timer" || !session.restTimer) {
      setRemaining(0);
      return;
    }

    let frame = 0;
    const tick = () => {
      const next = Math.max(0, Math.ceil((new Date(session.restTimer!.endsAt).getTime() - Date.now()) / 1000));
      setRemaining(next);
      frame = window.requestAnimationFrame(tick);
    };
    frame = window.requestAnimationFrame(tick);
    return () => window.cancelAnimationFrame(frame);
  }, [session.status, session.restTimer]);

  return remaining;
}

function useScreenWakeLock(enabled: boolean) {
  useEffect(() => {
    let active = true;
    let sentinel: WakeLockSentinel | undefined;

    const requestLock = async () => {
      const wakeLock = navigator.wakeLock;
      if (!enabled || !wakeLock || document.visibilityState !== "visible") {
        return;
      }
      try {
        sentinel = await wakeLock.request("screen");
      } catch {
        sentinel = undefined;
      }
    };

    const handleVisibility = () => {
      if (active && document.visibilityState === "visible") {
        void requestLock();
      }
    };

    void requestLock();
    document.addEventListener("visibilitychange", handleVisibility);

    return () => {
      active = false;
      document.removeEventListener("visibilitychange", handleVisibility);
      void sentinel?.release();
    };
  }, [enabled]);
}

function useCoachSpeech(session: WorkoutSession | null, enabled: boolean) {
  const lastSpokenId = useRef<string | null>(null);

  useEffect(() => {
    if (!enabled || !session || !("speechSynthesis" in window)) {
      return;
    }
    const latest = session.coachMessages.at(-1);
    if (!latest || latest.id === lastSpokenId.current) {
      return;
    }
    lastSpokenId.current = latest.id;
    const utterance = new SpeechSynthesisUtterance(latest.text);
    utterance.lang = "zh-CN";
    utterance.rate = 0.95;
    window.speechSynthesis.cancel();
    window.speechSynthesis.speak(utterance);
  }, [enabled, session]);
}

function useSpeechCommandRecognition(enabled: boolean, onCommand: (command: SpeechCommand) => void) {
  useEffect(() => {
    const SpeechRecognition =
      (window as SpeechRecognitionWindow).SpeechRecognition ?? (window as SpeechRecognitionWindow).webkitSpeechRecognition;
    if (!enabled || !SpeechRecognition) {
      return;
    }

    let active = true;
    const recognition = new SpeechRecognition();
    recognition.lang = "zh-CN";
    recognition.continuous = true;
    recognition.interimResults = false;
    recognition.onresult = (event) => {
      for (let index = event.resultIndex; index < event.results.length; index += 1) {
        const transcript = event.results[index]?.[0]?.transcript.replace(/\s/g, "") ?? "";
        if (transcript.includes("停止")) {
          onCommand("emergency_stop");
        } else if (transcript.includes("准备好了") || transcript.includes("继续")) {
          onCommand("ready");
        } else if (transcript.includes("完成") || transcript.includes("做完")) {
          onCommand("finish_set");
        }
      }
    };
    recognition.onend = () => {
      if (active) {
        try {
          recognition.start();
        } catch {
          // Browser may reject immediate restart; next toggle will retry.
        }
      }
    };

    try {
      recognition.start();
    } catch {
      active = false;
    }

    return () => {
      active = false;
      recognition.onend = null;
      recognition.onresult = null;
      try {
        recognition.stop();
      } catch {
        // Some browsers throw if stop is called before start settles.
      }
    };
  }, [enabled, onCommand]);
}

function useSensorCapabilities(): SensorCapabilitySnapshot {
  const [capabilities, setCapabilities] = useState<SensorCapabilitySnapshot>({
    deviceMotion: false,
    accelerometer: false,
    camera: false,
    poseEstimation: false
  });

  useEffect(() => {
    setCapabilities({
      deviceMotion: "DeviceMotionEvent" in window,
      accelerometer: "Accelerometer" in window,
      camera: Boolean(navigator.mediaDevices?.getUserMedia),
      poseEstimation: false
    });
  }, []);

  return capabilities;
}

function ProgressBar({ session }: { session: WorkoutSession }) {
  const progress = getProgress(session);
  return (
    <section className="progress-panel" aria-label="今日主训练进度">
      <div>
        <span className="eyebrow">今日主训练</span>
        <strong>{progress.percentComplete}%</strong>
      </div>
      <div
        className="progress-track"
        role="progressbar"
        aria-label="今日主训练完成进度"
        aria-valuemin={0}
        aria-valuemax={progress.totalMainSets}
        aria-valuenow={progress.completedMainSets}
      >
        <span style={{ width: `${progress.percentComplete}%` }} />
      </div>
      <small>
        完成 {progress.completedMainSets} / {progress.totalMainSets} 组，拉伸不计入
      </small>
    </section>
  );
}

function SensorPanel({ session, capabilities }: { session: WorkoutSession; capabilities: SensorCapabilitySnapshot }) {
  const target = getCurrentTarget(session);
  const method = recommendedCountingMethod(target, capabilities);
  return (
    <section className="sensor-panel" aria-label="计数能力">
      <span className="eyebrow">Counting</span>
      <p>{method === "timer" ? "计时" : method === "manual" ? "手动" : method === "accelerometer" ? "加速度" : "姿态"}</p>
      <small>
        Motion {capabilities.deviceMotion ? "on" : "off"} · Camera {capabilities.camera ? "on" : "off"}
      </small>
    </section>
  );
}

function CoachMessagePanel({ session }: { session: WorkoutSession }) {
  const latest = session.coachMessages.at(-1);
  if (!latest) {
    return null;
  }

  return (
    <section className="coach-panel" aria-label="最近教练建议">
      <span className="eyebrow">Coach</span>
      <p>{latest.text}</p>
    </section>
  );
}

function CountdownRing({ remaining, total, label }: { remaining: number; total: number; label: string }) {
  const percent = total <= 0 ? 0 : Math.max(0, Math.min(100, (remaining / total) * 100));
  return (
    <section className="countdown-card" aria-label={label}>
      <div
        className="ring"
        style={{ background: `conic-gradient(#f7c948 ${percent * 3.6}deg, rgba(255,255,255,0.1) 0deg)` }}
        role="progressbar"
        aria-label={label}
        aria-valuemin={0}
        aria-valuemax={total}
        aria-valuenow={remaining}
      >
        <div>
          <strong>{remaining}</strong>
          <span>秒</span>
        </div>
      </div>
      <p>{label}</p>
    </section>
  );
}

function ExerciseTimerPanel({
  remaining,
  total,
  tempo,
  repSnapshot,
  enabled,
  onToggle
}: {
  remaining: number;
  total: number;
  tempo: TempoPhase[];
  repSnapshot?: { currentRep: number; targetReps: number; phase: string };
  enabled: boolean;
  onToggle: () => void;
}) {
  const label = tempo.map((phase) => `${phase.phase} ${phase.seconds}s`).join(" · ");
  return (
    <section className="exercise-timer-card" aria-label="本组计时与节奏">
      <button className="tempo-toggle" type="button" aria-pressed={enabled} onClick={onToggle}>
        {enabled ? "节奏开启" : "节奏暂停"}
      </button>
      <div className="tempo-stage">
        <div className={`tempo-box${enabled ? "" : " paused"}`} aria-label="发力节奏演示" />
        <div className="rep-readout" aria-label="当前动作次数">
          {repSnapshot ? (
            <>
              <span>{repSnapshot.phase}</span>
              <strong>
                {repSnapshot.currentRep} / {repSnapshot.targetReps}
              </strong>
              <small>次</small>
            </>
          ) : (
            <>
              <span>保持</span>
              <strong>{remaining}</strong>
              <small>秒</small>
            </>
          )}
        </div>
      </div>
      <div className="timer-readout">
        <div
          className="timer-track"
          role="progressbar"
          aria-label="本组倒计时"
          aria-valuemin={0}
          aria-valuemax={total}
          aria-valuenow={remaining}
        >
          <span style={{ width: `${total <= 0 ? 0 : Math.max(0, Math.min(100, (remaining / total) * 100))}%` }} />
        </div>
        <p>
          <strong>{remaining}</strong> 秒
        </p>
        <span>{label || "默认呼吸节奏"}</span>
      </div>
    </section>
  );
}

function entryArray(payload: Record<string, unknown>, key: string): Array<Record<string, unknown>> {
  const value = payload[key];
  return Array.isArray(value) ? (value.filter((item) => item && typeof item === "object") as Array<Record<string, unknown>>) : [];
}

function workoutStats(entry: EntryRecord) {
  const exercises = entryArray((entry.payload.plan as Record<string, unknown> | undefined) ?? {}, "exercises");
  const feedbackEvents = entryArray(entry.payload, "feedbackEvents");
  const completedSets = exercises.reduce((total, exercise) => total + entryArray(exercise, "completedSets").length, 0);
  const riskEvents = feedbackEvents.filter((event) => ["pain", "skip", "not_followed", "too_hard"].includes(String(event.kind)));
  return { completedSets, riskEvents };
}

function PostWorkoutReviewPanel({ review }: { review?: PostWorkoutReview }) {
  const informationSupplement = review?.informationSupplement ? Object.entries(review.informationSupplement) : [];
  const workoutCorrections = stringArray(review?.workoutCorrections);
  const trainingFeedback = stringArray(review?.trainingFeedback);
  const productFeedback = stringArray(review?.productFeedback);
  if (!informationSupplement.length && !workoutCorrections.length && !trainingFeedback.length && !productFeedback.length) {
    return null;
  }

  return (
    <section className="post-review" aria-label="结构化复盘">
      <span className="eyebrow">Review</span>
      {informationSupplement.length ? (
        <article>
          <h3>信息补充</h3>
          {informationSupplement.map(([key, value]) => (
            <p key={key}>
              <strong>{key}</strong>
              <span>{formatSupplement(value)}</span>
            </p>
          ))}
        </article>
      ) : null}
      {workoutCorrections.length ? (
        <article>
          <h3>记录校正</h3>
          {workoutCorrections.map((item) => (
            <p key={item}>{item}</p>
          ))}
        </article>
      ) : null}
      {trainingFeedback.length ? (
        <article>
          <h3>训练反馈</h3>
          {trainingFeedback.map((item) => (
            <p key={item}>{item}</p>
          ))}
        </article>
      ) : null}
      {productFeedback.length ? (
        <article>
          <h3>软件反馈</h3>
          {productFeedback.map((item) => (
            <p key={item}>{item}</p>
          ))}
        </article>
      ) : null}
    </section>
  );
}

function exerciseHistory(entries: EntryRecord[]) {
  const latestByExercise = new Map<string, string>();
  for (const entry of entries) {
    const exercises = entryArray((entry.payload.plan as Record<string, unknown> | undefined) ?? {}, "exercises");
    for (const exercise of exercises) {
      const name = String(exercise.name ?? "Unknown exercise");
      if (latestByExercise.has(name)) {
        continue;
      }
      const completedSets = entryArray(exercise, "completedSets");
      const lastSet = completedSets.at(-1);
      if (!lastSet) {
        continue;
      }
      const weight = typeof lastSet.weight === "number" ? `${lastSet.weight}kg` : "自重";
      const reps = typeof lastSet.reps === "number" ? `${lastSet.reps} 次` : `${lastSet.durationSeconds ?? "?"} 秒`;
      latestByExercise.set(name, `${weight} · ${reps}`);
    }
  }
  return [...latestByExercise.entries()].slice(0, 8);
}

function sevenDaySummary(entries: EntryRecord[]) {
  const since = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const recent = entries.filter((entry) => new Date(entry.occurredAt).getTime() >= since);
  const sets = recent.reduce((total, entry) => total + workoutStats(entry).completedSets, 0);
  const risks = recent.reduce((total, entry) => total + workoutStats(entry).riskEvents.length, 0);
  return { workouts: recent.length, sets, risks };
}

const equipmentKinds: EquipmentKind[] = [
  "dumbbell",
  "barbell",
  "kettlebell",
  "pull_up_bar",
  "bench",
  "mat",
  "machine",
  "cardio",
  "bodyweight",
  "activity",
  "other"
];

function CheckInScreen({
  onDraftPlan,
  onTemplatePlan,
  busy
}: {
  onDraftPlan: (checkIn: DailyCheckIn) => void;
  onTemplatePlan: (checkIn: DailyCheckIn) => void;
  busy: boolean;
}) {
  const [checkIn, setCheckIn] = useState(defaultCheckIn);
  const [painText, setPainText] = useState("");
  const payload = { ...checkIn, painAreas: painText ? painText.split(/[,\s，、]+/).filter(Boolean) : [] };

  return (
    <main className="screen narrow">
      <h1>开始今日训练</h1>
      <p className="lead">先做一个轻量 check-in。今天的状态会影响保守程度。</p>
      <div className="form-grid">
        <label>
          睡眠
          <select value={checkIn.sleep} onChange={(event) => setCheckIn({ ...checkIn, sleep: event.target.value as DailyCheckIn["sleep"] })}>
            <option value="good">好</option>
            <option value="ok">一般</option>
            <option value="poor">差</option>
          </select>
        </label>
        <label>
          疲劳
          <select value={checkIn.fatigue} onChange={(event) => setCheckIn({ ...checkIn, fatigue: event.target.value as DailyCheckIn["fatigue"] })}>
            <option value="low">低</option>
            <option value="medium">中</option>
            <option value="high">高</option>
          </select>
        </label>
        <label>
          饥饿
          <select value={checkIn.hunger} onChange={(event) => setCheckIn({ ...checkIn, hunger: event.target.value as DailyCheckIn["hunger"] })}>
            <option value="not_hungry">不饿</option>
            <option value="somewhat_hungry">有点饿</option>
            <option value="very_hungry">很饿</option>
          </select>
        </label>
        <label>
          压力
          <select value={checkIn.stress} onChange={(event) => setCheckIn({ ...checkIn, stress: event.target.value as DailyCheckIn["stress"] })}>
            <option value="low">低</option>
            <option value="medium">中</option>
            <option value="high">高</option>
          </select>
        </label>
        <label>
          可训练时间
          <input
            type="number"
            min={15}
            max={120}
            value={checkIn.availableMinutes}
            onChange={(event) => setCheckIn({ ...checkIn, availableMinutes: Number(event.target.value) })}
          />
        </label>
        <label>
          疼痛区域
          <input value={painText} onChange={(event) => setPainText(event.target.value)} placeholder="例如：肩、腰、膝" />
        </label>
      </div>
      <div className="actions">
        <button className="primary" disabled={busy} onClick={() => onDraftPlan(payload)}>
          生成计划草稿
        </button>
        <button className="ghost" disabled={busy} onClick={() => onTemplatePlan(payload)}>
          规则模板
        </button>
      </div>
    </main>
  );
}

function PlanScreen({ session, onAccept, onReject }: { session: WorkoutSession; onAccept: () => void; onReject: () => void }) {
  const plan = session.plan;
  return (
    <main className="screen">
      <span className="eyebrow">计划确认</span>
      <h1>{plan?.focus ?? "今日训练"}</h1>
      <p className="lead">{plan?.safetyNotes}</p>
      <CoachMessagePanel session={session} />
      <div className="exercise-list">
        {plan?.exercises.map((exercise) => (
          <article key={exercise.exerciseId}>
            <h2>{exercise.name}</h2>
            <p>{exercise.notes}</p>
            <small>
              {exercise.targetSets.length} 组 · 休息 {exercise.restSeconds} 秒
            </small>
          </article>
        ))}
      </div>
      <div className="actions">
        <button className="primary" onClick={onAccept}>
          接受计划
        </button>
        <button className="ghost" onClick={onReject}>
          今天取消
        </button>
      </div>
    </main>
  );
}

function ActiveExerciseScreen({
  session,
  capabilities,
  tempoEnabled,
  onToggleTempo,
  onFinish,
  onEmergency
}: {
  session: WorkoutSession;
  capabilities: SensorCapabilitySnapshot;
  tempoEnabled: boolean;
  onToggleTempo: () => void;
  onFinish: () => void;
  onEmergency: () => void;
}) {
  const exercise = getCurrentExercise(session);
  const target = getCurrentTarget(session);
  const elapsed = secondsSince(session.activeSetStartedAt);
  const timer = useActiveSetCountdown(session);
  const repSnapshot = activeRepSnapshot(target, exercise?.tempo ?? [], timer.remaining, timer.total);
  return (
    <main className="screen runtime">
      <ProgressBar session={session} />
      <section className="current-card">
        <span className="eyebrow">当前动作</span>
        <h1>{exercise?.name}</h1>
        <p>
          第 {(target?.setIndex ?? 0).toString()} / {exercise?.targetSets.length ?? 0} 组 · {formatTarget(target)}
        </p>
        {repSnapshot ? (
          <div className="inline-rep">
            <strong>
              第 {repSnapshot.currentRep} / {repSnapshot.targetReps} 次
            </strong>
            <span>{repSnapshot.phase}</span>
          </div>
        ) : null}
        <small>本组已进行 {elapsed ?? 0} 秒，完成时自动记录实际时长</small>
      </section>
      <CoachMessagePanel session={session} />
      <SensorPanel session={session} capabilities={capabilities} />
      <ExerciseTimerPanel
        remaining={timer.remaining}
        total={timer.total}
        tempo={exercise?.tempo ?? []}
        repSnapshot={repSnapshot}
        enabled={tempoEnabled}
        onToggle={onToggleTempo}
      />
      <section className="actions runtime-actions">
        <button className="primary" onClick={onFinish}>
          完成本组
        </button>
        <button className="danger" onClick={onEmergency}>
          紧急停止
        </button>
      </section>
    </main>
  );
}

function FeedbackScreen({
  session,
  aiOptions,
  equipmentInventory,
  onUpdatePending,
  onSubmit
}: {
  session: WorkoutSession;
  aiOptions: AiFeedbackOption[];
  equipmentInventory: EquipmentInventory | null;
  onUpdatePending: (record: Partial<Omit<SetRecord, "setIndex" | "plannedSetIndex">>) => void;
  onSubmit: (payload: { kinds: FeedbackKind[]; messages: string[]; message?: string }) => void;
}) {
  const exercise = getCurrentExercise(session);
  const target = getCurrentTarget(session);
  const pending = session.pendingSet?.record;
  const targetWeightLabel = target?.targetWeight !== undefined ? `${target.targetWeight}${target.weightUnit === "kg" ? "kg" : ""}` : "无推荐重量";
  const weightUnit = pending?.weightUnit ?? target?.weightUnit ?? "kg";
  const usesExternalWeight = weightUnit !== "bodyweight";
  const weightOptions = weightOptionsForFeedback(session, equipmentInventory);
  const [selected, setSelected] = useState<FeedbackSelection[]>([defaultFeedbackSelection()]);
  const [freeNote, setFreeNote] = useState("");
  const setReps = (reps: number | undefined) => onUpdatePending({ reps });
  const setWeight = (weight: number | undefined) => onUpdatePending({ weight, weightUnit });
  const stepReps = (delta: number) => setReps(Math.max(0, (pending?.reps ?? target?.targetReps ?? 0) + delta));
  const stepWeight = (delta: number) => {
    const current = pending?.weight ?? target?.targetWeight ?? 0;
    setWeight(Number(Math.max(0, current + delta).toFixed(1)));
  };

  const syncPendingFromSelection = (nextSelected: FeedbackSelection[]) => {
    const kinds = nextSelected.map((selection) => selection.kind);
    if (kinds.includes("pain")) {
      onUpdatePending({ pain: true, status: "failed" });
    } else if (kinds.includes("skip")) {
      onUpdatePending({ pain: false, status: "skipped" });
    } else if (kinds.includes("not_followed") || kinds.includes("too_hard")) {
      onUpdatePending({ pain: false, status: "partial" });
    } else {
      onUpdatePending({ pain: false, status: "completed" });
    }
  };

  const toggleSelection = (selection: FeedbackSelection) => {
    setSelected((current) => {
      const exists = current.some((item) => item.key === selection.key);
      const withoutCompleted = current.filter((item) => item.kind !== "completed");
      const next =
        selection.kind === "completed"
          ? [selection]
          : exists
            ? withoutCompleted.filter((item) => item.key !== selection.key)
            : [...withoutCompleted, selection];
      const normalized = next.length > 0 ? next : [defaultFeedbackSelection()];
      syncPendingFromSelection(normalized);
      return normalized;
    });
  };

  return (
    <main className="screen feedback-screen">
      <span className="eyebrow">组后反馈</span>
      <h1>{exercise?.name}</h1>
      <CoachMessagePanel session={session} />
      <div className="form-grid">
        <section className="quick-field" aria-label="实际次数">
          <span>实际次数</span>
          <strong>{pending?.reps ?? 0}</strong>
          <div className="stepper-row">
            <button type="button" className="ghost compact" onClick={() => stepReps(-1)}>
              -1
            </button>
            <button type="button" className="ghost compact" onClick={() => target?.targetReps !== undefined && setReps(target.targetReps)}>
              目标
            </button>
            <button type="button" className="ghost compact" onClick={() => stepReps(1)}>
              +1
            </button>
          </div>
          <input
            aria-label="实际次数输入"
            type="number"
            min={0}
            value={pending?.reps ?? ""}
            onChange={(event) => setReps(parseOptionalNumber(event.target.value))}
          />
        </section>
        <div className="readonly-metric" aria-label="实际时长">
          <span>实际时长</span>
          <strong>{pending?.durationSeconds ?? 0} 秒</strong>
          <small>由系统根据本组开始和完成时间自动记录</small>
        </div>
        {usesExternalWeight ? (
          <section className="quick-field weight-field" aria-label="实际重量">
            <span>实际重量</span>
            <strong>{pending?.weight !== undefined ? `${pending.weight}${weightUnit === "kg" ? "kg" : ""}` : "未填"}</strong>
            <div className="stepper-row">
              <button type="button" className="ghost compact" onClick={() => stepWeight(-2.5)}>
                -2.5
              </button>
              <button type="button" className="ghost compact" disabled={target?.targetWeight === undefined} onClick={() => setWeight(target?.targetWeight)}>
                推荐
              </button>
              <button type="button" className="ghost compact" onClick={() => stepWeight(2.5)}>
                +2.5
              </button>
            </div>
            <input
              aria-label="实际重量输入"
              type="number"
              min={0}
              step={0.5}
              value={pending?.weight ?? ""}
              onChange={(event) => setWeight(parseOptionalNumber(event.target.value))}
            />
            {weightOptions.length ? (
              <div className="weight-options" aria-label="可选重量">
                {weightOptions.map((weight) => (
                  <button
                    key={weight}
                    type="button"
                    className={pending?.weight === weight ? "selected" : ""}
                    onClick={() => setWeight(weight)}
                  >
                    {weight}kg
                  </button>
                ))}
              </div>
            ) : null}
            <small>推荐：{targetWeightLabel}</small>
          </section>
        ) : null}
      </div>
      <div className="feedback-grid">
        {[...feedbackOptions, ...aiOptions].map((option) => {
          const optionMessage =
            option.kind === "completed" ? "" : "message" in option && typeof option.message === "string" ? option.message : option.label;
          const selection: FeedbackSelection = {
            key: "id" in option && typeof option.id === "string" ? option.id : `${option.kind}-${option.label}`,
            kind: option.kind,
            label: option.label,
            message: optionMessage
          };
          const isSelected = selected.some((item) => item.key === selection.key);
          return (
            <button
              key={selection.key}
              className={isSelected ? "selected" : ""}
              aria-pressed={isSelected}
              onClick={() => toggleSelection(selection)}
            >
              {option.label}
            </button>
          );
        })}
      </div>
      <label className="note-field">
        自由备注
        <textarea value={freeNote} onChange={(event) => setFreeNote(event.target.value)} />
      </label>
      <button
        className="primary"
        onClick={() =>
          onSubmit({
            kinds: [...new Set(selected.map((selection) => selection.kind))],
            messages: selected.map((selection) => selection.message),
            message: freeNote.trim() || undefined
          })
        }
      >
        提交反馈
      </button>
    </main>
  );
}

function RestScreen({
  session,
  onFinishRest,
  onExtend,
  onTransitionFeedback,
  onEmergency
}: {
  session: WorkoutSession;
  onFinishRest: () => void;
  onExtend: () => void;
  onTransitionFeedback: (kind: FeedbackKind, message: string) => void;
  onEmergency: () => void;
}) {
  const remaining = useRestCountdown(session);
  const exercise = getCurrentExercise(session);
  const target = getCurrentTarget(session);
  const total = session.restTimer?.durationSeconds ?? 1;

  return (
    <main className="screen runtime">
      <ProgressBar session={session} />
      <CountdownRing remaining={remaining} total={total} label="休息倒计时" />
      <section className="current-card">
        <span className="eyebrow">下一组</span>
        <h1>{exercise?.name}</h1>
        <p>
          第 {target?.setIndex} 组 · {formatTarget(target)}
        </p>
      </section>
      <CoachMessagePanel session={session} />
      <section className="transition-feedback" aria-label="组间反馈">
        <button onClick={() => onTransitionFeedback("not_followed", "还没恢复，下一组可能跟不上")}>还没恢复</button>
        <button onClick={() => onTransitionFeedback("too_hard", "上一组太重或太累")}>上一组太重</button>
        <button onClick={() => onTransitionFeedback("note", "动作感觉需要注意")}>动作注意</button>
      </section>
      <div className="actions">
        <button className="primary" onClick={onFinishRest}>
          准备好了
        </button>
        <button className="ghost" onClick={onExtend}>
          +30 秒
        </button>
        <button className="danger" onClick={onEmergency}>
          紧急停止
        </button>
      </div>
    </main>
  );
}

function SummaryScreen({ session, onConfirm }: { session: WorkoutSession; onConfirm: () => void }) {
  return (
    <main className="screen narrow">
      <span className="eyebrow">总结确认</span>
      <h1>{session.status === "aborted" ? "训练已中止" : "训练完成"}</h1>
      <CoachMessagePanel session={session} />
      <pre className="summary">{session.summary}</pre>
      <button className="primary" onClick={onConfirm}>
        确认总结
      </button>
    </main>
  );
}

function ConfirmedScreen({ session, onRestart }: { session: WorkoutSession; onRestart: () => void }) {
  const review = getWorkoutReviewFromRecord(session);
  return (
    <main className="screen narrow">
      <span className="eyebrow">已确认</span>
      <h1>记录已进入 confirmed 状态</h1>
      <p className="lead">本轮训练已写入 SQLite。刷新页面后，会恢复到最近一次训练状态。</p>
      <CoachMessagePanel session={session} />
      <pre className="summary">{session.summary}</pre>
      <PostWorkoutReviewPanel review={review} />
      <button className="primary" onClick={onRestart}>
        再来一次
      </button>
    </main>
  );
}

function HistoryScreen({
  entries,
  loading,
  selectedId,
  onSelect,
  onSaveNote,
  onRefresh
}: {
  entries: EntryRecord[];
  loading: boolean;
  selectedId: string | null;
  onSelect: (id: string) => void;
  onSaveNote: (id: string, note: string) => void;
  onRefresh: () => void;
}) {
  const selected = entries.find((entry) => entry.id === selectedId) ?? entries[0];
  const [draftNote, setDraftNote] = useState("");
  const summary = sevenDaySummary(entries);
  const selectedStats = selected ? workoutStats(selected) : undefined;
  const risks = selectedStats?.riskEvents ?? [];

  useEffect(() => {
    setDraftNote(typeof selected?.payload.userNote === "string" ? selected.payload.userNote : "");
  }, [selected?.id, selected?.payload.userNote]);

  return (
    <main className="screen history-screen">
      <section className="history-header">
        <div>
          <span className="eyebrow">History</span>
          <h1>训练复盘</h1>
        </div>
        <button className="ghost" onClick={onRefresh}>
          刷新
        </button>
      </section>
      <section className="history-summary" aria-label="最近七天摘要">
        <article>
          <strong>{summary.workouts}</strong>
          <span>7天训练</span>
        </article>
        <article>
          <strong>{summary.sets}</strong>
          <span>完成组数</span>
        </article>
        <article>
          <strong>{summary.risks}</strong>
          <span>风险反馈</span>
        </article>
      </section>
      <section className="history-layout">
        <div className="entry-list">
          {loading ? <p className="lead">正在读取记录...</p> : null}
          {!loading && entries.length === 0 ? <p className="lead">还没有 confirmed 训练记录。</p> : null}
          {entries.map((entry) => {
            const stats = workoutStats(entry);
            return (
              <button key={entry.id} className={entry.id === selected?.id ? "entry-item selected" : "entry-item"} onClick={() => onSelect(entry.id)}>
                <strong>{entry.title}</strong>
                <span>{new Date(entry.occurredAt).toLocaleString()}</span>
                <small>
                  {stats.completedSets} 组 · {stats.riskEvents.length} 条风险反馈
                </small>
              </button>
            );
          })}
        </div>
        <article className="entry-detail">
          {selected ? (
            <>
              <span className="eyebrow">Detail</span>
              <h2>{selected.title}</h2>
              <pre className="summary">{typeof selected.payload.summary === "string" ? selected.payload.summary : "暂无总结"}</pre>
              <PostWorkoutReviewPanel review={getWorkoutReviewFromRecord(selected.payload)} />
              <section className="history-subsection">
                <h3>同动作最近表现</h3>
                <div className="exercise-history">
                  {exerciseHistory(entries).map(([name, value]) => (
                    <p key={name}>
                      <strong>{name}</strong>
                      <span>{value}</span>
                    </p>
                  ))}
                </div>
              </section>
              <section className="history-subsection">
                <h3>风险提示</h3>
                {risks.length === 0 ? <p>本次没有明显风险反馈。</p> : null}
                {risks.map((event, index) => (
                  <p key={`${event.exerciseName}-${event.setIndex}-${index}`}>
                    {String(event.exerciseName ?? "Unknown")} 第 {String(event.setIndex ?? "?")} 组：{String(event.kind)}
                  </p>
                ))}
              </section>
              <label>
                备注修正
                <textarea value={draftNote} onChange={(event) => setDraftNote(event.target.value)} />
              </label>
              <button className="primary" onClick={() => onSaveNote(selected.id, draftNote)}>
                保存备注
              </button>
            </>
          ) : null}
        </article>
      </section>
    </main>
  );
}

function EquipmentScreen({
  inventory,
  loading,
  onSave,
  onRefresh
}: {
  inventory: EquipmentInventory | null;
  loading: boolean;
  onSave: (inventory: EquipmentInventory) => void;
  onRefresh: () => void;
}) {
  const [draft, setDraft] = useState<EquipmentInventory | null>(inventory);

  useEffect(() => {
    setDraft(inventory);
  }, [inventory]);

  const updateItem = (id: string, patch: Partial<EquipmentItem>) => {
    setDraft((current) =>
      current
        ? {
            ...current,
            items: current.items.map((item) => (item.id === id ? { ...item, ...patch } : item))
          }
        : current
    );
  };

  const addItem = () => {
    setDraft((current) => {
      const now = Date.now();
      const nextItem: EquipmentItem = {
        id: `equipment_${now}`,
        name: "New Equipment",
        kind: "other",
        available: true
      };
      return current ? { ...current, items: [...current.items, nextItem] } : { items: [nextItem] };
    });
  };

  return (
    <main className="screen history-screen">
      <section className="history-header">
        <div>
          <span className="eyebrow">Equipment</span>
          <h1>家庭器材</h1>
        </div>
        <div className="actions">
          <button className="ghost" onClick={onRefresh}>
            刷新
          </button>
          <button className="primary" disabled={!draft} onClick={() => draft && onSave(draft)}>
            保存
          </button>
        </div>
      </section>
      {loading ? <p className="lead">正在读取器材档案...</p> : null}
      <label>
        器材备注
        <textarea value={draft?.notes ?? ""} onChange={(event) => setDraft((current) => (current ? { ...current, notes: event.target.value } : current))} />
      </label>
      <section className="equipment-list">
        {draft?.items.map((item) => (
          <article key={item.id} className="equipment-item">
            <label>
              名称
              <input value={item.name} onChange={(event) => updateItem(item.id, { name: event.target.value })} />
            </label>
            <label>
              类型
              <select value={item.kind} onChange={(event) => updateItem(item.id, { kind: event.target.value as EquipmentKind })}>
                {equipmentKinds.map((kind) => (
                  <option key={kind} value={kind}>
                    {kind}
                  </option>
                ))}
              </select>
            </label>
            <label className="checkbox-label">
              <input type="checkbox" checked={item.available} onChange={(event) => updateItem(item.id, { available: event.target.checked })} />
              可用
            </label>
            <label>
              最小重量
              <input type="number" value={item.minWeight ?? ""} onChange={(event) => updateItem(item.id, { minWeight: Number(event.target.value) || undefined })} />
            </label>
            <label>
              最大重量
              <input type="number" value={item.maxWeight ?? ""} onChange={(event) => updateItem(item.id, { maxWeight: Number(event.target.value) || undefined })} />
            </label>
            <label>
              增量
              <input type="number" value={item.increment ?? ""} onChange={(event) => updateItem(item.id, { increment: Number(event.target.value) || undefined })} />
            </label>
            <label>
              备注
              <input value={item.notes ?? ""} onChange={(event) => updateItem(item.id, { notes: event.target.value })} />
            </label>
            <section className="equipment-ai-profile">
              <span className="eyebrow">AI 档案</span>
              <p>
                {[item.nameCn, item.nameEn, item.equipmentType].filter(Boolean).join(" · ") || "暂无结构化名称"}
              </p>
              {item.movementPatterns?.length ? <small>动作模式：{item.movementPatterns.join("、")}</small> : null}
              {item.functions?.length ? <small>支持功能：{item.functions.map((fn) => fn.nameCn ?? fn.name).join("、")}</small> : null}
              {item.constraints?.length ? <small>限制：{item.constraints.join("；")}</small> : null}
            </section>
          </article>
        ))}
      </section>
      <button className="ghost" onClick={addItem}>
        添加器材
      </button>
    </main>
  );
}

export function App() {
  const [session, setSession] = useState<WorkoutSession | null>(null);
  const [aiFeedbackOptions, setAiFeedbackOptions] = useState<AiFeedbackOption[]>([]);
  const [view, setView] = useState<"runtime" | "history" | "equipment">("runtime");
  const [entries, setEntries] = useState<EntryRecord[]>([]);
  const [equipmentInventory, setEquipmentInventory] = useState<EquipmentInventory | null>(null);
  const [selectedEntryId, setSelectedEntryId] = useState<string | null>(null);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [equipmentLoading, setEquipmentLoading] = useState(false);
  const [tempoEnabled, setTempoEnabled] = useState(true);
  const [voiceEnabled, setVoiceEnabled] = useState(false);
  const [speechInputEnabled, setSpeechInputEnabled] = useState(false);
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const currentTarget = useMemo(() => (session ? getCurrentTarget(session) : undefined), [session]);
  const sensorCapabilities = useSensorCapabilities();
  const runtimeActive = session?.status === "active_exercise" || session?.status === "rest_timer" || session?.status === "feedback";
  const speechInputSupported = Boolean(
    (window as SpeechRecognitionWindow).SpeechRecognition ?? (window as SpeechRecognitionWindow).webkitSpeechRecognition
  );

  useScreenWakeLock(runtimeActive);
  useCoachSpeech(session, voiceEnabled);

  const syncCurrentSession = useCallback(async (showLoading = false) => {
    try {
      if (showLoading) {
        setLoading(true);
      }
      const restored = await foxApi.getCurrentSession();
      setSession(restored);
      setError(null);
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Fox API 连接失败");
    } finally {
      if (showLoading) {
        setLoading(false);
      }
    }
  }, []);

  useEffect(() => {
    let active = true;
    const load = () => {
      if (active) {
        void syncCurrentSession(true);
      }
    };
    load();
    return () => {
      active = false;
    };
  }, [syncCurrentSession]);

  useEffect(() => {
    const handleVisibility = () => {
      if (document.visibilityState === "visible") {
        void syncCurrentSession(false);
      }
    };
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [syncCurrentSession]);

  useEffect(() => {
    if (session?.status !== "feedback") {
      setAiFeedbackOptions([]);
      return;
    }

    let active = true;
    const loadOptions = async () => {
      try {
        const payload = await foxApi.getFeedbackOptions();
        if (active) {
          setAiFeedbackOptions(payload.options);
          setSession(payload.session);
        }
      } catch {
        if (active) {
          setAiFeedbackOptions([]);
        }
      }
    };
    void loadOptions();
    return () => {
      active = false;
    };
  }, [session?.status, session?.pendingSet?.exerciseIndex, session?.pendingSet?.setIndex]);

  const loadEntries = useCallback(async () => {
    try {
      setHistoryLoading(true);
      const nextEntries = await foxApi.listEntries({ kind: "workout", source: "workout_session" });
      setEntries(nextEntries);
      setSelectedEntryId((current) => current ?? nextEntries[0]?.id ?? null);
    } finally {
      setHistoryLoading(false);
    }
  }, []);

  const loadEquipment = useCallback(async () => {
    try {
      setEquipmentLoading(true);
      setEquipmentInventory(await foxApi.getEquipmentInventory());
    } finally {
      setEquipmentLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadEquipment();
  }, [loadEquipment]);

  useEffect(() => {
    if (view === "history") {
      void loadEntries();
    }
    if (view === "equipment") {
      void loadEquipment();
    }
  }, [loadEntries, loadEquipment, view]);

  const saveEntryNote = async (entryId: string, userNote: string) => {
    const updated = await foxApi.updateEntryNote(entryId, userNote);
    setEntries((current) => current.map((entry) => (entry.id === updated.id ? updated : entry)));
  };

  const saveEquipment = async (inventory: EquipmentInventory) => {
    setEquipmentInventory(await foxApi.saveEquipmentInventory(inventory));
  };

  const withChrome = (content: ReactNode) => (
    <>
      <nav className="view-switch" aria-label="主视图">
        <button className={view === "runtime" ? "selected" : ""} onClick={() => setView("runtime")}>
          训练
        </button>
        <button className={view === "history" ? "selected" : ""} onClick={() => setView("history")}>
          历史
        </button>
        <button className={view === "equipment" ? "selected" : ""} onClick={() => setView("equipment")}>
          器材
        </button>
        <button
          className={voiceEnabled ? "selected" : ""}
          disabled={!("speechSynthesis" in window)}
          onClick={() => setVoiceEnabled((current) => !current)}
        >
          {voiceEnabled ? "语音开" : "语音关"}
        </button>
        <button
          className={speechInputEnabled ? "selected" : ""}
          disabled={!speechInputSupported}
          onClick={() => setSpeechInputEnabled((current) => !current)}
        >
          {speechInputEnabled ? "听写开" : "听写关"}
        </button>
      </nav>
      {content}
    </>
  );

  const send = useCallback(async (event: WorkoutEvent) => {
    try {
      setSending(true);
      const next = await foxApi.dispatchEvent(event);
      setSession(next);
      setError(null);
    } catch (sendError) {
      setError(sendError instanceof Error ? sendError.message : "提交训练事件失败");
    } finally {
      setSending(false);
    }
  }, []);

  const activeAutoKey = useMemo(() => {
    if (session?.status !== "active_exercise" || !session.activeSetStartedAt) {
      return null;
    }
    return `${session.id}-${session.currentExerciseIndex}-${session.currentSetIndex}-${session.activeSetStartedAt}`;
  }, [session]);

  useEffect(() => {
    if (!session || session.status !== "active_exercise" || !session.activeSetStartedAt || !activeAutoKey) {
      return;
    }
    const totalSeconds = currentSetTimerSeconds(session);
    if (!totalSeconds) {
      return;
    }
    const endsAt = new Date(session.activeSetStartedAt).getTime() + totalSeconds * 1000;
    const timeout = window.setTimeout(() => {
      void send({ type: "SET_FINISHED", record: estimateDefaultRecord(getCurrentTarget(session), session, totalSeconds) });
    }, Math.max(0, endsAt - Date.now()));
    return () => window.clearTimeout(timeout);
  }, [activeAutoKey, send, session]);

  useEffect(() => {
    if (session?.status !== "rest_timer" || !session.restTimer) {
      return;
    }
    const timeout = window.setTimeout(() => {
      void send({ type: "REST_FINISHED" });
    }, Math.max(0, new Date(session.restTimer.endsAt).getTime() - Date.now()));
    return () => window.clearTimeout(timeout);
  }, [send, session?.restTimer, session?.status]);

  const restart = async () => {
    try {
      setSending(true);
      const next = await foxApi.createSession();
      setSession(next);
      setError(null);
    } catch (restartError) {
      setError(restartError instanceof Error ? restartError.message : "创建训练会话失败");
    } finally {
      setSending(false);
    }
  };

  const draftPlan = async (checkIn: DailyCheckIn) => {
    try {
      setSending(true);
      const payload = await foxApi.draftPlan(checkIn);
      setSession(payload.session);
      setError(null);
    } catch (draftError) {
      setError(draftError instanceof Error ? draftError.message : "生成计划草稿失败");
    } finally {
      setSending(false);
    }
  };

  const handleSpeechCommand = useCallback(
    (command: SpeechCommand) => {
      if (!session) {
        return;
      }
      if (command === "finish_set" && session.status === "active_exercise") {
        void send({ type: "SET_FINISHED", record: estimateDefaultRecord(currentTarget, session) });
      } else if (command === "ready" && session.status === "rest_timer") {
        void send({ type: "REST_FINISHED" });
      } else if (command === "emergency_stop" && runtimeActive) {
        void send({ type: "EMERGENCY_STOP", message: "用户通过语音触发紧急停止。" });
      }
    },
    [currentTarget, runtimeActive, send, session]
  );

  useSpeechCommandRecognition(speechInputEnabled && runtimeActive, handleSpeechCommand);

  if (loading) {
    return (
      <main className="screen narrow">
        <span className="eyebrow">FOX RUNTIME</span>
        <h1>正在恢复训练状态</h1>
        <p className="lead">连接本地 API，并读取最近一次 SQLite 会话。</p>
      </main>
    );
  }

  if (error || !session) {
    return (
      <main className="screen narrow">
        <span className="eyebrow">连接错误</span>
        <h1>本地 API 不可用</h1>
        <pre className="summary">{error ?? "没有可用训练会话"}</pre>
        <button className="primary" onClick={() => window.location.reload()}>
          重新连接
        </button>
      </main>
    );
  }

  if (view === "history") {
    return withChrome(
      <HistoryScreen
        entries={entries}
        loading={historyLoading}
        selectedId={selectedEntryId}
        onSelect={setSelectedEntryId}
        onSaveNote={(entryId, note) => void saveEntryNote(entryId, note)}
        onRefresh={() => void loadEntries()}
      />
    );
  }

  if (view === "equipment") {
    return withChrome(
      <EquipmentScreen
        inventory={equipmentInventory}
        loading={equipmentLoading}
        onSave={(inventory) => void saveEquipment(inventory)}
        onRefresh={() => void loadEquipment()}
      />
    );
  }

  if (session.status === "idle") {
    return withChrome(
      <CheckInScreen
        busy={sending}
        onDraftPlan={(checkIn) => void draftPlan(checkIn)}
        onTemplatePlan={(checkIn) => void send({ type: "SUBMIT_CHECK_IN", checkIn })}
      />
    );
  }

  if (session.status === "awaiting_approval") {
    return withChrome(
      <PlanScreen
        session={session}
        onAccept={() => void send({ type: "ACCEPT_PLAN" })}
        onReject={() => void send({ type: "REJECT_PLAN" })}
      />
    );
  }

  if (session.status === "active_exercise") {
    return withChrome(
      <ActiveExerciseScreen
        session={session}
        capabilities={sensorCapabilities}
        tempoEnabled={tempoEnabled}
        onToggleTempo={() => setTempoEnabled((current) => !current)}
        onFinish={() => void send({ type: "SET_FINISHED", record: estimateDefaultRecord(currentTarget, session) })}
        onEmergency={() => void send({ type: "EMERGENCY_STOP", message: "用户触发紧急停止。" })}
      />
    );
  }

  if (session.status === "feedback") {
    return withChrome(
      <FeedbackScreen
        session={session}
        aiOptions={aiFeedbackOptions}
        equipmentInventory={equipmentInventory}
        onUpdatePending={(record) => void send({ type: "UPDATE_PENDING_SET", record })}
        onSubmit={(payload) => void send({ type: "SUBMIT_FEEDBACK", ...payload })}
      />
    );
  }

  if (session.status === "rest_timer") {
    return withChrome(
      <RestScreen
        session={session}
        onFinishRest={() => void send({ type: "REST_FINISHED" })}
        onExtend={() => void send({ type: "REST_EXTENDED", seconds: 30 })}
        onTransitionFeedback={(kind, message) => void send({ type: "SUBMIT_TRANSITION_FEEDBACK", kind, message })}
        onEmergency={() => void send({ type: "EMERGENCY_STOP", message: "用户在休息中触发紧急停止。" })}
      />
    );
  }

  if (session.status === "summary_pending" || session.status === "aborted") {
    return withChrome(<SummaryScreen session={session} onConfirm={() => void send({ type: "CONFIRM_SUMMARY" })} />);
  }

  if (session.status === "confirmed") {
    return withChrome(<ConfirmedScreen session={session} onRestart={() => void restart()} />);
  }

  return withChrome(
    <main className="screen narrow">
      <h1>训练已取消</h1>
      {sending ? <p className="lead">正在写入...</p> : null}
      <button className="primary" onClick={() => void restart()}>
        重新开始
      </button>
    </main>
  );
}
