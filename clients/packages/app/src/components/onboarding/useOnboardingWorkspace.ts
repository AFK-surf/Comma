import { useEffect, useState } from "react";
import { CommaApiError, type CommaApiClient } from "../../api";
import { writeActiveWorkspaceId } from "../activeWorkspace";

export type OnboardingWorkspace =
  /** `unreachable`: the last request did not get an answer (offline). */
  | { status: "preparing"; unreachable?: boolean }
  | { status: "ready"; workspaceId: string }
  | { status: "unavailable" };

const maxRetryDelaySeconds = 10;

// Answers that a later bootstrap cannot change: the session is gone, or the
// account has no workspace it may use.
const terminalStatuses = new Set([401, 403, 404]);

/**
 * Waits until the account's default workspace is ready, because every
 * workspace-scoped call the onboarding makes (Router name, plugins) answers
 * `workspace_provisioning` until then, and Home stops retrying after three
 * attempts.
 *
 * Bound: one poller per signed-in window (the overlay mounts once per window
 * and account), one `POST /v1/comma/me/bootstrap` in flight, one request per
 * `retry_after_seconds` clamped to 1–10 s (10 s after a transient failure),
 * and nothing after `ready`, a terminal answer, or the overlay unmounting.
 */
export function useOnboardingWorkspace(api: CommaApiClient): OnboardingWorkspace {
  const [workspace, setWorkspace] = useState<OnboardingWorkspace>({
    status: "preparing",
  });

  useEffect(() => {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;

    const attempt = async () => {
      let delaySeconds = maxRetryDelaySeconds;
      try {
        const result = await api.bootstrapWorkspace({ signal: controller.signal });
        if (controller.signal.aborted) return;
        if (result.status === "ready") {
          // The rest of the shell scopes to the active workspace; the Router
          // name and plugins the onboarding sets up belong to this one.
          writeActiveWorkspaceId(result.workspace.id);
          setWorkspace({ status: "ready", workspaceId: result.workspace.id });
          return;
        }
        setWorkspace({ status: "preparing" });
        delaySeconds = Math.min(
          Math.max(result.retry_after_seconds, 1),
          maxRetryDelaySeconds
        );
      } catch (error) {
        if (controller.signal.aborted) return;
        if (error instanceof CommaApiError && terminalStatuses.has(error.status)) {
          setWorkspace({ status: "unavailable" });
          return;
        }
        // No answer at all: say so, and keep trying until the network is back.
        if (!(error instanceof CommaApiError)) {
          setWorkspace({ status: "preparing", unreachable: true });
        }
      }
      timer = setTimeout(() => void attempt(), delaySeconds * 1_000);
    };

    void attempt();
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [api]);

  return workspace;
}
