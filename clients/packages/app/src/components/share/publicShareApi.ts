import { z } from "zod";

/**
 * Credential-free reads of one public Task Share. The link token is the only
 * authority; these requests never send cookies or the Comma session.
 */

const artifactSchema = z
  .object({
    type: z.enum(["file", "image"]),
    seq: z.number().int().positive(),
    index: z.number().int().nonnegative(),
    file_name: z.string(),
    mime_type: z.string(),
    size: z.number().int().nonnegative(),
  })
  .strip();

const blockSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("text"), text: z.string() }).strip(),
  z
    .object({
      type: z.enum(["file", "image"]),
      index: z.number().int().nonnegative(),
      file_name: z.string(),
      mime_type: z.string(),
      size: z.number().int().nonnegative(),
    })
    .strip(),
  z.object({ type: z.literal("task_ref") }).strip(),
]);

const messageSchema = z
  .object({
    seq: z.number().int().positive(),
    role: z.enum(["user", "assistant"]),
    created_at: z.number().optional(),
    content: z.array(z.unknown()),
  })
  .strip()
  .transform((message) => ({
    ...message,
    // An unknown future block type is skipped rather than failing the page.
    content: message.content.flatMap((block) => {
      const parsed = blockSchema.safeParse(block);
      return parsed.success ? [parsed.data] : [];
    }),
  }));

const summarySchema = z
  .object({
    title: z.string(),
    shared_at: z.number().nullable(),
    message_count: z.number().int().nonnegative(),
    artifacts: z.array(artifactSchema),
    artifacts_truncated: z.boolean(),
  })
  .strip();

const pageSchema = z
  .object({
    messages: z.array(messageSchema),
    next_after_seq: z.number().int().nonnegative().nullable(),
  })
  .strip();

export type PublicShareArtifact = z.output<typeof artifactSchema>;
export type PublicShareBlock = z.output<typeof blockSchema>;
export type PublicShareMessage = z.output<typeof messageSchema>;
export type PublicShareSummary = z.output<typeof summarySchema>;
export type PublicSharePage = z.output<typeof pageSchema>;

export type PublicShareFailure = "not_found" | "rate_limited" | "unavailable";

export class PublicShareError extends Error {
  constructor(readonly reason: PublicShareFailure) {
    super(reason);
    this.name = "PublicShareError";
  }
}

export type PublicShareClient = ReturnType<typeof createPublicShareClient>;

export function createPublicShareClient(
  baseUrl: string,
  token: string,
  fetchImpl: typeof fetch = (input, init) => fetch(input, init)
) {
  const root = `${baseUrl.replace(/\/+$/, "")}/v1/comma/public/shares/${encodeURIComponent(token)}`;

  async function get(path: string, signal?: AbortSignal) {
    let response: Response;
    try {
      response = await fetchImpl(root + path, {
        credentials: "omit",
        referrerPolicy: "no-referrer",
        ...(signal ? { signal } : {}),
      });
    } catch (error) {
      if (signal?.aborted) throw error;
      throw new PublicShareError("unavailable");
    }
    if (response.status === 404) throw new PublicShareError("not_found");
    if (response.status === 429) throw new PublicShareError("rate_limited");
    if (!response.ok) throw new PublicShareError("unavailable");
    return response;
  }

  return {
    async summary(signal?: AbortSignal): Promise<PublicShareSummary> {
      return summarySchema.parse(await (await get("", signal)).json());
    },
    async messages(afterSeq: number, signal?: AbortSignal): Promise<PublicSharePage> {
      const response = await get(`/messages?after_seq=${afterSeq}&limit=100`, signal);
      return pageSchema.parse(await response.json());
    },
    async attachment(seq: number, index: number, signal?: AbortSignal): Promise<Blob> {
      return (await get(`/attachments/${seq}/${index}`, signal)).blob();
    },
  };
}

/** The share token from a `/s/<token>` page path, if the path has that shape. */
export function shareTokenFromPath(pathname: string): string | undefined {
  const match = /^\/s\/([A-Za-z0-9_-]{43})\/?$/.exec(pathname);
  return match?.[1];
}
