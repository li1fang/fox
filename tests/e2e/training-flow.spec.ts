import { expect, test } from "@playwright/test";

test("completes and confirms a full workout flow", async ({ page, request }) => {
  await request.post("http://127.0.0.1:4187/sessions");
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
