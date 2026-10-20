// A station's own API as the core reads it over the direct connection: each chat a member has there (`GET /chats`),
// its open jobs (`GET /jobs`), the profiles a new chat can run on (`GET /overview`), and the events that say what
// changed (`GET /events`). Only the fields the core uses are read; the rest is the station's.
import { z } from "zod";

const text = z.string().max(100_000);
const name = z.string().max(4_096);
const nullable = <S extends z.ZodType>(schema: S) =>
  schema.nullish().transform((v) => v ?? null);

/** A message as the station shows it in a chat row (`MessageView`). */
export const messageSchema = z.object({
  seq: z.number().int(),
  ts: nullable(z.string().max(256)),
  authorKind: z.string().max(64),
  author: name,
  authorName: nullable(name),
  text: nullable(text),
  createdAt: z.number().default(0),
});
export type StationMessage = z.output<typeof messageSchema>;

export const cardSchema = z.object({
  type: z.string().max(64),
  options: z
    .array(
      z.object({
        label: name,
        detail: name.optional(),
        recommended: z.boolean().optional(),
        action: z.string().max(64).optional(),
      })
    )
    .max(50)
    .optional(),
  placeholder: name.optional(),
  assignee: name.optional(),
});
export type StationCard = z.output<typeof cardSchema>;

const askedSchema = z.object({
  seq: z.number().int(),
  message: messageSchema,
  before: z.array(messageSchema).max(10).default([]),
  dismissed: z.boolean().optional(),
});

const turnSchema = z.object({
  outcome: nullable(z.string().max(256)),
  ending: z.string().max(64).optional(),
  declared: nullable(z.string().max(64)),
  need: nullable(name).optional(),
  waitFor: nullable(name).optional(),
  detail: nullable(text),
  endedAt: nullable(z.number()),
});
export type StationTurn = z.output<typeof turnSchema>;

export const agentSchema = z.object({
  key: name,
  runtime: nullable(name),
  model: nullable(name),
  effort: nullable(name),
  process: nullable(name),
  pending: z.number().int().default(0),
  lastTurn: nullable(turnSchema),
  watch: z.unknown().optional(),
});
export type StationAgent = z.output<typeof agentSchema>;

/** One chat a member has on a station (`GET /chats`, and `event: chat`). */
export const chatRowSchema = z.object({
  id: name,
  session: name,
  thread: nullable(z.number().int()),
  title: nullable(name),
  agents: z.array(agentSchema).max(50).default([]),
  last: nullable(
    z.object({ seq: z.number().int(), text: nullable(text), createdAt: z.number() })
  ),
  unread: z.boolean().default(false),
  lastActiveAt: z.number().default(0),
  creator: nullable(
    z.object({ id: nullable(name), email: nullable(name), name: nullable(name) })
  ).optional(),
  card: nullable(askedSchema.extend({ card: cardSchema })).optional(),
  decision: nullable(
    askedSchema.extend({ options: cardSchema.shape.options })
  ).optional(),
  need: nullable(askedSchema).optional(),
  pinned: nullable(z.number()).optional(),
  archiveReminderDismissed: z.boolean().optional(),
  archiveRecommended: z.boolean().optional(),
  archiveReviewed: z.boolean().optional(),
});
export type StationChatRow = z.output<typeof chatRowSchema>;

export const chatRowsSchema = z.array(chatRowSchema).max(5_000);

/** An open job (`GET /jobs`). */
export const jobSchema = z.object({
  id: name,
  name: name,
  state: z.string().max(64),
  port: nullable(z.number().int()),
  watch: z.boolean().default(false),
  startedAt: z.number(),
  chat: nullable(
    z.object({ title: nullable(name), archived: nullable(z.unknown()) })
  ).optional(),
});
export type StationJob = z.output<typeof jobSchema>;

export const jobsSchema = z.array(jobSchema).max(2_000);

/** The profiles a new chat can run on (`GET /overview`'s `profiles`). */
export const overviewSchema = z.object({
  profiles: z
    .array(
      z.object({
        id: name,
        runtime: nullable(name),
        runtimes: z.array(name).max(16).optional(),
      })
    )
    .max(200)
    .default([]),
});

/** What `POST /sessions` answers: the new chat's session and its chat. */
export const madeSchema = z.object({
  key: name,
  thread: z.object({ id: z.number().int() }),
});

/** `POST /threads/:id/messages`: the message's number. */
export const sentSchema = z.object({ n: z.number().int() });

/** One entry of a chat (`GET /threads/:id/entries`, and `event: thread`): a message, or an edit of one. */
export const entrySchema = z.object({
  n: z.number().int(),
  kind: z.string().max(32),
  target: nullable(z.number().int()),
  ts: nullable(z.string().max(256)),
  authorKind: z.string().max(64),
  author: name,
  authorName: nullable(name),
  text: nullable(text),
  attachments: z
    .array(
      z.object({ name: name, path: z.string().max(8_192), size: z.number().default(0) })
    )
    .max(50)
    .default([]),
  quotes: z
    .array(z.object({ ts: z.string().max(256).nullish() }))
    .max(50)
    .default([]),
  card: cardSchema.optional(),
  ending: z.string().max(64).optional(),
  at: z.number().default(0),
});
export type StationEntry = z.output<typeof entrySchema>;

export const entriesSchema = z.object({
  last: z.number().int(),
  entries: z.array(entrySchema).max(2_000),
});

/** A chat's summary (`GET /threads/:id`, and `POST /threads`). */
export const threadSchema = z.object({
  id: z.number().int(),
  title: nullable(name),
  autoTitle: nullable(name).optional(),
  firstText: nullable(text).optional(),
  last: z.number().int().default(0),
  read: z.number().int().default(0),
});
export type StationThread = z.output<typeof threadSchema>;

/** A thread event's data: the entries just written. */
export const threadEventSchema = z.object({
  id: z.number().int(),
  entries: z.array(entrySchema).max(2_000),
});

/** `POST /uploads`: where the station keeps the file until a message takes it. */
export const uploadedSchema = z.object({
  name: name,
  path: z.string().max(8_192),
  size: z.number(),
});
