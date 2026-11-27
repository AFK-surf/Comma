import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";

import { ProactiveEvalItemSchema, type ProactiveEvalItem } from "./dataset";

const RawSnapshotItemSchema = z
  .object({
    id: z.string().min(1),
    toolkit: z.string().min(1),
    relationship: z.string().min(1),
    title: z.string().nullable().optional(),
    excerpt: z.string().nullable().optional(),
    context: z
      .object({
        text: z.string().nullable().optional(),
      })
      .loose()
      .nullable()
      .optional(),
    url: z.string().min(1),
    app: z.string().nullable().optional(),
    recipient: z.string().nullable().optional(),
    first_seen_at: z.string().datetime({ offset: true }),
    facts: z.record(z.string(), z.json()).nullable().optional(),
    provider_ids: z.record(z.string(), z.json()).nullable().optional(),
    prod_attention: z
      .object({
        outcome: z.string().nullable().optional(),
        decision: z.string().nullable().optional(),
      })
      .loose()
      .nullable()
      .optional(),
  })
  .loose();

const RawStagingSnapshotSchema = z
  .object({
    exported_at: z.string().datetime({ offset: true }),
    profile: z
      .object({
        locale: z.string().min(1).default("en"),
        timezone: z.string().min(1).default("UTC"),
      })
      .loose(),
    portrait_statements: z
      .array(
        z
          .object({
            text: z.string(),
          })
          .loose()
      )
      .default([]),
    notebook: z.string().nullable().optional(),
    home: z
      .array(
        z
          .object({
            from: z.string().min(1),
            text: z.string(),
            created_at: z.number().int().optional(),
          })
          .loose()
      )
      .default([]),
    known_matters: z.array(z.record(z.string(), z.json())).default([]),
    selected_items: z.array(RawSnapshotItemSchema).min(1),
    pool_items: z.array(RawSnapshotItemSchema).default([]),
  })
  .loose();

const EMAIL_RE = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/gu;
const OTP_RE = /\b(\d{6})\b/gu;

export function redactText(value: string): string {
  return value
    .replaceAll(EMAIL_RE, "[redacted-email]")
    .replaceAll(OTP_RE, "[redacted-code]");
}

function maybeRedact(value: string, redact: boolean): string {
  return redact ? redactText(value) : value;
}

export function buildShadowDatasetFromSnapshot(
  rawSnapshot: unknown,
  options: {
    name: string;
    description?: string;
    redact?: boolean;
    itemIds?: Set<string>;
  }
): { name: string; description: string; items: ProactiveEvalItem[] } {
  const snapshot = RawStagingSnapshotSchema.parse(rawSnapshot);
  const redact = options.redact === true;

  const selected = options.itemIds
    ? snapshot.selected_items.filter((item) => options.itemIds!.has(item.id))
    : snapshot.selected_items;

  const items = selected.map((item) => {
    const firstSeenMs = Date.parse(item.first_seen_at);
    const pastPool = snapshot.pool_items
      .filter(
        (p) =>
          p.id !== item.id &&
          p.url !== item.url &&
          Date.parse(p.first_seen_at) < firstSeenMs
      )
      .slice(0, 60)
      .map((p) => ({
        itemId: p.id,
        toolkit: p.toolkit,
        relationship: p.relationship,
        title: maybeRedact(p.title ?? "", redact),
        excerpt: maybeRedact(p.excerpt ?? "", redact),
        ...(p.context?.text
          ? { contextText: maybeRedact(p.context.text, redact) }
          : {}),
        url: p.url,
        ...(p.app ? { app: p.app } : {}),
        firstSeenAt: p.first_seen_at,
      }));

    const pastHome = snapshot.home
      .filter((h) => h.created_at === undefined || h.created_at < firstSeenMs)
      .map((h) => ({
        from: h.from,
        text: maybeRedact(h.text, redact),
        ...(h.created_at !== undefined ? { createdAtMs: h.created_at } : {}),
      }));

    const safeId = item.id.replaceAll(/[^a-zA-Z0-9._-]/gu, "_").slice(0, 64);
    const tags = [
      item.toolkit,
      item.relationship,
      ...(item.prod_attention?.outcome ? [`prod-${item.prod_attention.outcome}`] : []),
    ];

    return ProactiveEvalItemSchema.parse({
      id: safeId,
      input: {
        kind: "shadow_diff",
        tags,
        scenario: {
          context: {
            locale: snapshot.profile.locale,
            timezone: snapshot.profile.timezone,
            portraitStatements: snapshot.portrait_statements.map((s) =>
              maybeRedact(s.text, redact)
            ),
            ...(snapshot.notebook
              ? { notebook: maybeRedact(snapshot.notebook, redact) }
              : {}),
            home: pastHome,
            knownMatters: [],
            poolItems: pastPool,
          },
          items: [
            {
              itemId: item.id,
              toolkit: item.toolkit,
              relationship: item.relationship,
              title: maybeRedact(item.title ?? "", redact),
              excerpt: maybeRedact(item.excerpt ?? "", redact),
              ...(item.context?.text
                ? { contextText: maybeRedact(item.context.text, redact) }
                : {}),
              url: item.url,
              ...(item.app ? { app: item.app } : {}),
              ...(item.recipient
                ? { recipient: maybeRedact(item.recipient, redact) }
                : {}),
              firstSeenAt: item.first_seen_at,
              ...(item.facts ? { facts: item.facts } : {}),
              ...(item.provider_ids ? { providerIds: item.provider_ids } : {}),
            },
          ],
        },
      },
      expected: {},
    });
  });

  return {
    name: options.name,
    description:
      options.description ??
      `Proactive shadow dataset exported at ${snapshot.exported_at} (${items.length} items).`,
    items,
  };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const getArg = (flag: string): string | undefined => {
    const idx = args.indexOf(flag);
    return idx >= 0 ? args[idx + 1] : undefined;
  };
  const snapshotPath = getArg("--snapshot");
  const outDir = getArg("--out-dir");
  const name = getArg("--name") ?? "proactive-shadow-v1";
  const resultsFilterPath = getArg("--only-results");
  const redact = args.includes("--redact");

  if (!snapshotPath || !outDir) {
    throw new Error(
      "Usage: bun run experiments/proactive/build-shadow-dataset.ts --snapshot <path> --out-dir <dir> [--name <slug>] [--only-results <shadow.json>] [--redact]"
    );
  }

  let itemIds: Set<string> | undefined;
  if (resultsFilterPath) {
    const resRaw = JSON.parse(await readFile(resultsFilterPath, "utf8")) as {
      results?: { item?: { item_id?: string } }[];
    };
    itemIds = new Set(
      (resRaw.results ?? [])
        .map((r) => r.item?.item_id)
        .filter((id): id is string => typeof id === "string")
    );
  }

  const rawSnapshot: unknown = JSON.parse(await readFile(snapshotPath, "utf8"));
  const dataset = buildShadowDatasetFromSnapshot(rawSnapshot, {
    name,
    redact,
    ...(itemIds ? { itemIds } : {}),
  });
  await mkdir(outDir, { recursive: true });
  const target = path.join(outDir, "dataset.json");
  await writeFile(target, JSON.stringify(dataset, null, 2), "utf8");
  console.log(`wrote ${dataset.items.length} items to ${target} (redact=${redact})`);
}
