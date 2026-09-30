import { resolve } from "node:path";

export const TOOL_ROOT = resolve(import.meta.dir, "..");
export const REPO_ROOT = resolve(TOOL_ROOT, "../..");
export const LOCAL_ROOT = resolve(TOOL_ROOT, ".local");
export const JOB_ROOT = resolve(LOCAL_ROOT, "jobs");
export const PENDING_PATH = resolve(LOCAL_ROOT, "pending-changes.json");
export const EXPLANATION_SESSION_PATH = resolve(LOCAL_ROOT, "explanation-session.json");
export const EXPLANATION_REQUEST_ROOT = resolve(LOCAL_ROOT, "explanation-requests");
export const CATALOG_PATH = resolve(TOOL_ROOT, "data/catalog.generated.json");
export const DIST_ROOT = resolve(TOOL_ROOT, "dist");
export const EXTRACTION_PROMPT_PATH = resolve(TOOL_ROOT, "prompts/extract.md");
export const APPLY_PROMPT_PATH = resolve(TOOL_ROOT, "prompts/apply.md");
export const EXPLANATION_PROMPT_PATH = resolve(TOOL_ROOT, "prompts/explain.md");
export const EXTRACTION_SCHEMA_PATH = resolve(
  TOOL_ROOT,
  "schemas/extraction-result.schema.json",
);
export const APPLY_SCHEMA_PATH = resolve(
  TOOL_ROOT,
  "schemas/apply-result.schema.json",
);
export const EXPLANATION_SCHEMA_PATH = resolve(
  TOOL_ROOT,
  "schemas/explanation-result.schema.json",
);
