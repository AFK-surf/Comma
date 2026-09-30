import {
  CatalogSchema,
  ExplanationResponseSchema,
  JobSnapshotSchema,
  type Catalog,
  type ExplanationResponse,
  type JobSnapshot,
  type PendingChanges,
} from "../../shared/schema";

type Bootstrap = {
  csrfToken: string;
  codexAvailable: boolean;
  currentJob: JobSnapshot | null;
};

export class AtlasApi {
  private constructor(
    private readonly csrfToken: string,
    readonly codexAvailable: boolean,
  ) {}

  static async connect(): Promise<{ api: AtlasApi; currentJob: JobSnapshot | null }> {
    const response = await fetch("/api/bootstrap", { cache: "no-store" });
    if (!response.ok) throw new Error("无法连接 Bun 后端");
    const body = (await response.json()) as Bootstrap;
    return {
      api: new AtlasApi(body.csrfToken, body.codexAvailable),
      currentJob: body.currentJob ? JobSnapshotSchema.parse(body.currentJob) : null,
    };
  }

  private async request(path: string, init: RequestInit = {}): Promise<unknown> {
    const response = await fetch(path, {
      ...init,
      cache: "no-store",
      headers: {
        "x-salix-prompt-csrf": this.csrfToken,
        ...(init.body ? { "content-type": "application/json" } : {}),
        ...init.headers,
      },
    });
    const body = (await response.json()) as { error?: string };
    if (!response.ok) throw new Error(body.error ?? `请求失败：${response.status}`);
    return body;
  }

  async catalog(): Promise<Catalog> {
    return CatalogSchema.parse(await this.request("/api/catalog"));
  }

  async currentJob(): Promise<JobSnapshot | null> {
    const body = (await this.request("/api/jobs/current")) as { job: unknown };
    return body.job ? JobSnapshotSchema.parse(body.job) : null;
  }

  async extract(): Promise<JobSnapshot> {
    const body = (await this.request("/api/jobs/extract", {
      method: "POST",
      body: JSON.stringify({ draftCount: 0 }),
    })) as { job: unknown };
    return JobSnapshotSchema.parse(body.job);
  }

  async apply(pending: PendingChanges): Promise<JobSnapshot> {
    const body = (await this.request("/api/jobs/apply", {
      method: "POST",
      body: JSON.stringify(pending),
    })) as { job: unknown };
    return JobSnapshotSchema.parse(body.job);
  }

  async explain(
    documentId: string,
    lineId: string,
    context?: string,
  ): Promise<ExplanationResponse> {
    return ExplanationResponseSchema.parse(
      await this.request("/api/explanations/resolve", {
        method: "POST",
        body: JSON.stringify({ documentId, lineId, context }),
      }),
    );
  }
}
