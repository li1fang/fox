import assert from "node:assert/strict";
import test from "node:test";

import {
  buildAsrJobSpec,
  buildAsrPostPayload,
  parseJsonOutput,
  reportMatchesCapture
} from "../../scripts/fox-say-linux-asr-runner.mjs";

test("builds a VCompose ASR job spec without local raw audio paths", () => {
  const spec = buildAsrJobSpec({
    audioPathShape: "say_1234_real.m4a",
    target: "fox-say-latest-capture-sensevoice-v0",
    templateRef: "fox/k3s-heavy-gpu-fox-say-sensevoice-latest-capture-asr"
  });

  assert.match(spec, /templateRef: "fox\/k3s-heavy-gpu-fox-say-sensevoice-latest-capture-asr"/);
  assert.match(spec, /FOX_VOICE_ASR_AUDIO: "\/workspace\/data\/roundtrip\/say_1234_real\.m4a"/);
  assert.doesNotMatch(spec, /(^|\n)\s+image:/);
  assert.doesNotMatch(spec, /\/Users\//);
  assert.doesNotMatch(spec, /apps\/api\/\.tmp/);
});

test("maps a SenseVoice report to Fox ASR result payload", () => {
  const payload = buildAsrPostPayload({
    capture: {
      id: "say_1234_real",
      bytes: 1024,
      sha256: "abc123"
    },
    remoteReport: {
      ok: true,
      asr_engine: "sensevoice",
      asr_model: "iic/SenseVoiceSmall",
      language: "zh",
      text: "完成本组休息90秒。",
      tagged_text: "<|zh|><|NEUTRAL|><|Speech|><|withitn|>完成本组休息90秒。",
      transcribe_ms: 321,
      text_score: {
        expected_text_present: false
      },
      audio_path_shape: "/workspace/data/roundtrip/say_1234_real.m4a",
      raw_audio_committed: false
    }
  });

  assert.equal(payload.captureId, "say_1234_real");
  assert.equal(payload.provider, "linux-sensevoice");
  assert.equal(payload.language, "zh-CN");
  assert.equal(payload.transcript, "完成本组休息90秒。");
  assert.equal(payload.rawResult.raw_audio_committed, false);
  assert.doesNotMatch(JSON.stringify(payload), /\/Users\//);
});

test("matches remote ASR report to latest capture shape", () => {
  assert.equal(
    reportMatchesCapture(
      {
        ok: true,
        audio_bytes: 4096,
        audio_path_shape: "/workspace/data/roundtrip/say_real.wav",
        raw_audio_committed: false,
        text: "测试"
      },
      {
        bytes: 145,
        audioPathShape: "say_real.m4a",
        asrAudioBytes: 4096,
        asrAudioPathShape: "say_real.wav"
      }
    ),
    true
  );
});

test("extracts JSON from command output with logs around it", () => {
  assert.deepEqual(parseJsonOutput("log\n{\"ok\":true,\"value\":1}\n", "sample"), { ok: true, value: 1 });
});
