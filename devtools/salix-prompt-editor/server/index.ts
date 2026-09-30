import { stat } from "node:fs/promises";
import { extname, resolve, sep } from "node:path";
import {
  CatalogSchema,
  ExplanationRequestSchema,
  PendingChangesSchema,
} from "../shared/schema";
import { ExplanationService } from "./explanations";
import { JobManager } from "./jobs";
import { CATALOG_PATH, DIST_ROOT } from "./paths";

const PORT = Number.parseInt(process.env.SALIX_PROMPT_EDITOR_PORT ?? "4318", 10);
const HOST = "127.0.0.1";
const csrfToken = crypto.randomUUID();
const jobs = new JobManager();
const explanations = new ExplanationService();
const allowedOrigins = new Set([
  "http://127.0.0.1:4317",
  "http://localhost:4317",
  `http://${HOST}:${PORT}`,
  `http://localhost:${PORT}`,
]);

const mimeTypes: Record<string, string> = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
};

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

function isAllowedOrigin(request: Request): boolean {
  const origin = request.headers.get("origin");
  return origin === null || allowedOrigins.has(origin);
}

function isAuthorized(request: Request): boolean {
  return (
    isAllowedOrigin(request) &&
    request.headers.get("x-salix-prompt-csrf") === csrfToken
  );
}

async function parseJson(request: Request): Promise<unknown> {
  const length = Number.parseInt(request.headers.get("content-length") ?? "0", 10);
  if (length > 20 * 1024 * 1024) throw new Error("请求体超过 20MB 限制");
  if (!request.headers.get("content-type")?.startsWith("application/json")) {
    throw new Error("请求必须使用 application/json");
  }
  return request.json();
}

async function serveStatic(pathname: string): Promise<Response> {
  const requested = pathname === "/" ? "index.html" : pathname.slice(1);
  const candidate = resolve(DIST_ROOT, requested);
  if (!candidate.startsWith(`${DIST_ROOT}${sep}`) && candidate !== DIST_ROOT) {
    return new Response("Not found", { status: 404 });
  }

  try {
    const info = await stat(candidate);
    if (info.isFile()) {
      return new Response(Bun.file(candidate), {
        headers: {
          "content-type": mimeTypes[extname(candidate)] ?? "application/octet-stream",
        },
      });
    }
  } catch {
    // The SPA fallback below owns unknown browser routes.
  }

  const index = Bun.file(resolve(DIST_ROOT, "index.html"));
  if (await index.exists()) {
    return new Response(index, {
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  }
  return new Response("Frontend build not found. Run `bun run build`.", {
    status: 404,
  });
}

const server = Bun.serve({
  hostname: HOST,
  port: PORT,
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === "/api/bootstrap" && request.method === "GET") {
      if (!isAllowedOrigin(request)) return json({ error: "Origin 不受信任" }, 403);
      return json({
        csrfToken,
        codexAvailable: Boolean(Bun.which("codex")),
        currentJob: jobs.snapshot(),
      });
    }

    if (url.pathname === "/api/catalog" && request.method === "GET") {
      if (!isAuthorized(request)) return json({ error: "未授权" }, 403);
      const parsed = CatalogSchema.safeParse(await Bun.file(CATALOG_PATH).json());
      if (!parsed.success) return json({ error: "catalog 数据无效" }, 500);
      return json(parsed.data);
    }

    if (url.pathname === "/api/jobs/current" && request.method === "GET") {
      if (!isAuthorized(request)) return json({ error: "未授权" }, 403);
      return json({ job: jobs.snapshot() });
    }

    if (url.pathname === "/api/jobs/extract" && request.method === "POST") {
      if (!isAuthorized(request)) return json({ error: "未授权" }, 403);
      try {
        const body = (await parseJson(request)) as { draftCount?: unknown };
        if (typeof body.draftCount !== "number" || body.draftCount !== 0) {
          return json({ error: "存在草稿；清空后才能全量提取" }, 409);
        }
        if (jobs.busy()) return json({ error: "已有 Codex 任务正在运行" }, 409);
        return json({ job: jobs.startExtraction() }, 202);
      } catch (error) {
        return json({ error: error instanceof Error ? error.message : String(error) }, 400);
      }
    }

    if (url.pathname === "/api/jobs/apply" && request.method === "POST") {
      if (!isAuthorized(request)) return json({ error: "未授权" }, 403);
      try {
        if (jobs.busy()) return json({ error: "已有 Codex 任务正在运行" }, 409);
        const pending = PendingChangesSchema.parse(await parseJson(request));
        return json({ job: await jobs.startApply(pending) }, 202);
      } catch (error) {
        return json({ error: error instanceof Error ? error.message : String(error) }, 400);
      }
    }

    if (url.pathname === "/api/explanations/resolve" && request.method === "POST") {
      if (!isAuthorized(request)) return json({ error: "未授权" }, 403);
      if (!Bun.which("codex")) return json({ error: "PATH 中找不到 codex CLI" }, 503);
      try {
        const requestBody = ExplanationRequestSchema.parse(await parseJson(request));
        return json(
          await explanations.resolve(
            requestBody.documentId,
            requestBody.lineId,
            requestBody.context,
          ),
        );
      } catch (error) {
        return json({ error: error instanceof Error ? error.message : String(error) }, 400);
      }
    }

    if (url.pathname.startsWith("/api/")) return json({ error: "Not found" }, 404);
    return serveStatic(url.pathname);
  },
});

console.log(`Salix Prompt Atlas backend: http://${server.hostname}:${server.port}`);
