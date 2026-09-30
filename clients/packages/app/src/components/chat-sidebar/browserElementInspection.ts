import type { BrowserSidebarInspectResult } from "@comma/native-bridge";

type SelectedInspection = Extract<BrowserSidebarInspectResult, { status: "selected" }>;

const maxUserMessageLength = 4_000;
const maxElementTextLength = 2_000;
const maxHtmlLength = 4_000;
const browserElementInspectionContextPattern =
  /\s*<user-reminder>\s*<browser-element-inspection\s+id="([^"]+)"\s*\/>\s*<browser_element_context>([\s\S]*?)<\/browser_element_context>\s*<\/user-reminder>\s*$/u;

export type BrowserElementInspectionContext = {
  attributes?: string | undefined;
  elementText?: string | undefined;
  inspectionId: string;
  pageTitle?: string | undefined;
  pageUrl: string;
  selector: string;
  tagName: string;
};

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

export function stripBrowserElementInspectionContext(message: string) {
  return message.replace(browserElementInspectionContextPattern, "").trimEnd();
}

export function parseBrowserElementInspectionMessage(message: string): {
  body: string;
  context?: BrowserElementInspectionContext | undefined;
} {
  const match = browserElementInspectionContextPattern.exec(message);
  if (!match) return { body: message };

  const contextText = match[2] ?? "";
  const pageUrl = lineValue(contextText, "Page URL");
  const selector = lineValue(contextText, "Selector");
  const tagName = lineValue(contextText, "Tag");
  if (!pageUrl || !selector || !tagName) {
    return { body: stripBrowserElementInspectionContext(message) };
  }

  const elementText =
    /(?:^|\n)Element text:\n([\s\S]*?)(?=\n\nElement HTML excerpt:|\n<\/browser_element_context>|$)/u.exec(
      contextText
    )?.[1];
  return {
    body: message.slice(0, match.index).trimEnd(),
    context: {
      attributes: lineValue(contextText, "Attributes"),
      elementText: elementText?.trim() || undefined,
      inspectionId: match[1] ?? "",
      pageTitle: lineValue(contextText, "Page title"),
      pageUrl,
      selector,
      tagName,
    },
  };
}

function lineValue(context: string, label: string) {
  const line = context
    .split("\n")
    .find((candidate) => candidate.startsWith(`${label}: `));
  return line?.slice(label.length + 2).trim() || undefined;
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
