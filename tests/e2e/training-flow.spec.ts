import { expect, test } from "@playwright/test";

const apiBase = "http://127.0.0.1:4187";

test.describe.configure({ mode: "serial" });

test("completes and confirms a full workout flow", async ({ page, request }) => {
  await request.post(`${apiBase}/sessions`);
  await page.goto("/");

  await page.getByRole("button", { name: "生成计划草稿" }).click();
  await expect(page.getByText("计划确认")).toBeVisible();

  await page.getByRole("button", { name: "接受计划" }).click();

  for (let setIndex = 0; setIndex < 6; setIndex += 1) {
    await expect(page.getByRole("button", { name: "完成本组" })).toBeVisible();
    await page.getByRole("button", { name: "完成本组" }).click();

    await expect(page.getByText("组后反馈")).toBeVisible();
    await page.getByRole("button", { name: "提交反馈" }).click();

    if (setIndex < 5) {
      await expect(page.getByText("休息倒计时")).toBeVisible();
      await page.getByRole("button", { name: "准备好了" }).click();
    }
  }

  await expect(page.getByText("总结确认")).toBeVisible();
  await page.getByRole("button", { name: "确认总结" }).click();

  await expect(page.getByText("记录已进入 confirmed 状态")).toBeVisible();
});

test("auto-advances exercise and rest timers while preserving multi-select feedback", async ({ page, request }) => {
  await request.post(`${apiBase}/sessions`);
  await request.post(`${apiBase}/sessions/current/plan-draft`, {
    data: {
      source: "ai",
      message: "自动化短流程计划，请确认。",
      checkIn: {
        sleep: "good",
        fatigue: "medium",
        hunger: "not_hungry",
        stress: "low",
        painAreas: ["手臂后侧"],
        availableMinutes: 5
      },
      plan: {
        focus: "automated timer flow",
        estimatedDurationMinutes: 5,
        warmup: "light warmup",
        cooldown: "stretch",
        safetyNotes: "stop on pain",
        exercises: [
          {
            exerciseId: "auto_press",
            name: "Auto Press",
            category: "push",
            restSeconds: 1,
            tempo: [{ phase: "lift", seconds: 1, visual: "expand" }],
            notes: "short automated set",
            targetSets: [{ setIndex: 1, targetReps: 1, targetWeight: 5, weightUnit: "kg", restSeconds: 1 }],
            completedSets: []
          },
          {
            exerciseId: "auto_plank",
            name: "Auto Plank",
            category: "core",
            restSeconds: 1,
            tempo: [{ phase: "hold", seconds: 1, visual: "hold" }],
            notes: "short automated hold",
            targetSets: [{ setIndex: 1, targetDurationSeconds: 1, weightUnit: "bodyweight", restSeconds: 1 }],
            completedSets: []
          }
        ]
      }
    }
  });

  await page.goto("/");
  await expect(page.getByText("计划确认")).toBeVisible();
  await page.getByRole("button", { name: "接受计划" }).click();

  await expect(page.getByText("组后反馈")).toBeVisible();
  await page.getByRole("button", { name: "太重了" }).click();
  await page.getByRole("button", { name: "速度不稳定" }).click();
  await page.getByLabel("自由备注").fill("自动测试备注");
  await page.getByRole("button", { name: "提交反馈" }).click();

  await expect(page.getByText("休息倒计时")).toBeVisible();
  await expect(page.getByText("Auto Plank")).toBeVisible({ timeout: 5_000 });

  await expect(page.getByText("组后反馈")).toBeVisible();
  await page.getByRole("button", { name: "提交反馈" }).click();

  await expect(page.getByText("总结确认")).toBeVisible();
  await expect(page.getByText("自动测试备注")).toBeVisible();
  await page.getByRole("button", { name: "确认总结" }).click();
  await expect(page.getByText("记录已进入 confirmed 状态")).toBeVisible();

  const entriesResponse = await request.get(`${apiBase}/entries`);
  const { entries } = await entriesResponse.json();
  expect(entries[0].payload.summary).toContain("自动测试备注");
  expect(entries[0].payload.feedbackEvents[0].kinds).toEqual(["too_hard", "note"]);
});

test("shows rep cues and dumbbell weight quick-picks during set feedback", async ({ page, request }) => {
  await request.post(`${apiBase}/sessions`);
  await request.post(`${apiBase}/sessions/current/plan-draft`, {
    data: {
      source: "ai",
      message: "哑铃快选测试计划。",
      checkIn: {
        sleep: "good",
        fatigue: "low",
        hunger: "not_hungry",
        stress: "low",
        painAreas: [],
        availableMinutes: 5
      },
      plan: {
        focus: "dumbbell quick input flow",
        estimatedDurationMinutes: 5,
        warmup: "light warmup",
        cooldown: "stretch",
        safetyNotes: "stop on pain",
        exercises: [
          {
            exerciseId: "dumbbell_fly_e2e",
            name: "哑铃飞鸟",
            category: "push",
            restSeconds: 1,
            tempo: [
              { phase: "lower", seconds: 1, visual: "shrink" },
              { phase: "lift", seconds: 1, visual: "expand" }
            ],
            notes: "quick input test",
            targetSets: [{ setIndex: 1, targetReps: 4, targetWeight: 2.5, weightUnit: "kg", restSeconds: 1 }],
            completedSets: []
          }
        ]
      }
    }
  });

  await page.goto("/");
  await expect(page.getByText("计划确认")).toBeVisible();
  await page.getByRole("button", { name: "接受计划" }).click();

  await expect(page.getByText("第 1 / 4 次")).toBeVisible();
  await expect(page.getByLabel("当前动作次数")).toContainText("1 / 4");
  await expect(page.getByLabel("发力节奏演示")).toBeVisible();

  await page.getByRole("button", { name: "完成本组" }).click();
  await expect(page.getByText("组后反馈")).toBeVisible();
  await expect(page.getByRole("button", { name: "2.5kg", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "5kg", exact: true })).toBeVisible();

  await page.getByRole("button", { name: "-1" }).click();
  await expect(page.getByLabel("实际次数输入")).toHaveValue("3");
  await page.getByRole("button", { name: "目标" }).click();
  await expect(page.getByLabel("实际次数输入")).toHaveValue("4");

  await page.getByRole("button", { name: "5kg", exact: true }).click();
  await expect(page.getByLabel("实际重量输入")).toHaveValue("5");
});

test("keeps active and feedback screens within an iPad Pro landscape viewport", async ({ page, request }) => {
  await page.setViewportSize({ width: 1366, height: 1024 });
  await request.post(`${apiBase}/sessions`);
  await request.post(`${apiBase}/sessions/current/plan-draft`, {
    data: {
      source: "ai",
      message: "iPad 视口测试计划。",
      checkIn: {
        sleep: "good",
        fatigue: "low",
        hunger: "not_hungry",
        stress: "low",
        painAreas: [],
        availableMinutes: 5
      },
      plan: {
        focus: "ipad viewport flow",
        estimatedDurationMinutes: 5,
        warmup: "light warmup",
        cooldown: "stretch",
        safetyNotes: "stop on pain",
        exercises: [
          {
            exerciseId: "dumbbell_press_viewport",
            name: "哑铃卧推",
            category: "push",
            restSeconds: 1,
            tempo: [
              { phase: "lower", seconds: 1, visual: "shrink" },
              { phase: "peak", seconds: 1, visual: "vibrate" },
              { phase: "lift", seconds: 1, visual: "expand" }
            ],
            notes: "viewport test",
            targetSets: [{ setIndex: 1, targetReps: 8, targetWeight: 7.5, weightUnit: "kg", restSeconds: 1 }],
            completedSets: []
          }
        ]
      }
    }
  });

  await page.goto("/");
  await page.getByRole("button", { name: "接受计划" }).click();
  await expect(page.getByLabel("当前动作次数")).toContainText("1 / 8");

  const activeOverflow = await page.evaluate(() => document.documentElement.scrollHeight - window.innerHeight);
  expect(activeOverflow).toBeLessThanOrEqual(2);

  await page.getByRole("button", { name: "完成本组" }).click();
  await expect(page.getByText("组后反馈")).toBeVisible();
  await expect(page.getByRole("button", { name: "7.5kg", exact: true })).toBeVisible();

  const feedbackOverflow = await page.evaluate(() => document.documentElement.scrollHeight - window.innerHeight);
  expect(feedbackOverflow).toBeLessThanOrEqual(2);
});
