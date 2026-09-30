import { mkdir, rename, rm } from "node:fs/promises";
import {
  ApplyResultSchema,
  CatalogSchema,
  ExtractionResultSchema,
  type Catalog,
  type JobSnapshot,
  type PendingChanges,
} from "../shared/schema";
import { runCodex } from "./codex";
import {
  APPLY_PROMPT_PATH,
  APPLY_SCHEMA_PATH,
  CATALOG_PATH,
  EXTRACTION_PROMPT_PATH,
  EXTRACTION_SCHEMA_PATH,
  LOCAL_ROOT,
  PENDING_PATH,
  REPO_ROOT,
  TOOL_ROOT,
} from "./paths";

type MutableJob = JobSnapshot & { logs: string[] };

const MAX_LOG_LINES = 80;

export class JobManager {
  private current: MutableJob | null = null;

  snapshot(): JobSnapshot | null {
    return this.current ? structuredClone(this.current) : null;
  }

  busy(): boolean {
    return this.current?.status === "queued" || this.current?.status === "running";
  }

  startExtraction(): JobSnapshot {
    const job = this.create("extract", "等待启动");
    void this.runExtractionJob(job);
    return structuredClone(job);
  }

  async startApply(pending: PendingChanges): Promise<JobSnapshot> {
    await this.writePending(pending);
    const job = this.create("apply", "变更数据已落盘");
    void this.runApplyJob(job);
    return structuredClone(job);
  }

  private create(kind: "extract" | "apply", stage: string): MutableJob {
    if (this.busy()) throw new Error("已有 Codex 任务正在运行");
    const job: MutableJob = {
      id: crypto.randomUUID(),
      kind,
      status: "queued",
      stage,
      startedAt: null,
      finishedAt: null,
      logs: [],
      result: null,
      error: null,
    };
    this.current = job;
    return job;
  }

  private log(job: MutableJob, message: string): void {
    job.logs.push(message);
    if (job.logs.length > MAX_LOG_LINES) job.logs.shift();
  }

  private async writePending(pending: PendingChanges): Promise<void> {
    await mkdir(LOCAL_ROOT, { recursive: true });
    const temporary = `${PENDING_PATH}.tmp`;
    await Bun.write(temporary, `${JSON.stringify(pending, null, 2)}\n`);
    await rename(temporary, PENDING_PATH);
  }

  private async readCatalog(): Promise<Catalog> {
    const parsed = CatalogSchema.safeParse(await Bun.file(CATALOG_PATH).json());
    if (!parsed.success) {
      throw new Error("Codex 生成的 catalog 未通过本地 schema 校验");
    }
    return parsed.data;
  }

  private begin(job: MutableJob, stage: string): void {
    job.status = "running";
    job.stage = stage;
    job.startedAt = new Date().toISOString();
  }

  private succeed(job: MutableJob, result: Record<string, unknown>): void {
    job.status = "succeeded";
    job.stage = "完成";
    job.result = result;
    job.finishedAt = new Date().toISOString();
  }

  private fail(
    job: MutableJob,
    error: unknown,
    result?: Record<string, unknown>,
  ): void {
    job.status = "failed";
    job.stage = "需要处理";
    job.error = error instanceof Error ? error.message : String(error);
    job.result = result ?? job.result;
    job.finishedAt = new Date().toISOString();
    this.log(job, job.error);
  }

  private async extract(job: MutableJob) {
    job.stage = "Codex 正在建立完整源码目录";
    const inventory = await runCodex({
      jobId: job.id,
      phase: "extract",
      cwd: TOOL_ROOT,
      sandbox: "workspace-write",
      promptPath: EXTRACTION_PROMPT_PATH,
      outputSchemaPath: EXTRACTION_SCHEMA_PATH,
      resultSchema: ExtractionResultSchema,
      onLog: (message) => this.log(job, message),
    });
    if (!inventory.success) {
      throw new Error(`源码目录未完成：${inventory.warnings.join("；")}`);
    }
    const catalog = await this.readCatalog();
    const categoryCounts = catalog.documents.reduce(
      (counts, document) => {
        counts[document.category] += 1;
        return counts;
      },
      { system: 0, tool: 0, skill: 0 },
    );
    if (categoryCounts.system === 0 || categoryCounts.tool === 0 || categoryCounts.skill === 0) {
      throw new Error(
        `源码目录不完整：system=${categoryCounts.system}, tool=${categoryCounts.tool}, skill=${categoryCounts.skill}`,
      );
    }
    const temporary = `${CATALOG_PATH}.tmp`;
    await Bun.write(temporary, `${JSON.stringify(catalog)}\n`);
    await rename(temporary, CATALOG_PATH);

    return {
      success: true,
      documents: catalog.documents.length,
      lines: catalog.documents.reduce((sum, document) => sum + document.lines.length, 0),
      classifiedLines: catalog.documents.reduce(
        (sum, document) =>
          sum + document.lines.filter((line) => line.classification !== "pending").length,
        0,
      ),
      warnings: inventory.warnings,
    };
  }

  private async runExtractionJob(job: MutableJob): Promise<void> {
    this.begin(job, "准备全量提取");
    try {
      const extraction = await this.extract(job);
      this.succeed(job, { extraction });
    } catch (error) {
      this.fail(job, error);
    }
  }

  private async runApplyJob(job: MutableJob): Promise<void> {
    this.begin(job, "Codex 正在读取 pending changes");
    try {
      const apply = await runCodex({
        jobId: job.id,
        phase: "apply",
        cwd: REPO_ROOT,
        sandbox: "workspace-write",
        promptPath: APPLY_PROMPT_PATH,
        outputSchemaPath: APPLY_SCHEMA_PATH,
        resultSchema: ApplyResultSchema,
        onLog: (message) => this.log(job, message),
      });
      job.result = { apply };

      if (!apply.success || !apply.validationPassed) {
        this.fail(
          job,
          new Error(apply.error ?? "源码已修改，但至少一项验证未通过"),
          { apply },
        );
        return;
      }

      const extraction = await this.extract(job);
      await rm(PENDING_PATH, { force: true });
      this.succeed(job, { apply, extraction });
    } catch (error) {
      this.fail(job, error, job.result ?? undefined);
    }
  }
}
