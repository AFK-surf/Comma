import { lazySchema } from "../lazy-schema.ts";
import { dynamicUiBaseLevel, dynamicUiFeatureLevels, dynamicUiLevel } from "./level.ts";
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
const text = lazySchema(() => z.string().regex(/\S/));
// Text that may be blank, such as an unlabeled bar.
const caption = lazySchema(() => z.string());
const number = lazySchema(() => z.number());
const brand = lazySchema(() => z.string());
// Card text never holds a clock time or a time zone: the Agent cannot know
// who reads the card or where. Moments travel as ISO times, which the
// template shows in the viewer's own time zone.
const untimed = z
  .string()
  .regex(/^(?![\s\S]*(?:\d{1,2}:\d{2}|\b(?:UTC|GMT)\b))[\s\S]*\S/)
  .meta({ title: "untimed" });
const moment = z.string().meta({ format: "date-time" });
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
// A status is its label alone, or a label with the tone that colors it.
const status = z
  .union([text, z.object({ label: text, tone: tone.optional() })])
  .meta({ title: "status" });
const delta = z
  .object({
    value: text.describe('the change as shown, with its unit and no sign: "37.6%"'),
    direction: z.enum(["up", "down", "flat"]).optional(),
    good: z
      .boolean()
      .optional()
      .describe(
        "whether the change is good; without it a rise is good and a fall is not"
      ),
  })
  .meta({ title: "delta" });

/** Shared chrome: what the card is about and where its facts came from. */
export const cardFrame = {
  title: text,
  meta: untimed.optional().describe("short header context"),
  source: text.optional(),
  sourceBrand: brand.optional(),
  updatedAt: untimed
    .optional()
    .describe('a freshness label without a clock time, such as "截至 9/22"'),
  observedAt: moment.optional().describe("when the facts were read"),
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
  .describe("weather for one place: now, today or the coming days")
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
  .describe("choices to pick one from, such as trains, flights, hotels or plans")
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
      .meta({ limit: 6 })
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
  .describe("one to six key numbers, or progress toward a goal")
  .meta({
    needs: ["metrics", "goal"],
    layouts: "single (1 metric), grid (2 to 6), goal (with any metrics under it)",
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
        averageLabel: text
          .optional()
          .describe(
            'names the dashed line at the mean of the bars, such as "日均 217"'
          ),
      })
      .optional()
      .describe("one bar per period, oldest first; the last bar is the current one"),
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
  .describe(
    "how numbers change over time, or a watchlist of prices; a number per category is bars"
  )
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
  .describe("two or three subjects compared attribute by attribute")
  .meta({
    sameLength: [["rows[].values", "subjects"]],
    layouts: "columns, table (<= 4 rows), versus (2 subjects, scores on every row)",
  });

const zone = z
  .string()
  .regex(/^[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+)*$/)
  .meta({
    title: "zone",
    description:
      "an IANA time zone such as Asia/Tokyo; the card shows a moment beside it in that zone",
  });

const schedule = z
  .object({
    ...cardFrame,
    zone: zone.optional(),
    now: text.optional(),
    events: z
      .array(
        z.object({
          start: text.describe('a clock time such as "09:30", or an ISO time'),
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
  .describe(
    "a day's events, an itinerary of one or several days, or the stages of a process; ISO event times show in zone, where the events happen, or on the viewer's clock without it"
  )
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
                actions: z
                  .array(z.object({ label: text, prompt: text }))
                  .meta({ limit: 3 })
                  .optional()
                  .describe(
                    "this item's follow-ups, such as adding it to the calendar, reminders or Routine; a click proposes the prompt like comma.request"
                  ),
              })
            )
            .min(1),
        })
      )
      .min(1)
      .meta({ limit: 4 })
      .describe("at most 20 items in total"),
  })
  .describe("things to do, pack or check off")
  .meta({ layouts: "progress, grouped (2 or more groups)" });

const composition = z
  .object({
    ...cardFrame,
    total: z.union([text, number]),
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
  .describe("how a total splits into parts that add up to it")
  .meta({ layouts: "stacked, donut" });

const place = z
  .object({
    ...cardFrame,
    places: z
      .array(
        z.object({
          name: text,
          category: text.optional(),
          note: text.optional().describe("what it is or why it fits, in one line"),
          rating: number.optional(),
          reviews: text.optional().describe('a review count such as "2,310 条评价"'),
          status: status.optional(),
          address: text.optional(),
          distance: text.optional(),
          eta: text.optional(),
          href: url.optional(),
        })
      )
      .min(1)
      .meta({ limit: 8 }),
  })
  .describe("places to go: nearby results or recommendations")
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
          time: untimed.optional().describe('a label such as "2 小时前"'),
          at: moment.optional().describe("when it happened"),
          status: status.optional(),
          tags: z.array(text).meta({ limit: 3 }).optional(),
          href: url.optional(),
          filterKeys: z.array(text).meta({ limit: 8 }).optional(),
        })
      )
      .meta({ limit: 60 })
      .optional(),
    filters: z
      .array(z.object({ key: text, label: text }))
      .meta({ limit: 4 })
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
  .describe(
    "news, updates and status lists such as a day's pull requests, issues or CI runs; over 12 items show title, status, source and time, and each filter shows its count"
  )
  .meta({
    needs: ["items", "groups"],
    layouts:
      "news (<= 12 items), list (items without excerpts or tags, or over 12), digest (groups)",
  });

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
  .describe("a countdown to a moment, a focus timer, or days until an event")
  .meta({
    needs: ["endsAt", "remainingSeconds", "daysLeft"],
    layouts: "countdown, event (daysLeft)",
  });

const order = z
  .object({
    ...cardFrame,
    brand: brand.optional(),
    orderId: text.optional(),
    status: text.describe('where the order is, such as "正在出库"'),
    arrival: untimed
      .optional()
      .describe(
        'the expected arrival without a clock time, such as "预计 10月29日 周四 送达"'
      ),
    arrivesBy: moment
      .optional()
      .describe("the latest arrival moment, shown on the viewer's clock"),
    items: z
      .array(
        z.object({
          name: text,
          quantity: z.number().int().min(1).optional(),
          detail: text.optional().describe("a variant such as size or color"),
          price: text.optional(),
        })
      )
      .meta({ limit: 6 })
      .optional(),
    total: text.optional(),
    totalLabel: text.optional().describe('such as "实付"'),
    address: text.optional(),
    stages: z
      .array(z.object({ label: text, state }))
      .min(2)
      .meta({ limit: 5 })
      .optional(),
  })
  .describe(
    "one order and where it is: a purchase, a takeout or a parcel; title names the merchant or carrier"
  )
  .meta({
    layouts: "tracking (stages), receipt (an item with a price, or a total), compact",
  });

const fact = z.object({ label: text, value: text }).meta({ title: "fact" });
const control = z.object({ label: text, prompt: text }).meta({
  title: "control",
  description: "a click proposes the prompt like an action",
});

const endpoint = z.object({
  place: text.describe("station, airport or stop"),
  code: text.optional().describe("such as PVG"),
  at: moment,
  zone: zone.optional(),
  terminal: text.optional(),
});
const ticket = z
  .object({
    ...cardFrame,
    brand: brand.optional(),
    mode: z.enum(["train", "flight"]).optional(),
    number: text.describe("train or flight number"),
    depart: endpoint,
    arrive: endpoint,
    duration: untimed.optional(),
    details: z
      .array(fact)
      .meta({ limit: 4 })
      .optional()
      .describe("such as seat, gate, cabin or boarding time"),
    passenger: text.optional(),
    status: status.optional(),
    reference: text.optional().describe("booking reference or e-ticket number"),
  })
  .describe("one train or flight ticket, or a boarding pass; title names the carrier")
  .meta({ layouts: "ticket, pass" });

const ride = z
  .object({
    ...cardFrame,
    brand: brand.optional(),
    status: text.describe('such as "司机正在赶来"'),
    eta: untimed.optional().describe('such as "3 分钟"'),
    plate: text.optional(),
    car: text.optional().describe("color and model"),
    driver: z
      .object({ name: text, rating: number.optional(), trips: text.optional() })
      .optional(),
    pickup: text.optional(),
    dropoff: text.optional(),
    fare: text.optional(),
  })
  .describe("a ride on its way or under way; title names the service")
  .meta({ layouts: "pickup (plate), trip (pickup and dropoff)" });

const product = z
  .object({
    ...cardFrame,
    products: z
      .array(
        z.object({
          name: text,
          image: url.optional(),
          price: text,
          originalPrice: text.optional(),
          badge: text.optional().describe('such as "券后" or "包邮"'),
          shop: text.optional(),
          rating: number.optional(),
          sales: text.optional().describe('such as "月销 2万+"'),
          href: url.optional(),
        })
      )
      .min(1)
      .meta({ limit: 6 }),
  })
  .describe("products to buy, with images and prices")
  .meta({ layouts: "hero (1 product), grid (2 to 6), list" });

const booking = z
  .object({
    ...cardFrame,
    brand: brand.optional(),
    status: status.optional(),
    at: moment.describe("when the booking starts"),
    zone: zone.optional(),
    details: z
      .array(fact)
      .meta({ limit: 6 })
      .optional()
      .describe("such as party size, room or department"),
    confirmation: text.optional(),
    address: text.optional(),
  })
  .describe(
    "a reservation or appointment: a table, a room, a doctor; title names the venue"
  )
  .meta({ layouts: "confirmation, compact" });

const device = z
  .object({
    ...cardFrame,
    devices: z
      .array(
        z.object({
          name: text,
          on: z.boolean().optional(),
          online: z.boolean().optional().describe("false shows it offline"),
          value: text.optional().describe('the main reading, such as "26"'),
          unit: text.optional().describe('such as "°C" or "%"'),
          mode: text.optional(),
          detail: text.optional(),
          controls: z.array(control).meta({ limit: 4 }).optional(),
        })
      )
      .min(1)
      .meta({ limit: 6 }),
  })
  .describe("smart home devices, their state and controls")
  .meta({ layouts: "single (1 device), grid (2 to 6)" });

const payment = z
  .object({
    ...cardFrame,
    brand: brand.optional(),
    amount: text,
    status: status,
    counterparty: text.optional().describe("who was paid, or who paid"),
    at: moment.optional(),
    details: z
      .array(fact)
      .meta({ limit: 5 })
      .optional()
      .describe("such as payment method, fee or reference"),
  })
  .describe("a payment, transfer or refund and its result; title names the provider")
  .meta({ layouts: "receipt, compact" });

const media = z
  .object({
    ...cardFrame,
    brand: brand.optional(),
    track: text.describe("song, episode or video"),
    artist: text.optional(),
    album: text.optional(),
    cover: url.optional(),
    playing: z.boolean().optional(),
    position: z.number().min(0).optional().describe("seconds"),
    duration: z.number().min(0).optional().describe("seconds"),
    controls: z
      .object({
        previous: text.optional(),
        toggle: text.optional(),
        next: text.optional(),
      })
      .optional()
      .describe("a prompt per button, proposed like an action"),
    queue: z
      .array(z.object({ track: text, artist: text.optional() }))
      .meta({ limit: 5 })
      .optional(),
  })
  .describe("what is playing, or a song or video to play; title names the service")
  .meta({ layouts: "player, queue (needs queue)" });

const bars = z
  .object({
    ...cardFrame,
    items: z
      .array(
        z.object({
          label: text,
          value: number,
          valueLabel: text
            .optional()
            .describe('how the value reads, such as "¥4,500" or "72%"'),
          compare: number
            .optional()
            .describe(
              "the same measure in the other series: the previous period, a budget, a target"
            ),
          compareLabel: text.optional(),
          delta: delta.optional(),
          caption: text
            .optional()
            .describe('a short second line, such as "转化 25% · 中位 38 秒"'),
          status: status.optional(),
          tone: tone
            .optional()
            .describe("colors the bar; warning or error marks a value to act on"),
          brand: brand.optional(),
          href: url.optional(),
        })
      )
      .min(1)
      .meta({ limit: 12 }),
    max: number
      .optional()
      .describe(
        "what a full bar stands for, such as 100 for percentages or a goal; without it, the largest value"
      ),
    legend: z
      .object({ value: text, compare: text })
      .optional()
      .describe(
        'names the two bars of each item, such as {value: "昨日", compare: "前天"}'
      ),
  })
  .describe(
    "a number per category, each a labelled bar: rankings such as top sources, pages or products, survey answers, rating distributions, funnel steps, budget against actual, progress per goal"
  )
  .meta({
    layouts:
      "rows, compact (short labels, no captions or statuses), columns (2 to 7 items with short labels, values only and no max)",
  });

const cell = z
  .union([caption, number, z.null(), z.object({ text: text, tone: tone.optional() })])
  .meta({
    title: "cell",
    description:
      'text, a number, {text, tone?} to color the text, or null or "" for an empty cell',
  });
const table = z
  .object({
    ...cardFrame,
    columns: z
      .array(caption)
      .min(2)
      .meta({ limit: 8 })
      .describe('a heading per column; "" leaves one without'),
    rows: z
      .array(z.array(cell).meta({ limit: 8 }))
      .min(1)
      .meta({ limit: 24 })
      .describe("the first cell names the row"),
  })
  .describe(
    "rows and columns of facts that no other kind shows: a leaderboard with several numbers, orders, hosts and their readings, more than three subjects compared, a cohort grid"
  )
  .meta({ sameLength: [["rows[]", "columns"]], layouts: "grid" });

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
  order,
  ticket,
  ride,
  product,
  booking,
  device,
  payment,
  media,
  bars,
  table,
};

/**
 * The first runtime level (level.ts) that shows all the data this contract
 * accepts for the kind. A new kind takes the level of the change that adds it.
 * So does a kind whose contract now accepts data that an older runtime rejects,
 * drops or shows differently. ui.create gives a widget the highest level among
 * the kinds it uses.
 */
export const cardKindLevels: Record<keyof typeof cardDataSchemas, number> = {
  forecast: 1,
  // Level 2: a status may be plain text.
  options: 2,
  // Level 2: six metrics, and metrics under a goal.
  metric: 2,
  // Level 2: a change without `good` is good only when it rises.
  trend: 2,
  comparison: 1,
  // Level 2: ISO event times, shown in zone.
  schedule: 2,
  checklist: 1,
  // Level 2: total may be a number.
  composition: 2,
  place: 2,
  feed: 2,
  timer: 1,
  order: 1,
  ticket: 2,
  ride: 1,
  product: 1,
  booking: 2,
  device: 1,
  payment: 2,
  media: 1,
  bars: 2,
  table: 2,
};

/** The levels as ui.create reads them from the generated contract. */
export const cardContractLevels = {
  level: dynamicUiLevel,
  base: dynamicUiBaseLevel,
  kinds: cardKindLevels,
  features: dynamicUiFeatureLevels,
};
