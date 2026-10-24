import { expect, test } from "@playwright/test";

const apiBase = "http://127.0.0.1:4187";

function installNativeCaptureSuccessMock(page: import("@playwright/test").Page) {
  return page.addInitScript(() => {
    const win = window as any;
    win.__nativeCaptureMessages = [];
    win.webkit = {
      messageHandlers: {
        foxPadAudioCapture: {
          postMessage(message: unknown) {
            win.__nativeCaptureMessages.push(message);
            const action = typeof message === "object" && message ? (message as { action?: string }).action : "";
            if (action === "start") {
              window.setTimeout(() => {
                win.__foxPadAudioCaptureResult?.({
                  ok: true,
                  event: "started",
                  backend: "ios_native"
                });
              }, 0);
            }
            if (action === "stop") {
              window.setTimeout(() => {
                win.__foxPadAudioCaptureResult?.({
                  ok: true,
                  event: "uploaded",
                  backend: "ios_native",
                  payload: {
                    capture: {
                      id: "say_native_mock",
                      contentType: "audio/mp4",
                      bytes: 8192,
                      sha256: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
                      audioPathShape: "runtime-only/say_native_mock.m4a",
                      capturedAt: "2026-07-02T00:00:00.000Z"
                    }
                  }
                });
              }, 0);
            }
          }
        }
      }
    };
  });
}

function installNativeCaptureFailureMock(page: import("@playwright/test").Page) {
  return page.addInitScript(() => {
    const win = window as any;
    win.__nativeCaptureMessages = [];
    win.webkit = {
      messageHandlers: {
        foxPadAudioCapture: {
          postMessage(message: unknown) {
            win.__nativeCaptureMessages.push(message);
            win.__foxPadAudioCaptureResult?.({
              ok: false,
              event: "error",
              error: "native_recording_start_failed",
              errorMessage: "mock audio session denied",
              errorDomain: "AVFoundationErrorDomain",
              errorCode: 561017449,
              context: "beginRecording"
            });
          }
        }
      }
    };
  });
}

test("opens Fox Say directly as its own app route", async ({ page }) => {
  await page.goto("/?mode=say");
  await expect(page.locator("[data-mode='fox-say']")).toBeVisible();
  await expect(page.getByRole("navigation", { name: "应用入口" })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Fox Say" })).toBeVisible();
  await expect(page.getByRole("navigation", { name: "Fox Say 工作区" })).toContainText("日常记录");
  await expect(page.getByLabel("日常记录流程")).toBeVisible();
});

test("handles iPad native capture bridge success without browser MediaRecorder", async ({ page }) => {
  await installNativeCaptureSuccessMock(page);
  await page.route(`${apiBase}/say/asr-jobs`, async (route) => {
    const body = route.request().postDataJSON() as { captureId?: string };
    expect(body.captureId).toBe("say_native_mock");
    await route.fulfill({
      status: 202,
      contentType: "application/json",
      body: JSON.stringify({
        reused: false,
        job: {
          schema: "fox.say_asr_job.v0",
          id: "asrjob_native_mock",
          captureId: "say_native_mock",
          status: "queued"
        }
      })
    });
  });
  await page.route(`${apiBase}/say/asr-jobs/asrjob_native_mock`, async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        job: {
          schema: "fox.say_asr_job.v0",
          id: "asrjob_native_mock",
          captureId: "say_native_mock",
          status: "running"
        }
      })
    });
  });

  await page.goto("/?mode=say");
  await page.getByRole("button", { name: "开始录音" }).click();
  await expect(page.getByLabel("Fox Say 状态")).toContainText("正在通过 iPad 原生录音桥录音。");
  await expect(page.getByLabel("记录步骤")).toContainText("收音中");

  const startMessages = await page.evaluate(() => (window as any).__nativeCaptureMessages);
  expect(startMessages[0]).toMatchObject({
    action: "start",
    uploadUrl: `${apiBase}/say/capture`
  });

  await page.getByRole("button", { name: "停止并上传" }).click();
  await expect(page.getByLabel("Fox Say 状态")).toContainText("Linux ASR 正在处理");
  await expect(page.getByLabel("日常记录流程")).toContainText("say_native_mock");
  await expect(page.getByLabel("记录步骤")).toContainText("8 KB");

  const allMessages = await page.evaluate(() => (window as any).__nativeCaptureMessages);
  expect(allMessages.map((message: { action?: string }) => message.action)).toEqual(["start", "stop"]);
});

test("surfaces detailed iPad native capture bridge failures", async ({ page }) => {
  await installNativeCaptureFailureMock(page);

  await page.goto("/?mode=say");
  await page.getByRole("button", { name: "开始录音" }).click();

  await expect(page.getByLabel("Fox Say 状态")).toContainText("iPad 原生录音失败：native_recording_start_failed");
  await expect(page.getByLabel("Fox Say 状态")).toContainText("mock audio session denied");
  await expect(page.getByLabel("Fox Say 状态")).toContainText("AVFoundationErrorDomain#561017449");
  await expect(page.getByLabel("Fox Say 状态")).toContainText("context beginRecording");
  await expect(page.getByRole("button", { name: "开始录音" })).toBeEnabled();
  await expect(page.getByRole("button", { name: "停止并上传" })).toBeDisabled();
});

test("recovers when the iPad native capture bridge throws before reaching Swift", async ({ page }) => {
  await page.addInitScript(() => {
    const win = window as any;
    win.webkit = {
      messageHandlers: {
        foxPadAudioCapture: {
          postMessage() {
            throw new Error("mock bridge unavailable");
          }
        }
      }
    };
  });

  await page.goto("/?mode=say");
  await page.getByRole("button", { name: "开始录音" }).click();

  await expect(page.getByLabel("Fox Say 状态")).toContainText("iPad 原生录音桥启动失败：mock bridge unavailable");
  await expect(page.getByRole("button", { name: "开始录音" })).toBeEnabled();
  await expect(page.getByRole("button", { name: "停止并上传" })).toBeDisabled();
});

test("saves a Fox Say corpus sample manifest from the latest capture", async ({ page, request }) => {
  const captureResponse = await request.post(`${apiBase}/say/capture`, {
    headers: { "content-type": "audio/mp4" },
    data: Buffer.from("fake-ipad-audio-for-corpus")
  });
  expect(captureResponse.status()).toBe(201);

  await page.goto("/?mode=say");
  await page.getByText("调试详情").click();
  await expect(page.getByText("Corpus Capture")).toBeVisible();
  await page.getByRole("button", { name: "读取最近录音" }).click();
  await expect(page.getByText("已载入最近录音")).toBeVisible();

  await page.getByLabel("Bucket").selectOption("training_feedback");
  await page.getByLabel("Environment").fill("quiet_room");
  await page.getByLabel("Speaker").fill("owner");
  await page.getByLabel("Expected Text").fill("右肘有点酸，少做两次");
  await page.getByLabel("Noise Notes").fill("iPad 近距离，无明显噪声");
  await page.getByRole("button", { name: "保存样本" }).click();

  await expect(page.getByText(/已保存 fox-say-\d+/)).toBeVisible();
  await expect(page.getByLabel("最近 corpus 样本")).toContainText("training_feedback");
  await expect(page.getByLabel("最近 corpus 样本")).toContainText("右肘有点酸，少做两次");

  const listed = await request.get(`${apiBase}/say/corpus-samples`);
  const payload = (await listed.json()) as {
    samples: Array<{ expectedText: string; rawAudioCommitted: boolean; audioPath: string }>;
  };
  const sample = payload.samples.find((item) => item.expectedText === "右肘有点酸，少做两次");
  expect(sample?.rawAudioCommitted).toBe(false);
  expect(sample?.audioPath).toContain("runtime-only/");
});

test("reviews a Linux ASR result and confirms it as a Fox entry", async ({ page, request }) => {
  const captureResponse = await request.post(`${apiBase}/say/capture`, {
    headers: { "content-type": "audio/mp4" },
    data: Buffer.from("fake-ipad-audio-for-asr-draft")
  });
  expect(captureResponse.status()).toBe(201);
  const { capture } = (await captureResponse.json()) as { capture: { id: string } };

  const asrResponse = await request.post(`${apiBase}/say/asr-results`, {
    data: {
      captureId: capture.id,
      provider: "linux-sensevoice",
      language: "zh-CN",
      confidence: 0.92,
      transcript: "今天跑步五分钟，配速五公里每小时，平板支撑没做。"
    }
  });
  expect(asrResponse.status()).toBe(201);

  await page.goto("/?mode=say");
  await page.getByRole("button", { name: "读取最近录音" }).click();
  await page.getByRole("button", { name: "读取当前录音 ASR" }).click();
  await expect(page.getByLabel("日常记录流程")).toContainText("今天跑步五分钟");
  await page.getByRole("button", { name: "生成草稿" }).click();
  await expect(page.getByLabel("ASR to Fox draft").locator(".draft-flow-grid article").nth(1)).toContainText("needs_review");
  await page.getByLabel("确认内容").fill("跑步机 5 分钟，速度 5km/h；平板支撑未完成。");
  await page.getByRole("button", { name: "确认入库" }).click();
  await expect(page.getByLabel("ASR to Fox draft").getByText(/已确认 entry_/)).toBeVisible();

  const entries = await request.get(`${apiBase}/entries?source=voice_draft`);
  const payload = (await entries.json()) as { entries: Array<{ rawText: string; confirmedJson: { notes?: string } }> };
  expect(payload.entries[0]?.rawText).toContain("平板支撑没做");
  expect(payload.entries[0]?.confirmedJson.notes).toContain("5km/h");
});

test("guided test flow creates reviewable inbox drafts", async ({ page, request }) => {
  await page.goto("/?mode=say");
  await page.getByRole("button", { name: "测试链路" }).click();
  await expect(page.getByLabel("Fox Say 测试链路")).toBeVisible();
  await page.getByRole("button", { name: "生成测试草稿" }).click();

  await expect(page.getByLabel("ASR to Fox draft")).toBeVisible();
  await expect(page.getByLabel("语音草稿收件箱")).toContainText("测试：午饭现金支出");
  await expect(page.getByLabel("语音草稿收件箱")).toContainText("测试：哑铃飞鸟记录");

  const drafts = await request.get(`${apiBase}/say/drafts`);
  const payload = (await drafts.json()) as { drafts: Array<{ title: string; status: string }> };
  expect(payload.drafts.filter((draft) => draft.status === "needs_review" && draft.title.startsWith("测试：")).length).toBeGreaterThanOrEqual(2);
});

test("edits and confirms a selected Fox Say review inbox draft", async ({ page, request }) => {
  const suffix = `e2e-${Date.now()}`;
  const expenseTitle = `测试午饭 ${suffix}`;
  const workoutTitle = `测试训练 ${suffix}`;
  const captureResponse = await request.post(`${apiBase}/say/capture`, {
    headers: { "content-type": "audio/mp4" },
    data: Buffer.from("fake-ipad-audio-for-review-inbox")
  });
  expect(captureResponse.status()).toBe(201);
  const { capture } = (await captureResponse.json()) as { capture: { id: string } };

  const expenseAsrResponse = await request.post(`${apiBase}/say/asr-results`, {
    data: {
      captureId: capture.id,
      provider: "linux-sensevoice",
      language: "zh-CN",
      confidence: 0.9,
      transcript: "午饭花了四十二元，吃了鸡胸肉和米饭。"
    }
  });
  expect(expenseAsrResponse.status()).toBe(201);
  const { asrResult: expenseAsr } = (await expenseAsrResponse.json()) as { asrResult: { id: string } };
  const expenseDraftResponse = await request.post(`${apiBase}/say/drafts`, {
    data: { asrResultId: expenseAsr.id, title: expenseTitle }
  });
  expect(expenseDraftResponse.status()).toBe(201);

  const workoutAsrResponse = await request.post(`${apiBase}/say/asr-results`, {
    data: {
      captureId: capture.id,
      provider: "linux-sensevoice",
      language: "zh-CN",
      confidence: 0.88,
      transcript: "哑铃飞鸟二点五千克十次。"
    }
  });
  expect(workoutAsrResponse.status()).toBe(201);
  const { asrResult: workoutAsr } = (await workoutAsrResponse.json()) as { asrResult: { id: string } };
  const workoutDraftResponse = await request.post(`${apiBase}/say/drafts`, {
    data: { asrResultId: workoutAsr.id, title: workoutTitle }
  });
  expect(workoutDraftResponse.status()).toBe(201);

  await page.goto("/?mode=say");
  await page.getByRole("navigation", { name: "Fox Say 工作区" }).getByRole("button", { name: "收件箱" }).click();
  const inbox = page.getByLabel("语音草稿收件箱");
  await expect(inbox).toContainText("needs_review");
  await inbox.getByRole("button", { name: new RegExp(expenseTitle) }).click();

  await page.getByLabel("草稿类型").selectOption("expense");
  await page.getByLabel("草稿标题").fill("午饭现金支出");
  await page.getByLabel("结构化 JSON").fill(
    JSON.stringify(
      {
        amount: 42,
        currency: "CNY",
        notes: "午饭：鸡胸肉和米饭"
      },
      null,
      2
    )
  );
  await page.getByLabel("确认内容").fill("午饭现金支出 42 元，鸡胸肉和米饭。");
  await page.getByRole("button", { name: "保存修改" }).click();
  await expect(page.getByText(/已保存草稿/)).toBeVisible();

  await page.getByRole("button", { name: "确认入库" }).click();
  await expect(page.getByLabel("ASR to Fox draft").getByText(/已确认 entry_/)).toBeVisible();

  const entries = await request.get(`${apiBase}/entries?source=voice_draft`);
  const payload = (await entries.json()) as {
    entries: Array<{ kind: string; title: string; confirmedJson: { amount?: number; notes?: string } }>;
  };
  const entry = payload.entries.find((candidate) => candidate.title === "午饭现金支出");
  expect(entry?.kind).toBe("expense");
  expect(entry?.confirmedJson.amount).toBe(42);
  expect(entry?.confirmedJson.notes).toContain("42 元");
});

test("does not read stale ASR from a previous capture", async ({ page, request }) => {
  const staleCaptureResponse = await request.post(`${apiBase}/say/capture`, {
    headers: { "content-type": "audio/mp4" },
    data: Buffer.from("fake-ipad-audio-for-stale-asr")
  });
  expect(staleCaptureResponse.status()).toBe(201);
  const { capture: staleCapture } = (await staleCaptureResponse.json()) as { capture: { id: string } };

  const staleAsrResponse = await request.post(`${apiBase}/say/asr-results`, {
    data: {
      captureId: staleCapture.id,
      provider: "linux-sensevoice",
      language: "zh-CN",
      confidence: 0.91,
      transcript: "这是一条旧录音的识别结果，不应该出现。"
    }
  });
  expect(staleAsrResponse.status()).toBe(201);

  const currentCaptureResponse = await request.post(`${apiBase}/say/capture`, {
    headers: { "content-type": "audio/mp4" },
    data: Buffer.from("fake-ipad-audio-current-without-asr")
  });
  expect(currentCaptureResponse.status()).toBe(201);
  const { capture: currentCapture } = (await currentCaptureResponse.json()) as { capture: { id: string } };

  await page.goto("/?mode=say");
  await page.getByRole("button", { name: "读取最近录音" }).click();
  await expect(page.getByLabel("日常记录流程")).toContainText(currentCapture.id);
  await page.getByRole("button", { name: "读取当前录音 ASR" }).click();

  await expect(page.getByLabel("Fox Say 状态")).toContainText("读取当前录音 ASR 失败：asr_result_not_found");
  await expect(page.getByLabel("日常记录流程")).not.toContainText("这是一条旧录音的识别结果");
});

test("can trigger ASR for the current capture from the Fox Say UI", async ({ page, request }) => {
  const captureResponse = await request.post(`${apiBase}/say/capture`, {
    headers: { "content-type": "audio/mp4" },
    data: Buffer.from("fake-ipad-audio-for-ui-asr-runner")
  });
  expect(captureResponse.status()).toBe(201);
  const { capture } = (await captureResponse.json()) as { capture: { id: string } };

  const jobId = "asrjob_ui_mock";
  const asrResult = {
    schema: "fox.say_asr_result.v0",
    id: "asr_ui_mock",
    captureId: capture.id,
    provider: "mock-linux-sensevoice",
    transcript: "这是从 iPad 页面触发的识别。",
    language: "zh-CN",
    confidence: 0.87,
    rawAudioCommitted: false
  };
  await page.route(`${apiBase}/say/asr-jobs`, async (route) => {
    const body = route.request().postDataJSON() as { captureId?: string };
    expect(body.captureId).toBe(capture.id);
    await route.fulfill({
      status: 202,
      contentType: "application/json",
      body: JSON.stringify({
        reused: false,
        job: {
          schema: "fox.say_asr_job.v0",
          id: jobId,
          captureId: capture.id,
          status: "queued"
        }
      })
    });
  });
  await page.route(`${apiBase}/say/asr-jobs/${jobId}`, async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        job: {
          schema: "fox.say_asr_job.v0",
          id: jobId,
          captureId: capture.id,
          status: "succeeded",
          asrResultId: asrResult.id
        },
        asrResult
      })
    });
  });

  await page.goto("/?mode=say");
  await page.getByRole("button", { name: "读取最近录音" }).click();
  await expect(page.getByLabel("日常记录流程")).toContainText(capture.id);
  await page.getByRole("button", { name: "识别当前录音" }).click();

  await expect(page.getByLabel("Fox Say 状态")).toContainText("当前录音 ASR 已完成。");
  await expect(page.getByLabel("日常记录流程")).toContainText("这是从 iPad 页面触发的识别。");
});

test("restores the capture-bound ASR job after reopening the latest recording", async ({ page, request }) => {
  const captureResponse = await request.post(`${apiBase}/say/capture`, {
    headers: { "content-type": "audio/mp4" },
    data: Buffer.from("fake-ipad-audio-for-asr-job-restore")
  });
  expect(captureResponse.status()).toBe(201);
  const { capture } = (await captureResponse.json()) as { capture: { id: string } };
  const jobId = "asrjob_restore_mock";
  const asrResult = {
    schema: "fox.say_asr_result.v0",
    id: "asr_restore_mock",
    captureId: capture.id,
    provider: "mock-linux-sensevoice",
    transcript: "这是重新打开后恢复的当前录音识别结果。",
    language: "zh-CN",
    confidence: 0.9,
    rawAudioCommitted: false
  };

  await page.route(new RegExp(`/say/asr-jobs\\?captureId=${capture.id}$`), async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        jobs: [
          {
            schema: "fox.say_asr_job.v0",
            id: jobId,
            captureId: capture.id,
            status: "succeeded",
            asrResultId: asrResult.id
          }
        ]
      })
    });
  });
  await page.route(`${apiBase}/say/asr-jobs/${jobId}`, async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        job: {
          schema: "fox.say_asr_job.v0",
          id: jobId,
          captureId: capture.id,
          status: "succeeded",
          asrResultId: asrResult.id
        },
        asrResult
      })
    });
  });

  await page.goto("/?mode=say");
  await page.getByRole("button", { name: "读取最近录音" }).click();
  await expect(page.getByLabel("Fox Say 状态")).toContainText("当前录音 ASR 已完成。");
  await expect(page.getByLabel("日常记录流程")).toContainText("这是重新打开后恢复的当前录音识别结果。");
});

test("queues a reviewed ASR text for the Mac clipboard without confirming a Fox Entry", async ({ page, request }) => {
  const beforeEntriesResponse = await request.get(`${apiBase}/entries?source=voice_draft`);
  const beforeEntries = (await beforeEntriesResponse.json()) as { entries: unknown[] };
  const captureResponse = await request.post(`${apiBase}/say/capture`, {
    headers: { "content-type": "audio/mp4" },
    data: Buffer.from("fake-ipad-audio-for-mac-input")
  });
  expect(captureResponse.status()).toBe(201);
  const { capture } = (await captureResponse.json()) as { capture: { id: string } };

  const asrResponse = await request.post(`${apiBase}/say/asr-results`, {
    data: {
      captureId: capture.id,
      provider: "linux-sensevoice",
      language: "zh-CN",
      confidence: 0.93,
      transcript: "把这条测试文本送到 Mac。"
    }
  });
  expect(asrResponse.status()).toBe(201);
  const { asrResult } = (await asrResponse.json()) as { asrResult: { id: string } };

  await page.goto("/?mode=say");
  await page.getByRole("button", { name: "读取最近录音" }).click();
  await page.getByRole("button", { name: "读取当前录音 ASR" }).click();
  await expect(page.getByLabel("日常记录流程")).toContainText("把这条测试文本送到 Mac");
  await page.getByRole("button", { name: "发送到 Mac" }).click();
  await expect(page.getByLabel("Fox Say 状态")).toContainText("已发送到 Mac 剪贴板队列");
  await expect(page.getByLabel("日常记录流程")).toContainText("clipboard / queued");

  const jobs = await request.get(`${apiBase}/say/mac-input-jobs?asrResultId=${asrResult.id}`);
  const jobsPayload = (await jobs.json()) as { jobs: Array<{ status: string; textCharacters: number }> };
  expect(jobsPayload.jobs[0]?.status).toBe("queued");
  expect(jobsPayload.jobs[0]?.textCharacters).toBeGreaterThan(0);

  const entries = await request.get(`${apiBase}/entries?source=voice_draft`);
  const entriesPayload = (await entries.json()) as { entries: unknown[] };
  expect(entriesPayload.entries).toHaveLength(beforeEntries.entries.length);
});
