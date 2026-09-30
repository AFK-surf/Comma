import { Client as McpClient } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { z } from "zod";

import type { ExternalResourceObservation, ExternalResourceObserver } from "./types";
import { createExternalObservation } from "./types";

const NotionNotFoundErrorSchema = z
  .object({ code: z.literal("object_not_found") })
  .loose();
const UnknownRecordSchema = z.record(z.string(), z.unknown());
const McpTextBlockSchema = z
  .object({ type: z.literal("text"), text: z.string() })
  .loose();

export type NotionPageTarget = ({ pageId: string } | { title: string }) & {
  /** When supplied, the observer verifies the fetched page's ancestor path. */
  expectedParentId?: string;
};

export type NotionPageResource = {
  id: string;
  title?: string;
  url?: string;
  archived?: boolean;
  expectedParentId?: string;
  parentMatched?: boolean;
};

export type NotionObservation = ExternalResourceObservation<NotionPageResource>;

/**
 * This boundary intentionally models the official hosted MCP rather than the
 * public Notion data API. Evalens materializes a Notion MCP OAuth token, whose
 * audience is mcp.notion.com; @notionhq/client expects a different API token and
 * cannot safely reuse that credential.
 */
export type NotionObserverClient = {
  fetch(pageId: string): Promise<unknown>;
  search?(title: string): Promise<unknown>;
};

export class NotionMcpPageObserver implements ExternalResourceObserver<
  NotionPageTarget,
  NotionObservation
> {
  readonly provider = "notion" as const;

  constructor(
    accessToken: string,
    private readonly client: NotionObserverClient = new HostedNotionMcpClient(
      accessToken
    ),
    private readonly now: () => Date = () => new Date()
  ) {}

  async observe(target: NotionPageTarget): Promise<NotionObservation> {
    const lookup = "pageId" in target ? target.pageId : `title=${target.title}`;
    try {
      let pageId: string | undefined;
      if ("pageId" in target) {
        pageId = target.pageId;
      } else {
        if (!this.client.search) {
          throw new Error("Notion observer client does not support search");
        }
        pageId = pageIdFromSearch(await this.client.search(target.title), target.title);
      }
      if (!pageId) {
        return createExternalObservation({
          provider: this.provider,
          resourceType: "page",
          lookup,
          now: this.now,
        });
      }
      const payload = await this.client.fetch(pageId);
      const serialized = JSON.stringify(payload);
      const expectedParentId = target.expectedParentId;
      const title = findString(payload, ["title"]);
      const url = findString(payload, ["url", "href"]);
      const archived = findBoolean(payload, ["is_archived", "archived", "in_trash"]);
      return createExternalObservation({
        provider: this.provider,
        resourceType: "page",
        lookup,
        resource: {
          id: pageId,
          ...(title ? { title } : {}),
          ...(url ? { url } : {}),
          ...(archived === undefined ? {} : { archived }),
          ...(expectedParentId
            ? {
                expectedParentId,
                parentMatched: serialized
                  .toLowerCase()
                  .replaceAll("-", "")
                  .includes(expectedParentId.toLowerCase().replaceAll("-", "")),
              }
            : {}),
        },
        now: this.now,
      });
    } catch (error) {
      if (!NotionNotFoundErrorSchema.safeParse(error).success) throw error;
      return createExternalObservation({
        provider: this.provider,
        resourceType: "page",
        lookup,
        now: this.now,
      });
    }
  }
}

class HostedNotionMcpClient implements NotionObserverClient {
  constructor(
    private readonly accessToken: string,
    private readonly endpoint = "https://mcp.notion.com/mcp"
  ) {}

  async fetch(pageId: string): Promise<unknown> {
    return this.callTool("notion-fetch", { id: pageId });
  }

  async search(title: string): Promise<unknown> {
    return this.callTool("notion-search", {
      query: title,
      query_type: "internal",
    });
  }

  private async callTool(
    name: "notion-fetch" | "notion-search",
    args: Record<string, unknown>
  ): Promise<unknown> {
    const client = new McpClient({ name: "evalens-observer", version: "1.0.0" });
    const transport = new StreamableHTTPClientTransport(new URL(this.endpoint), {
      requestInit: {
        headers: {
          Authorization: `Bearer ${this.accessToken}`,
          "User-Agent": "Evalens-Observer/1.0",
        },
      },
    });
    try {
      await client.connect(transport);
      const result = await client.callTool({
        name,
        arguments: args,
      });
      const text = Array.isArray(result.content)
        ? result.content.flatMap((block) => {
            const parsed = McpTextBlockSchema.safeParse(block);
            return parsed.success ? [parsed.data.text] : [];
          })
        : [];
      const joinedText = text.join("\n");
      if (result.isError) {
        throw new NotionMcpToolError(joinedText);
      }
      if (!joinedText) throw new Error(`${name} returned no text content`);
      try {
        return JSON.parse(joinedText);
      } catch {
        // Some server versions return Notion-flavored markup directly. Keeping
        // the text wrapped makes metadata extraction and parent matching stable.
        return { text: joinedText };
      }
    } finally {
      await client.close().catch(() => undefined);
    }
  }
}

class NotionMcpToolError extends Error {
  readonly code: string;

  constructor(message: string) {
    super(message || "notion-fetch failed");
    this.code = /(?:not found|could not find|object_not_found)/i.test(message)
      ? "object_not_found"
      : "mcp_tool_error";
  }
}

function pageIdFromSearch(payload: unknown, expectedTitle: string): string | undefined {
  if (Array.isArray(payload)) {
    for (const item of payload) {
      const id = pageIdFromSearch(item, expectedTitle);
      if (id) return id;
    }
    return undefined;
  }
  const parsed = UnknownRecordSchema.safeParse(payload);
  if (!parsed.success) return undefined;
  const record = parsed.data;
  const title = findString(record, ["title", "name"]);
  if (title === expectedTitle) {
    const directId = findString(record, ["id", "page_id"]);
    if (directId) return directId;
    const url = findString(record, ["url", "href"]);
    const idFromUrl = url?.match(
      /([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|[0-9a-f]{32})(?:\?|$)/i
    )?.[1];
    if (idFromUrl) return idFromUrl;
  }
  for (const item of Object.values(record)) {
    const id = pageIdFromSearch(item, expectedTitle);
    if (id) return id;
  }
  return undefined;
}

function findString(value: unknown, keys: string[]): string | undefined {
  return findValue(
    value,
    keys,
    (candidate): candidate is string => typeof candidate === "string"
  );
}

function findBoolean(value: unknown, keys: string[]): boolean | undefined {
  return findValue(
    value,
    keys,
    (candidate): candidate is boolean => typeof candidate === "boolean"
  );
}

function findValue<T>(
  value: unknown,
  keys: string[],
  predicate: (candidate: unknown) => candidate is T
): T | undefined {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findValue(item, keys, predicate);
      if (found !== undefined) return found;
    }
    return undefined;
  }
  const parsed = UnknownRecordSchema.safeParse(value);
  if (!parsed.success) return undefined;
  const record = parsed.data;
  for (const key of keys) {
    if (predicate(record[key])) return record[key];
  }
  for (const item of Object.values(record)) {
    const found = findValue(item, keys, predicate);
    if (found !== undefined) return found;
  }
  return undefined;
}
