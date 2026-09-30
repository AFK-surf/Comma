import { createElement, type ComponentType } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { CommaLocale } from "@comma/i18n";
import type { useCommaMessages } from "@comma/i18n/react";
import {
  cardColorTokens,
  cardLengthTokens,
  cardRawTokens,
  type CardCopy,
  type CardIconName,
} from "@comma/chat-contract/dynamic-ui-cards";
import {
  ArrowRightIcon,
  ArrowUpIcon,
  brandMarks,
  CheckIcon,
  CheckLargeIcon,
  ChevronRightSmallIcon,
  CloudIcon,
  CloudySunIcon,
  isBrandKey,
  MoonIcon,
  RainIcon,
  SnowIcon,
  SunIcon,
} from "@comma/ui";

/**
 * Host side of the `comma.card` templates: the glyphs, logos, copy and theme
 * tokens the sandboxed runtime cannot reach on its own.
 */

const cardIcons: Record<CardIconName, ComponentType> = {
  sun: SunIcon,
  moon: MoonIcon,
  cloud: CloudIcon,
  "partly-cloudy": CloudySunIcon,
  rain: RainIcon,
  snow: SnowIcon,
  check: CheckIcon,
  "check-large": CheckLargeIcon,
  "arrow-up": ArrowUpIcon,
  "arrow-right": ArrowRightIcon,
  "chevron-right": ChevronRightSmallIcon,
};

let iconMarkup: Record<string, string> | undefined;

/** Template glyphs as static SVG, rendered once from the icon registry. */
export const cardIconMarkup = () =>
  (iconMarkup ??= Object.fromEntries(
    Object.entries(cardIcons).map(([name, Icon]) => [
      name,
      renderToStaticMarkup(createElement(Icon)),
    ])
  ));

/**
 * Localized template chrome. Placeholders stay in for the runtime to fill.
 * `locale` overrides the active locale, e.g. for a gallery of Chinese data.
 */
export const cardCopy = (
  messages: ReturnType<typeof useCommaMessages>,
  locale?: CommaLocale
): CardCopy => {
  const options = locale ? { locale } : undefined;
  return {
    recommended: messages.chat_ui_card_recommended({}, options),
    alternatives: messages.chat_ui_card_alternatives({}, options),
    high: messages.chat_ui_card_high({}, options),
    low: messages.chat_ui_card_low({}, options),
    feelsLike: messages.chat_ui_card_feels_like({}, options),
    humidity: messages.chat_ui_card_humidity({}, options),
    ongoing: messages.chat_ui_card_ongoing({}, options),
    directions: messages.chat_ui_card_directions({}, options),
    range: messages.chat_ui_card_range({}, options),
    days: messages.chat_ui_card_days({}, options),
    attribute: messages.chat_ui_card_attribute({}, options),
    option: messages.chat_ui_card_option({}, options),
    versus: messages.chat_ui_card_versus({}, options),
    checklistProgress: messages.chat_ui_card_checklist_progress(
      { done: "{done}", total: "{total}" },
      options
    ),
    focus: messages.chat_ui_card_focus({}, options),
    rest: messages.chat_ui_card_rest({}, options),
    paused: messages.chat_ui_card_paused({}, options),
    timeUp: messages.chat_ui_card_time_up({}, options),
    timerCycle: messages.chat_ui_card_timer_cycle(
      { current: "{current}", total: "{total}" },
      options
    ),
  };
};

/**
 * Logos for the brands a card names. Each mark loads its own chunk, so a card
 * pays only for the logos it shows; a name outside the catalog gets none and
 * keeps its monogram.
 */
export const cardBrandIcons = async (names: unknown) => {
  if (!Array.isArray(names)) return {};
  const keys = [...new Set(names)]
    .filter(
      (name): name is string =>
        typeof name === "string" && /^[a-z0-9-]{1,40}$/.test(name)
    )
    .slice(0, 32);
  return Object.fromEntries(
    await Promise.all(
      keys.map(async (key) => {
        // Explicit empty replies settle unknown brands without settling other requests.
        if (!isBrandKey(key)) return [key, ""] as const;
        const Mark = brandMarks[key];
        await Mark.preload();
        return [key, renderToStaticMarkup(createElement(Mark))] as const;
      })
    )
  );
};

/**
 * Resolves the Comma tokens the templates read to concrete values for the
 * current theme and text size. Colors and lengths resolve through hidden
 * probes inside `parent`, so scoped themes apply; lengths arrive in pixels
 * because the sandbox does not share the app's root font size.
 */
export const cardTokenProbe = (parent: HTMLElement) => {
  const container = document.createElement("div");
  container.hidden = true;
  container.setAttribute("aria-hidden", "true");
  const probes: Array<[string, HTMLSpanElement, "color" | "width"]> = [];
  for (const [names, property] of [
    [cardColorTokens, "color"],
    [cardLengthTokens, "width"],
  ] as const) {
    for (const name of names) {
      const probe = document.createElement("span");
      probe.style[property] = `var(${name})`;
      container.append(probe);
      probes.push([name, probe, property]);
    }
  }
  // Insert every probe together: consecutive reads then share one style pass.
  parent.append(container);
  return {
    read() {
      const tokens: Record<string, string> = {};
      for (const [name, probe, property] of probes) {
        const value = getComputedStyle(probe)[property];
        if (value && value !== "auto") tokens[name] = value;
      }
      const inherited = getComputedStyle(parent);
      for (const name of cardRawTokens) {
        const value = inherited.getPropertyValue(name).trim();
        if (value) tokens[name] = value;
      }
      return tokens;
    },
    remove() {
      container.remove();
    },
  };
};
