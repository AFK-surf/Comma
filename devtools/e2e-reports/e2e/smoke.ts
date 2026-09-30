import { chromium } from "playwright";

const webURL = process.env.E2E_WEB_URL || "http://127.0.0.1:5173";
const browser = await chromium.launch({
  headless: process.env.E2E_HEADLESS !== "false",
});
const page = await browser.newPage();

try {
  await page.goto(webURL);
  await expectText("Comma E2E Reports");
} finally {
  await browser.close();
}

async function expectText(text: string) {
  const visible = await page.getByText(text).first().isVisible();
  if (!visible) throw new Error(`Expected visible text: ${text}`);
}
