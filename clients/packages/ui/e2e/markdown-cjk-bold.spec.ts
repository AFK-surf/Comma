import { expect, test } from "@playwright/test";

test("CJK bold labels survive streamed prose, completion and compiled handoff", async ({
  page,
}) => {
  test.slow();
  await page.goto(
    "/iframe.html?id=app-components-markdown-stream--cjk-bold-labels&viewMode=story",
    { waitUntil: "domcontentloaded" }
  );
  const preview = page;
  const markdown = preview.locator(".markdown-stream");
  await expect(markdown.locator("strong")).toHaveText(["做什么："], {
    timeout: 60_000,
  });

  await preview.getByRole("button", { name: "Append prose", exact: true }).click();
  const assertLabels = async () => {
    await expect(markdown.locator("strong")).toHaveText([
      "做什么：",
      "和普通大模型有什么不同：",
      "为什么引人关注：",
      "怎么用：",
    ]);
    await expect(markdown.locator("li").first()).toHaveText("做什么：它是模型。");
    await expect(markdown.locator("code")).toHaveText("**代码：**正文");
  };
  await assertLabels();
  await preview.getByRole("button", { name: "Finish stream", exact: true }).click();
  await assertLabels();
  await preview
    .getByRole("button", { name: "Use compiled nodes", exact: true })
    .click();
  await assertLabels();
});
