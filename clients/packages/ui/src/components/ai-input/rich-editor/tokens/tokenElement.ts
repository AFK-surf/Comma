import type { AiInputRichTokenSegment } from "../../richText";
import {
  aiInputRichToken,
  aiInputRichTokenIcon,
  aiInputRichTokenLabel,
} from "../../styles";
import { sanitizedTokenIconElement } from "./tokenIcon";

export function createTokenElement(
  token: AiInputRichTokenSegment,
  tooltipId: string,
  disabled: boolean
) {
  const element = document.createElement("button");
  element.className = aiInputRichToken;
  element.contentEditable = "false";
  element.dataset.active = "false";
  element.dataset.aiInputToken = token.instanceId;
  element.dataset.menuId = token.menuId;
  element.dataset.itemId = token.itemId;
  element.disabled = disabled;
  element.setAttribute("aria-pressed", "false");
  element.setAttribute("type", "button");
  if (token.description) element.setAttribute("aria-describedby", tooltipId);

  const label = document.createElement("span");
  label.className = aiInputRichTokenLabel;
  label.textContent = token.label;

  const icon = token.iconMarkup ? sanitizedTokenIconElement(token.iconMarkup) : null;
  if (icon) {
    const iconSlot = document.createElement("span");
    iconSlot.className = aiInputRichTokenIcon;
    iconSlot.setAttribute("aria-hidden", "true");
    iconSlot.append(icon);
    element.append(iconSlot);
  }
  element.append(label);
  return element;
}

export function createTokenSpacer() {
  const spacer = document.createElement("span");
  spacer.contentEditable = "false";
  spacer.dataset.aiInputTokenSpacer = "";
  spacer.setAttribute("aria-hidden", "true");
  return spacer;
}

export function closestTokenElement(target: EventTarget | null) {
  if (!(target instanceof Element)) return null;
  return target.closest<HTMLElement>("[data-ai-input-token]");
}

export function findTokenElement(editor: HTMLElement, tokenId: string) {
  return Array.from(editor.querySelectorAll<HTMLElement>("[data-ai-input-token]")).find(
    (token) => token.dataset.aiInputToken === tokenId
  );
}
