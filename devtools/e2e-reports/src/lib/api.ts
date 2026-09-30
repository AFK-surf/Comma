import { get } from "svelte/store";
import { backendUrl } from "./stores/auth";
import type {
  ArtifactRecord,
  CleanupPreview,
  ReportSession,
  RunRecord,
} from "./types";

function getBase(): string {
  const override = get(backendUrl);
  return override ? override.replace(/\/+$/, "") : "/v1";
}

function query(params: Record<string, string | number | undefined>) {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== "") search.set(key, String(value));
  }
  const value = search.toString();
  return value ? `?${value}` : "";
}

async function req<T>(
  method: string,
  path: string,
  token: string,
  body?: unknown,
): Promise<T> {
  const res = await fetch(getBase() + path, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(err.error || res.statusText);
  }
  return res.json();
}

export function resolveBackendUrl(pathOrUrl: string): string {
  try {
    return new URL(pathOrUrl).toString();
  } catch {
    return new URL(
      pathOrUrl,
      new URL(getBase(), window.location.origin),
    ).toString();
  }
}

export const e2eReports = {
  listRuns: (
    token: string,
    params: Record<string, string | number | undefined>,
  ) =>
    req<{ runs: RunRecord[] }>(
      "GET",
      `/admin/e2e-reports/runs${query(params)}`,
      token,
    ),
  getRun: (token: string, runId: string, attempt: string) =>
    req<RunRecord>(
      "GET",
      `/admin/e2e-reports/runs/${encodeURIComponent(runId)}${query({ attempt })}`,
      token,
    ),
  createReportSession: (
    token: string,
    runId: string,
    attempt: string,
    target: string,
  ) =>
    req<ReportSession>("POST", "/admin/e2e-reports/report-sessions", token, {
      runId,
      attempt,
      target,
    }),
  listArtifacts: (
    token: string,
    params: Record<string, string | number | undefined>,
  ) =>
    req<{ artifacts: ArtifactRecord[] }>(
      "GET",
      `/admin/e2e-reports/artifacts${query(params)}`,
      token,
    ),
  cleanupPreview: (token: string, body: Record<string, unknown>) =>
    req<CleanupPreview>(
      "POST",
      "/admin/e2e-reports/artifacts/cleanup-preview",
      token,
      body,
    ),
  cleanup: (token: string, body: Record<string, unknown>) =>
    req<CleanupPreview>(
      "POST",
      "/admin/e2e-reports/artifacts/cleanup",
      token,
      body,
    ),
  deleteRun: (token: string, runId: string, attempt: string) =>
    req<CleanupPreview>(
      "DELETE",
      `/admin/e2e-reports/runs/${encodeURIComponent(runId)}${query({ attempt })}`,
      token,
    ),
};
