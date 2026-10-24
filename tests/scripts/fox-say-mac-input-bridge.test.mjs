import assert from "node:assert/strict";
import test from "node:test";
import { bridgeFailureReceipt, bridgeReceipt } from "../../scripts/fox-say-mac-input-bridge.mjs";

test("Fox Say Mac bridge receipts never include dictated text", () => {
  const secretTranscript = "这段文字只能进入本机剪贴板。";
  const job = { id: "macjob_test_123", textCharacters: secretTranscript.length };

  const completed = bridgeReceipt(job);
  const failed = bridgeFailureReceipt(job, new Error("pbcopy unavailable"));

  assert.match(completed, /macjob_test_123/);
  assert.match(completed, new RegExp(`chars=${secretTranscript.length}`));
  assert.doesNotMatch(completed, new RegExp(secretTranscript));
  assert.doesNotMatch(failed, new RegExp(secretTranscript));
});
