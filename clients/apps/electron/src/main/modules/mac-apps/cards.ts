import type { MacAppId } from "@comma/native-bridge";

/**
 * The chat cards of a Mac apps tool result: what the call made or found
 * (an event, a reminder, a note, a person, a place), as `mac_app_item` content
 * blocks the Agent puts in its reply. Clients draw each as the app draws it,
 * with a way to open it there; others show the text fallback Salix adds.
 */

export type MacAppCardApp = Extract<
  MacAppId,
  "calendar" | "reminders" | "notes" | "contacts" | "maps"
>;

export interface MacAppItemBlock {
  type: "mac_app_item";
  app: MacAppCardApp;
  item_id?: string;
  title: string;
  start?: string;
  end?: string;
  all_day?: boolean;
  calendar?: string;
  color?: string;
  location?: string;
  due?: string;
  completed?: boolean;
  list?: string;
  folder?: string;
  detail?: string;
  address?: string;
  latitude?: number;
  longitude?: number;
  category?: string;
}

/** More cards than this in one reply is a list, which reads better as text. */
export const MAX_CARDS = 5;

type Record_ = Record<string, unknown>;

export function macAppCards(tool: string, result: unknown): MacAppItemBlock[] {
  if (!isRecord(result) || result.isError === true) return [];
  const data = result.structuredContent;
  if (!isRecord(data)) return [];
  const cards = cardsOf(tool, data);
  return cards.slice(0, MAX_CARDS);
}

function cardsOf(tool: string, data: Record_): MacAppItemBlock[] {
  switch (tool) {
    case "calendar_create_event":
    case "calendar_update_event":
      return one(event(data.event));
    case "calendar_list_events":
      return many(data.events, event);
    case "reminders_create":
    case "reminders_update":
    case "reminders_complete":
      return one(reminder(data.reminder));
    case "reminders_list":
      return many(data.reminders, reminder);
    case "notes_create":
    case "notes_read":
      return one(note(data));
    case "notes_search":
      return many(data.notes, note);
    case "contacts_get":
      return one(contact(data.contact));
    case "contacts_search":
      return many(data.contacts, contact);
    case "maps_search_places":
      return many(data.places, place);
    default:
      return [];
  }
}

function one(block: MacAppItemBlock | undefined) {
  return block ? [block] : [];
}

function many(values: unknown, make: (value: unknown) => MacAppItemBlock | undefined) {
  return Array.isArray(values) ? values.flatMap((value) => one(make(value))) : [];
}

function event(value: unknown): MacAppItemBlock | undefined {
  if (!isRecord(value)) return undefined;
  return card("calendar", text(value.title), {
    item_id: text(value.id),
    start: text(value.start),
    end: text(value.end),
    all_day: value.all_day === true,
    calendar: text(value.calendar),
    color: color(value.calendar_color),
    location: text(value.location),
  });
}

function reminder(value: unknown): MacAppItemBlock | undefined {
  if (!isRecord(value)) return undefined;
  return card("reminders", text(value.title), {
    item_id: text(value.id),
    due: text(value.due),
    completed: value.completed === true,
    list: text(value.list),
    color: color(value.list_color),
  });
}

function note(value: unknown): MacAppItemBlock | undefined {
  if (!isRecord(value)) return undefined;
  return card("notes", text(value.name), {
    item_id: text(value.id),
    folder: text(value.folder),
  });
}

function contact(value: unknown): MacAppItemBlock | undefined {
  if (!isRecord(value)) return undefined;
  const first = (list: unknown) =>
    Array.isArray(list) && isRecord(list[0]) ? text(list[0].value) : undefined;
  return card("contacts", text(value.name) ?? text(value.organization), {
    item_id: text(value.id),
    detail: first(value.phones) ?? first(value.emails),
  });
}

function place(value: unknown): MacAppItemBlock | undefined {
  if (!isRecord(value)) return undefined;
  return card("maps", text(value.name), {
    address: text(value.address),
    latitude: number(value.latitude),
    longitude: number(value.longitude),
    category: text(value.category),
  });
}

function card(
  app: MacAppCardApp,
  title: string | undefined,
  fields: {
    [K in keyof Omit<MacAppItemBlock, "type" | "app" | "title">]?:
      | MacAppItemBlock[K]
      | undefined;
  }
): MacAppItemBlock | undefined {
  if (!title) return undefined;
  const block: MacAppItemBlock = { type: "mac_app_item", app, title };
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined || value === false || value === "") continue;
    (block as unknown as Record_)[key] = value;
  }
  return block;
}

/** What the Agent reads after the result: the cards, and how to show them. */
export function cardInstruction(cards: readonly MacAppItemBlock[]) {
  return [
    "To show the user what this changed or found as cards like the Mac app draws them, put these blocks, unchanged, into the content of your reply message after its text (im_api.internal.send_message content), at most once per item:",
    JSON.stringify(cards),
  ].join("\n");
}

function text(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function number(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function color(value: unknown) {
  const hex = text(value);
  return hex && /^#[0-9A-Fa-f]{6}$/.test(hex) ? hex.toUpperCase() : undefined;
}

function isRecord(value: unknown): value is Record_ {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
