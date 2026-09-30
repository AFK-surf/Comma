import { z } from "zod";

/**
 * What an Agent passes to `comma.card(id, kind, data)`, per kind. This is the one
 * definition of card data: the card data types derive from it, and
 * `pnpm generate:card-contract` renders it into the JSON that ui.create checks
 * card data against and shows the Agent in its manual.
 *
 * The templates stay tolerant of data that bypasses that check: they skip an
 * entry they cannot read and fill optional values with defaults.
 *
 * Meta keys: `limit` is how many entries a list keeps (the rest are dropped,
 * not rejected); `needs` names alternatives of which at least one must be
 * present and non-empty; `sameLength` pairs lists that must have as many
 * entries (`[]` in a path means every entry); `layouts` is manual text.
 */

// Display text. The templates add units, formatting and color, so numbers stay
// JSON numbers.
const text = z.string().regex(/\S/);
// Text that may be blank, such as an unlabeled bar.
const caption = z.string();
const number = z.number();
const brand = z.string();
const url = z
  .string()
  .regex(/^https:\/\/[^\s/?#@]+(?:[/?#]\S*)?$/)
  .meta({ title: "url", description: "an HTTPS URL" });
const tone = z
  .enum(["neutral", "brand", "success", "warning", "error"])
  .meta({ title: "tone" });
const condition = z
  .enum(["clear", "clear-night", "partly-cloudy", "cloudy", "rain", "snow"])
  .meta({ title: "condition" });
const state = z.enum(["done", "current", "upcoming"]).meta({ title: "state" });
const status = z
  .object({ label: text, tone: tone.optional() })
  .meta({ title: "status" });
const delta = z
  .object({
    value: text,
    direction: z.enum(["up", "down", "flat"]).optional(),
    good: z.boolean().optional().describe("true when the change is good"),
  })
  .meta({ title: "delta" });

/** Shared chrome: what the card is about and where its facts came from. */
export const cardFrame = {
  title: text,
  meta: text.optional().describe("short header context"),
  source: text.optional(),
  sourceBrand: brand.optional(),
  updatedAt: text.optional().describe('display text such as "17:05"'),
  actions: z
    .array(z.object({ label: text, prompt: text }))
    .meta({ limit: 2 })
    .optional()
    .describe("a click proposes the prompt like comma.request"),
};

const forecast = z
  .object({
    ...cardFrame,
    location: text.optional(),
    current: z
      .object({
        temperature: number,
        condition: condition.optional(),
        label: text.optional(),
        feelsLike: number.optional(),
        humidity: number.optional().describe("percent"),
        wind: text.optional(),
      })
      .optional(),
    days: z
      .array(
        z.object({
          label: text,
          condition,
          conditionLabel: text,
          high: number,
          low: number,
          precipitation: number.optional().describe("percent"),
        })
      )
      .meta({ limit: 7 })
      .optional(),
    highlight: text.optional(),
  })
  .meta({
    needs: ["days", "current"],
    layouts: "today (needs current), week, compact (current and <= 2 days)",
  });

const options = z
  .object({
    ...cardFrame,
    items: z
      .array(
        z.object({
          primary: text,
          id: text.optional(),
          secondary: text.optional().describe("arrival time"),
          span: text.optional(),
          meta: text.optional(),
          price: text.optional(),
          priceNote: text.optional(),
          status: status.optional(),
          tags: z.array(text).meta({ limit: 3 }).optional(),
          reason: text.optional(),
          recommended: z.boolean().optional(),
          filterKeys: z.array(text).meta({ limit: 8 }).optional(),
        })
      )
      .min(1)
      .meta({ limit: 8 }),
    filters: z
      .array(z.object({ key: text, label: text }))
      .meta({ limit: 4 })
      .optional(),
  })
  .meta({
    layouts:
      "timetable and list (every item has secondary), pick (no item has secondary)",
  });

const metric = z
  .object({
    ...cardFrame,
    metrics: z
      .array(
        z.object({
          label: text,
          value: text.describe("display text"),
          unit: text.optional(),
          delta: delta.optional(),
          caption: text.optional(),
          series: z.array(number).meta({ limit: 64 }).optional(),
        })
      )
      .meta({ limit: 4 })
      .optional(),
    goal: z
      .object({
        current: number,
        target: number,
        valueLabel: text,
        targetLabel: text,
        note: text.optional(),
      })
      .optional(),
  })
  .meta({
    needs: ["metrics", "goal"],
    layouts: "single (1 metric), grid (2 to 4), goal",
  });

const trend = z
  .object({
    ...cardFrame,
    brand: brand.optional(),
    value: text.optional(),
    delta: delta.optional(),
    ranges: z
      .array(
        z.object({
          key: text,
          label: text,
          points: z.array(number).min(2).meta({ limit: 64 }),
          axis: z.array(text).meta({ limit: 6 }),
        })
      )
      .meta({ limit: 4 })
      .optional(),
    bars: z
      .object({
        labels: z.array(caption).min(1).meta({ limit: 31 }),
        values: z.array(number).min(1).meta({ limit: 31 }),
        valueLabels: z.array(caption).meta({ limit: 31 }).optional(),
        averageLabel: text.optional(),
      })
      .optional(),
    series: z
      .array(
        z.object({
          label: text,
          value: text,
          points: z.array(number).min(2).meta({ limit: 64 }),
          brand: brand.optional(),
          delta: delta.optional(),
        })
      )
      .meta({ limit: 6 })
      .optional(),
  })
  .meta({
    needs: ["ranges", "bars", "series"],
    sameLength: [["bars.labels", "bars.values"]],
    layouts: "area (ranges), bars, watchlist (series)",
  });

const comparison = z
  .object({
    ...cardFrame,
    subjects: z
      .array(
        z.object({
          name: text,
          caption: text.optional(),
          recommended: z.boolean().optional(),
          brand: brand.optional(),
        })
      )
      .min(2)
      .meta({ limit: 3 }),
    rows: z
      .array(
        z.object({
          label: text,
          values: z
            .array(text.nullable())
            .meta({ limit: 3 })
            .describe("one per subject; null shows a dash"),
          best: z.number().int().min(0).optional().describe("subject index"),
          scores: z
            .array(z.number().min(0).max(10))
            .min(2)
            .meta({ limit: 2 })
            .optional(),
        })
      )
      .min(1)
      .meta({ limit: 8 }),
    verdict: text.optional(),
  })
  .meta({
    sameLength: [["rows[].values", "subjects"]],
    layouts: "columns, table (<= 4 rows), versus (2 subjects, scores on every row)",
  });

const schedule = z
  .object({
    ...cardFrame,
    now: text.optional(),
    events: z
      .array(
        z.object({
          start: text,
          title: text,
          end: text.optional(),
          detail: text.optional(),
          state: state.optional(),
          tone: tone.optional(),
        })
      )
      .meta({ limit: 8 })
      .optional(),
    stages: z
      .array(z.object({ label: text, state, detail: text.optional() }))
      .min(2)
      .meta({ limit: 6 })
      .optional(),
    summary: text.optional(),
  })
  .meta({
    needs: ["events", "stages"],
    layouts: "agenda and timeline (events), stages",
  });

const checklist = z
  .object({
    ...cardFrame,
    groups: z
      .array(
        z.object({
          label: text.optional(),
          items: z
            .array(
              z.object({
                label: text,
                id: text.optional(),
                detail: text.optional(),
                done: z.boolean().optional(),
              })
            )
            .min(1),
        })
      )
      .min(1)
      .meta({ limit: 4 })
      .describe("at most 12 items in total"),
  })
  .meta({ layouts: "progress, grouped (2 or more groups)" });

const composition = z
  .object({
    ...cardFrame,
    total: text,
    totalLabel: text.optional(),
    segments: z
      .array(
        z.object({
          label: text,
          value: z.number().min(0),
          valueLabel: text.optional(),
          muted: z.boolean().optional(),
        })
      )
      .min(1)
      .meta({ limit: 6 }),
  })
  .meta({ layouts: "stacked, donut" });

const place = z
  .object({
    ...cardFrame,
    places: z
      .array(
        z.object({
          name: text,
          category: text.optional(),
          rating: number.optional(),
          reviews: text.optional(),
          status: status.optional(),
          address: text.optional(),
          distance: text.optional(),
          eta: text.optional(),
          href: url.optional(),
        })
      )
      .min(1)
      .meta({ limit: 5 }),
  })
  .meta({ layouts: "single (1 place), nearby (2 or more)" });

const feed = z
  .object({
    ...cardFrame,
    items: z
      .array(
        z.object({
          source: text,
          title: text,
          brand: brand.optional(),
          excerpt: text.optional(),
          time: text.optional(),
          status: status.optional(),
          href: url.optional(),
        })
      )
      .meta({ limit: 6 })
      .optional(),
    groups: z
      .array(
        z.object({
          source: text,
          summary: text,
          brand: brand.optional(),
          count: z.number().int().min(0).optional(),
          tone: tone.optional(),
        })
      )
      .meta({ limit: 6 })
      .optional(),
  })
  .describe("news, updates and status lists such as pull requests or CI runs")
  .meta({ needs: ["items", "groups"], layouts: "news (items), digest (groups)" });

const timer = z
  .object({
    ...cardFrame,
    label: text,
    endsAt: z.string().meta({ format: "date-time" }).optional(),
    remainingSeconds: number.optional(),
    daysLeft: number.optional(),
    totalSeconds: number.optional(),
    paused: z.boolean().optional(),
    phase: z.enum(["focus", "break"]).optional(),
    cycle: z
      .object({
        current: z.number().int().min(1),
        total: z.number().int().min(1).max(8),
      })
      .optional(),
    date: text.optional(),
    elapsedRatio: z.number().min(0).max(1).optional(),
    note: text.optional(),
  })
  .meta({
    needs: ["endsAt", "remainingSeconds", "daysLeft"],
    layouts: "countdown, event (daysLeft)",
  });

/** Card data per kind, in the order the manual lists them. */
export const cardDataSchemas = {
  forecast,
  options,
  metric,
  trend,
  comparison,
  schedule,
  checklist,
  composition,
  place,
  feed,
  timer,
};
