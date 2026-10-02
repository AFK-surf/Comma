import { useCallback, useMemo, useSyncExternalStore } from "react";
import type { CommaApiClient, CommaBillingPlan, CommaBillingSummary } from "../../api";
import { creditAllowance } from "./BillingSettings";

export type CreditWarning = {
  percent: number;
  // 0: no usable credits remain, including after every grant expired.
  threshold: 0 | 5 | 10 | 50;
};

function warningThreshold(percent: number): CreditWarning["threshold"] | undefined {
  return percent <= 5 ? 5 : percent <= 10 ? 10 : percent <= 50 ? 50 : undefined;
}

type Dismissal = { grants: string; threshold: number };

// Share reads across visible chat surfaces in this renderer. The main chat
// and sidebar require at most two workspace scopes. Each scope has one in-flight
// summary read and one read per minute, regardless of its conversation count.
// Catalog reads occur once per subscription lifetime. Hidden pages do not poll.
const monitors = new WeakMap<CommaApiClient, Map<string, CreditWarningMonitor>>();

class CreditWarningMonitor {
  private listeners = new Set<() => void>();
  private plans: CommaBillingPlan[] | undefined;
  private summary: CommaBillingSummary | undefined;
  private warning: CreditWarning | undefined;
  private dismissal: Dismissal | undefined;
  private controller: AbortController | undefined;
  private timer: ReturnType<typeof setInterval> | undefined;

  constructor(
    private api: CommaApiClient,
    private workspaceId: string,
    private release: () => void
  ) {}

  getSnapshot = () => this.warning;

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) {
      window.addEventListener("focus", this.refresh);
      document.addEventListener("visibilitychange", this.refresh);
      this.timer = setInterval(this.refresh, 60_000);
      this.refresh();
    }
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size) return;
      window.removeEventListener("focus", this.refresh);
      document.removeEventListener("visibilitychange", this.refresh);
      clearInterval(this.timer);
      this.controller?.abort();
      this.controller = undefined;
      queueMicrotask(() => {
        if (!this.listeners.size) this.release();
      });
    };
  };

  private refresh = () => {
    if (document.visibilityState === "hidden" || this.controller) return;
    const controller = new AbortController();
    this.controller = controller;
    void this.load(controller);
  };

  private async load(controller: AbortController) {
    try {
      const options = { signal: controller.signal };
      const [summary, plans] = await Promise.all([
        this.api.getBillingSummary(this.workspaceId, options),
        this.plans ?? this.api.listBillingPlans(options),
      ]);
      if (controller.signal.aborted) return;
      this.summary = summary;
      this.plans = plans;
      this.update();
    } catch {
      // A failed balance read must not block chat or display a stale warning.
      if (!controller.signal.aborted) this.publish(undefined);
    } finally {
      if (this.controller === controller) this.controller = undefined;
    }
  }

  private storageKey() {
    return `comma.creditWarning.${this.summary?.billing_account_id}`;
  }

  private grantScope() {
    return JSON.stringify(
      this.summary!.active_grants.map((grant) => grant.id).toSorted()
    );
  }

  private update() {
    if (!this.summary) return this.publish(undefined);
    const allowance = creditAllowance(this.summary, this.plans ?? []);
    // The summary lists only unexpired grants. With none left there is no
    // allowance to compare against, but billed work is already refused, so
    // that state reads as exhausted rather than unknown.
    const exhausted =
      this.summary.current_credits <= 0 &&
      (allowance !== undefined || this.summary.active_grants.length === 0);
    if (!allowance && !exhausted) return this.publish(undefined);
    // Compare the actual ratio. Display rounding must not trigger an early warning.
    const percent = allowance
      ? (this.summary.current_credits / allowance.total) * 100
      : 0;
    const threshold = exhausted ? 0 : warningThreshold(percent);
    if (threshold === undefined) return this.publish(undefined);
    try {
      const saved: unknown = JSON.parse(
        localStorage.getItem(this.storageKey()) ?? "null"
      );
      if (
        saved &&
        typeof saved === "object" &&
        "grants" in saved &&
        "threshold" in saved &&
        typeof saved.grants === "string" &&
        typeof saved.threshold === "number"
      ) {
        this.dismissal = { grants: saved.grants, threshold: saved.threshold };
      }
    } catch {
      // Keep in-memory dismissal when browser storage is unavailable.
    }
    if (
      this.dismissal?.grants === this.grantScope() &&
      threshold >= this.dismissal.threshold
    ) {
      return this.publish(undefined);
    }
    this.publish({ percent: allowance?.percent ?? 0, threshold });
  }

  dismiss = () => {
    if (!this.warning || !this.summary) return;
    this.dismissal = { grants: this.grantScope(), threshold: this.warning.threshold };
    try {
      localStorage.setItem(this.storageKey(), JSON.stringify(this.dismissal));
    } catch {
      // Storage failures do not prevent closing the warning.
    }
    this.publish(undefined);
  };

  private publish(warning: CreditWarning | undefined) {
    if (
      warning?.percent === this.warning?.percent &&
      warning?.threshold === this.warning?.threshold
    )
      return;
    this.warning = warning;
    for (const listener of this.listeners) listener();
  }
}

const emptySnapshot = () => undefined;
const emptySubscribe = () => () => {};

export function useCreditWarning(
  api: CommaApiClient | undefined,
  workspaceId: string | undefined,
  active: boolean
) {
  const monitor = useMemo(() => {
    if (!api || !workspaceId || !active) return undefined;
    let workspaces = monitors.get(api);
    if (!workspaces) {
      workspaces = new Map();
      monitors.set(api, workspaces);
    }
    let entry = workspaces.get(workspaceId);
    if (!entry) {
      entry = new CreditWarningMonitor(api, workspaceId, () => {
        if (workspaces.get(workspaceId) === entry) workspaces.delete(workspaceId);
      });
      workspaces.set(workspaceId, entry);
    }
    return entry;
  }, [api, workspaceId, active]);
  const warning = useSyncExternalStore(
    monitor?.subscribe ?? emptySubscribe,
    monitor?.getSnapshot ?? emptySnapshot,
    emptySnapshot
  );
  const dismiss = useCallback(() => monitor?.dismiss(), [monitor]);
  return { warning, dismiss };
}
