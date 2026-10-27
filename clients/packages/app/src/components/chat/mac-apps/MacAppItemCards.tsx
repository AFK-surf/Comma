import type { ChatMacAppItem, ChatMessagePart } from "@comma/chat-contract";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { Button } from "@comma/ui/components/Button";
import { memo, type CSSProperties } from "react";
import { appIcon, appName, useMacAppIcons } from "../../plugins/MacApps";
import "./mac-app-item.css";

/**
 * The Mac app cards a message carries, after its text: each item an Agent made
 * or found on the user's Mac (an event, a reminder, a note, a person, a place),
 * drawn as its app draws it. On the Mac, a card opens the item in its app.
 */

type MacAppItemPart = Extract<ChatMessagePart, { kind: "mac-app-item" }>;
type Messages = ReturnType<typeof useCommaMessages>;

export const MessageMacAppItemCards = memo(function MessageMacAppItemCards({
  message,
}: {
  message: { parts?: readonly ChatMessagePart[] | undefined };
}) {
  const items = (message.parts ?? [])
    .filter((part): part is MacAppItemPart => part.kind === "mac-app-item")
    .map((part) => part.item);
  const icons = useMacAppIcons();
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  if (items.length === 0) return null;
  const bridge = getNativeBridge();
  const onMac = bridge.platform === "electron" && bridge.os === "macos";
  return (
    <ul className="comma-mac-item-list">
      {items.map((item, index) => (
        <li
          className="comma-mac-item"
          data-app={item.app}
          key={`${item.app}-${item.itemId ?? item.title}-${index}`}
        >
          <header className="comma-mac-item-head">
            <span aria-hidden className="comma-mac-item-icon">
              {appIcon(icons, item.app)}
            </span>
            <span className="comma-mac-item-app">{appName(messages, item.app)}</span>
            {onMac ? (
              <Button
                className="comma-mac-item-open"
                hierarchy="tertiary-gray"
                onPress={() =>
                  void bridge.macApps
                    .openItem({
                      app: item.app,
                      ...(item.itemId ? { itemId: item.itemId } : {}),
                      title: item.title,
                      ...(item.latitude !== undefined && item.longitude !== undefined
                        ? { latitude: item.latitude, longitude: item.longitude }
                        : {}),
                    })
                    .catch(() => undefined)
                }
                size="sm"
              >
                {messages.chat_mac_item_open({ app: appName(messages, item.app) })}
              </Button>
            ) : null}
          </header>
          <ItemBody item={item} locale={locale} messages={messages} />
        </li>
      ))}
    </ul>
  );
});

function ItemBody({
  item,
  locale,
  messages,
}: {
  item: ChatMacAppItem;
  locale: string;
  messages: Messages;
}) {
  const accent = item.color
    ? ({ "--mac-item-accent": item.color } as CSSProperties)
    : undefined;
  switch (item.app) {
    case "calendar":
      return (
        <div className="comma-mac-item-body comma-mac-item-event" style={accent}>
          <span aria-hidden className="comma-mac-item-bar" />
          <div className="comma-mac-item-text">
            <p className="comma-mac-item-title">{item.title}</p>
            <p className="comma-mac-item-meta">
              {item.allDay
                ? joined([day(item.start, locale), messages.chat_mac_item_all_day()])
                : timeRange(item.start, item.end, locale)}
            </p>
            <p className="comma-mac-item-meta">
              {joined([item.calendar, item.location])}
            </p>
          </div>
        </div>
      );
    case "reminders":
      return (
        <div className="comma-mac-item-body comma-mac-item-reminder" style={accent}>
          <span
            aria-label={item.completed ? messages.chat_mac_item_completed() : undefined}
            className="comma-mac-item-check"
            data-completed={item.completed ? "" : undefined}
            role={item.completed ? "img" : undefined}
          />
          <div className="comma-mac-item-text">
            <p className="comma-mac-item-title">{item.title}</p>
            <p className="comma-mac-item-meta">
              {joined([dateTime(item.due, locale), item.list])}
            </p>
          </div>
        </div>
      );
    case "contacts":
      return (
        <div className="comma-mac-item-body comma-mac-item-contact">
          <span aria-hidden className="comma-mac-item-initials">
            {initials(item.title)}
          </span>
          <div className="comma-mac-item-text">
            <p className="comma-mac-item-title">{item.title}</p>
            <p className="comma-mac-item-meta">{item.detail}</p>
          </div>
        </div>
      );
    case "maps":
      return (
        <div className="comma-mac-item-body">
          <div className="comma-mac-item-text">
            <p className="comma-mac-item-title">{item.title}</p>
            <p className="comma-mac-item-meta">
              {joined([item.category, item.address])}
            </p>
          </div>
        </div>
      );
    case "notes":
      return (
        <div className="comma-mac-item-body comma-mac-item-note">
          <div className="comma-mac-item-text">
            <p className="comma-mac-item-title">{item.title}</p>
            <p className="comma-mac-item-meta">{item.folder}</p>
          </div>
        </div>
      );
  }
}

function joined(values: readonly (string | undefined)[]) {
  return values.filter(Boolean).join(" · ");
}

/** A date the Mac app gave: a day (`2026-10-20`) or an instant (`…T10:00:00Z`). */
function parsed(value: string | undefined) {
  if (!value) return undefined;
  const dayOnly = /^\d{4}-\d{2}-\d{2}$/.test(value);
  const date = new Date(dayOnly ? `${value}T00:00:00` : value);
  return Number.isNaN(date.getTime()) ? undefined : { date, dayOnly };
}

function day(value: string | undefined, locale: string) {
  const at = parsed(value);
  return at
    ? new Intl.DateTimeFormat(locale, {
        weekday: "short",
        month: "short",
        day: "numeric",
      }).format(at.date)
    : undefined;
}

function dateTime(value: string | undefined, locale: string) {
  const at = parsed(value);
  if (!at) return undefined;
  return new Intl.DateTimeFormat(
    locale,
    at.dayOnly
      ? { weekday: "short", month: "short", day: "numeric" }
      : {
          weekday: "short",
          month: "short",
          day: "numeric",
          hour: "numeric",
          minute: "2-digit",
        }
  ).format(at.date);
}

function timeRange(start: string | undefined, end: string | undefined, locale: string) {
  const from = parsed(start);
  if (!from) return undefined;
  const to = parsed(end);
  const time = new Intl.DateTimeFormat(locale, { hour: "numeric", minute: "2-digit" });
  const range = to ? time.formatRange(from.date, to.date) : time.format(from.date);
  return joined([day(start, locale), range]);
}

/** Initials as Contacts draws a person without a photo; a CJK name shows its first character. */
function initials(name: string) {
  const trimmed = name.trim();
  if (
    /^\p{Script=Han}|^\p{Script=Hangul}|^\p{Script=Hiragana}|^\p{Script=Katakana}/u.test(
      trimmed
    )
  )
    return [...trimmed][0]!;
  const words = trimmed.split(/\s+/);
  const letters =
    words.length > 1 ? words[0]![0]! + words.at(-1)![0]! : [...trimmed][0]!;
  return letters.toUpperCase();
}
