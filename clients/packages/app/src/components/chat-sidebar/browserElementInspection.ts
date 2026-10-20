import type { BrowserSidebarInspectResult } from "@comma/native-bridge";

type SelectedInspection = Extract<BrowserSidebarInspectResult, { status: "selected" }>;

const maxUserMessageLength = 4_000;
const maxElementTextLength = 2_000;
const maxHtmlLength = 4_000;
const screenshotName = "inspected-element.png";

export function buildBrowserElementInspectionMessage(inspection: SelectedInspection) {
  const userMessage = clipped(inspection.userMessage.trim(), maxUserMessageLength);
  const lines = [
    userMessage || "Inspect this selected page element.",
    "",
    "<user-reminder>",
    `<browser-element-inspection id="${escapedAttribute(inspection.inspectionId)}" />`,
    "<browser_element_context>",
  ];

  if (inspection.page.title?.trim()) {
    lines.push(`Page title: ${inspection.page.title.trim()}`);
  }
  lines.push(`Page URL: ${inspection.page.url}`);
  lines.push(`Selector: ${inspection.element.selector}`);
  lines.push(`Tag: ${inspection.element.tagName}`);

  const attributes = Object.entries(inspection.element.attributes)
    .toSorted(([left], [right]) => left.localeCompare(right))
    .map(([name, value]) => `${name}=${value}`)
    .join(", ");
  if (attributes) lines.push(`Attributes: ${attributes}`);

  const { rect } = inspection.element;
  lines.push(
    `Bounding rect: x=${rounded(rect.x)}, y=${rounded(rect.y)}, width=${rounded(rect.width)}, height=${rounded(rect.height)}`
  );
  if (inspection.screenshot) lines.push(`Screenshot: attached as ${screenshotName}`);

  if (inspection.element.text?.trim()) {
    lines.push(
      "",
      "Element text:",
      clipped(inspection.element.text.trim(), maxElementTextLength)
    );
  }
  if (inspection.element.outerHTML?.trim()) {
    lines.push(
      "",
      "Element HTML excerpt:",
      "```html",
      clipped(inspection.element.outerHTML.trim(), maxHtmlLength),
      "```"
    );
  }

  lines.push("</browser_element_context>", "</user-reminder>");
  return lines.join("\n");
}

/**
 * The element's screenshot as a file of its message: the chat shows it, and the agent reads it beside the DOM in the
 * message's text. None when the element was not on screen.
 */
export function browserElementInspectionFiles(inspection: SelectedInspection) {
  const { screenshot } = inspection;
  return screenshot
    ? [{ bytes: screenshot, name: screenshotName, size: screenshot.byteLength }]
    : [];
}

function clipped(value: string, maxLength: number) {
  return value.length <= maxLength
    ? value
    : `${value.slice(0, maxLength)}\n...[truncated]`;
}

function escapedAttribute(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function rounded(value: number) {
  return String(Math.round(value * 10) / 10);
}
