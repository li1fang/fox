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
