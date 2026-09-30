import { mkdir, rename, rm } from "node:fs/promises";
import { relative } from "node:path";
import { z } from "zod";
import {
  CatalogSchema,
  ExplanationResultSchema,
  type ExplanationResponse,
} from "../shared/schema";
import { runCodex } from "./codex";
import {
  CATALOG_PATH,
  EXPLANATION_PROMPT_PATH,
  EXPLANATION_REQUEST_ROOT,
  EXPLANATION_SCHEMA_PATH,
  EXPLANATION_SESSION_PATH,
  LOCAL_ROOT,
  REPO_ROOT,
} from "./paths";

const MAX_WAITING_EXPLANATIONS = 24;

const SessionSchema = z.object({
  schemaVersion: z.literal(1),
  sessionId: z.string().uuid(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
});

type SessionState = z.infer<typeof SessionSchema>;

export class ExplanationService {
  private sessionPromise: Promise<SessionState | null> | null = null;
  private tail: Promise<void> = Promise.resolve();
  private waiting = 0;

  resolve(
    documentId: string,
    lineId: string,
    context?: string,
  ): Promise<ExplanationResponse> {
    if (this.waiting >= MAX_WAITING_EXPLANATIONS) {
      return Promise.reject(new Error("解释队列已满，请稍后重试"));
    }

    this.waiting += 1;
    const task = this.tail.then(() => this.explain(documentId, lineId, context));
    this.tail = task.then(
      () => undefined,
      () => undefined,
    );
    return task.finally(() => {
      this.waiting -= 1;
    });
  }

  private async explain(
    documentId: string,
    lineId: string,
    context?: string,
  ): Promise<ExplanationResponse> {
    const parsedCatalog = CatalogSchema.safeParse(await Bun.file(CATALOG_PATH).json());
    if (!parsedCatalog.success) throw new Error("catalog 数据无效");
    const document = parsedCatalog.data.documents.find((item) => item.id === documentId);
    const line = document?.lines.find((item) => item.id === lineId);
    if (!document || !line) throw new Error("找不到对应的 Prompt 行");
    if (line.kind !== "text" || !line.text.trim()) {
      throw new Error("只有静态文本行可以解释");
    }

    const requestId = crypto.randomUUID();
    const requestPath = `${EXPLANATION_REQUEST_ROOT}/${requestId}.json`;
    await mkdir(EXPLANATION_REQUEST_ROOT, { recursive: true });
    await Bun.write(
      requestPath,
      `${JSON.stringify(
        {
          schemaVersion: 1,
          context: context || `${document.category} / ${document.title}`,
          document: {
            id: document.id,
            category: document.category,
            title: document.title,
            description: document.description,
          },
          line: {
            id: line.id,
            text: line.text,
            classification: line.classification,
            source: line.source,
          },
        },
        null,
        2,
      )}\n`,
    );

    try {
      const session = await this.loadSession();
      try {
        return await this.runTurn(requestId, requestPath, session);
      } catch (error) {
        if (!session || !this.isMissingSession(error)) throw error;
        await this.clearSession();
        return this.runTurn(requestId, requestPath, null);
      }
    } finally {
      await rm(requestPath, { force: true });
    }
  }

  private async runTurn(
    requestId: string,
    requestPath: string,
    session: SessionState | null,
  ): Promise<ExplanationResponse> {
    let observedSessionId = session?.sessionId ?? null;
    const result = await runCodex({
      jobId: `explanation-${requestId}`,
      phase: "explain",
      cwd: REPO_ROOT,
      sandbox: "read-only",
      promptPath: EXPLANATION_PROMPT_PATH,
      outputSchemaPath: EXPLANATION_SCHEMA_PATH,
      resultSchema: ExplanationResultSchema,
      promptSuffix: `\n\nExplain the request in \`${relative(REPO_ROOT, requestPath)}\`.\n`,
      model: "gpt-5.6-luna",
      reasoningEffort: "low",
      persistSession: true,
      resumeSessionId: session?.sessionId,
      onSessionId: (sessionId) => {
        observedSessionId = sessionId;
      },
      onLog: () => {},
    });
    if (!result.success || !result.explanation.trim()) {
      throw new Error(result.warnings.join("；") || "Codex 未返回完整解释");
    }
    if (!observedSessionId) throw new Error("Codex 未返回解释 session id");
    await this.persistSession(observedSessionId, session?.createdAt);
    return { explanation: result.explanation, sessionId: observedSessionId };
  }

  private async loadSession(): Promise<SessionState | null> {
    if (!this.sessionPromise) {
      this.sessionPromise = (async () => {
        try {
          const file = Bun.file(EXPLANATION_SESSION_PATH);
          if (!(await file.exists())) return null;
          const parsed = SessionSchema.safeParse(await file.json());
          return parsed.success ? parsed.data : null;
        } catch {
          return null;
        }
      })();
    }
    return this.sessionPromise;
  }

  private async persistSession(sessionId: string, createdAt?: string): Promise<void> {
    const now = new Date().toISOString();
    const state: SessionState = {
      schemaVersion: 1,
      sessionId,
      createdAt: createdAt ?? now,
      updatedAt: now,
    };
    await mkdir(LOCAL_ROOT, { recursive: true });
    const temporary = `${EXPLANATION_SESSION_PATH}.${crypto.randomUUID()}.tmp`;
    await Bun.write(temporary, `${JSON.stringify(state, null, 2)}\n`);
    await rename(temporary, EXPLANATION_SESSION_PATH);
    this.sessionPromise = Promise.resolve(state);
  }

  private async clearSession(): Promise<void> {
    await rm(EXPLANATION_SESSION_PATH, { force: true });
    this.sessionPromise = Promise.resolve(null);
  }

  private isMissingSession(error: unknown): boolean {
    const message = error instanceof Error ? error.message : String(error);
    return /(?:session|thread|rollout).*(?:not found|missing|unknown)|no rollout/i.test(message);
  }
}
