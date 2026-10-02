import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { StrictMode } from "react";
import { afterEach, expect, it, vi } from "vitest";
import type {
  CommaApiClient,
  CommaBillingPlan,
  CommaBillingSummary,
} from "../../../api";
import { CreditWarningNotice } from "../CreditWarningNotice";

const plan: CommaBillingPlan = {
  plan_key: "monthly",
  package_code: "monthly",
  package_version: "v1",
  name: "Monthly",
  mode: "subscription",
  currency: "usd",
  amount_minor: 100,
  grant_credits: 1000,
};
function summary(remaining: number, id = "grant-1"): CommaBillingSummary {
  return {
    billing_account_id: "billing-warning-test",
    current_credits: remaining,
    active_grants: [
      {
        id,
        package_code: plan.package_code,
        package_version: plan.package_version,
        remaining_credits: remaining,
        valid_from: "2026-09-01T00:00:00Z",
        expires_at: null,
        source_type: "subscription_cycle",
        source_id: "cycle",
      },
    ],
  };
}
afterEach(() => {
  localStorage.clear();
  vi.restoreAllMocks();
  vi.useRealTimers();
});

it("shares balance reads and dismissal across chat surfaces, then alerts at each lower threshold and the next grant", async () => {
  let current = summary(500);
  const getBillingSummary = vi.fn(async () => current);
  const listBillingPlans = vi.fn(async () => [plan]);
  const api = { getBillingSummary, listBillingPlans } as unknown as CommaApiClient;
  const view = render(
    <StrictMode>
      <CreditWarningNotice api={api} workspaceId="workspace" active />
      <CreditWarningNotice api={api} workspaceId="workspace" active />
    </StrictMode>
  );
  await waitFor(() =>
    expect(screen.getAllByTestId("chat-credit-warning")).toHaveLength(2)
  );
  // StrictMode cancels the first mount's read. The two surfaces share its replacement.
  expect(getBillingSummary).toHaveBeenCalledTimes(2);
  fireEvent.click(
    within(screen.getAllByTestId("chat-credit-warning")[0]!).getByRole("button", {
      name: "Close",
    })
  );
  expect(screen.queryByTestId("chat-credit-warning")).toBeNull();
  fireEvent(window, new Event("focus"));
  await waitFor(() => expect(getBillingSummary).toHaveBeenCalledTimes(3));
  expect(screen.queryByTestId("chat-credit-warning")).toBeNull();
  for (const remaining of [100, 50]) {
    current = summary(remaining);
    fireEvent(window, new Event("focus"));
    await waitFor(() =>
      expect(screen.getAllByTestId("chat-credit-warning")[0]).toHaveTextContent(
        `${remaining / 10}% of usage credits remaining`
      )
    );
    fireEvent.click(
      within(screen.getAllByTestId("chat-credit-warning")[0]!).getByRole("button", {
        name: "Close",
      })
    );
    expect(screen.queryByTestId("chat-credit-warning")).toBeNull();
  }
  view.unmount();
  await act(async () => {});
  const reopened = render(
    <CreditWarningNotice api={api} workspaceId="workspace" active />
  );
  await waitFor(() => expect(getBillingSummary).toHaveBeenCalledTimes(6));
  expect(screen.queryByTestId("chat-credit-warning")).toBeNull();
  current = summary(500, "grant-2");
  fireEvent(window, new Event("focus"));
  expect(await screen.findByTestId("chat-credit-warning")).toHaveTextContent(
    "50% of usage credits remaining"
  );
  reopened.unmount();
});

it("does not warn early due to rounding, guess unknown grants, or retain a warning after a failed read", async () => {
  let current = summary(501);
  const getBillingSummary = vi.fn(async () => current);
  const api = {
    getBillingSummary,
    listBillingPlans: vi.fn(async () => [plan]),
  } as unknown as CommaApiClient;
  render(<CreditWarningNotice api={api} workspaceId="workspace" active />);
  await waitFor(() => expect(getBillingSummary).toHaveBeenCalledTimes(1));
  expect(screen.queryByTestId("chat-credit-warning")).toBeNull();
  current = summary(100);
  current.active_grants[0]!.package_code = null;
  fireEvent(window, new Event("focus"));
  await waitFor(() => expect(getBillingSummary).toHaveBeenCalledTimes(2));
  expect(screen.queryByTestId("chat-credit-warning")).toBeNull();
  current = summary(100);
  fireEvent(window, new Event("focus"));
  await screen.findByTestId("chat-credit-warning");
  getBillingSummary.mockRejectedValueOnce(new Error("offline"));
  fireEvent(window, new Event("focus"));
  await waitFor(() => expect(screen.queryByTestId("chat-credit-warning")).toBeNull());
});

it("polls once per visible workspace per minute and stops when its surfaces are hidden", async () => {
  vi.useFakeTimers();
  let visibility: DocumentVisibilityState = "visible";
  vi.spyOn(document, "visibilityState", "get").mockImplementation(() => visibility);
  const getBillingSummary = vi.fn(async () => summary(1000));
  const api = {
    getBillingSummary,
    listBillingPlans: vi.fn(async () => [plan]),
  } as unknown as CommaApiClient;
  const view = render(
    <>
      <CreditWarningNotice api={api} workspaceId="workspace" active />
      <CreditWarningNotice api={api} workspaceId="workspace" active />
    </>
  );
  await act(async () => {});
  expect(getBillingSummary).toHaveBeenCalledTimes(1);
  await act(async () => {
    await vi.advanceTimersByTimeAsync(60_000);
  });
  expect(getBillingSummary).toHaveBeenCalledTimes(2);
  visibility = "hidden";
  await act(async () => {
    await vi.advanceTimersByTimeAsync(120_000);
  });
  expect(getBillingSummary).toHaveBeenCalledTimes(2);
  visibility = "visible";
  await act(async () => {
    document.dispatchEvent(new Event("visibilitychange"));
  });
  expect(getBillingSummary).toHaveBeenCalledTimes(3);
  view.rerender(
    <CreditWarningNotice api={api} workspaceId="workspace" active={false} />
  );
  await act(async () => {
    await vi.advanceTimersByTimeAsync(60_000);
  });
  expect(getBillingSummary).toHaveBeenCalledTimes(3);
});

it("ignores a late balance from the previous workspace", async () => {
  let finishPrevious: ((value: CommaBillingSummary) => void) | undefined;
  let previousSignal: AbortSignal | undefined;
  const api = {
    listBillingPlans: vi.fn(async () => [plan]),
    getBillingSummary: vi.fn(
      (workspaceId: string, options: { signal?: AbortSignal }) => {
        if (workspaceId === "previous") {
          previousSignal = options.signal;
          return new Promise<CommaBillingSummary>((resolve) => {
            finishPrevious = resolve;
          });
        }
        return Promise.resolve(summary(1000));
      }
    ),
  } as unknown as CommaApiClient;
  const view = render(<CreditWarningNotice api={api} workspaceId="previous" active />);
  await waitFor(() => expect(finishPrevious).toBeDefined());
  view.rerender(<CreditWarningNotice api={api} workspaceId="current" active />);
  expect(previousSignal?.aborted).toBe(true);
  await act(async () => {
    finishPrevious!(summary(50));
  });
  expect(screen.queryByTestId("chat-credit-warning")).toBeNull();
});

it("shows the out-of-credits card when the balance is spent or every grant has expired", async () => {
  let current: CommaBillingSummary = summary(0);
  const getBillingSummary = vi.fn(async () => current);
  const api = {
    getBillingSummary,
    listBillingPlans: vi.fn(async () => [plan]),
  } as unknown as CommaApiClient;
  render(<CreditWarningNotice api={api} workspaceId="workspace" active />);
  const spent = await screen.findByTestId("chat-credit-warning");
  expect(spent).toHaveTextContent("Out of usage credits");
  expect(spent).toHaveAttribute("data-tone", "error");
  expect(within(spent).getByRole("button", { name: "Add credits" })).toBeVisible();

  // The summary lists only unexpired grants: after the last one expires there
  // is no allowance, which must still read as exhausted, not as unknown.
  current = { ...summary(0), active_grants: [] };
  fireEvent(window, new Event("focus"));
  await waitFor(() => expect(getBillingSummary).toHaveBeenCalledTimes(2));
  expect(screen.getByTestId("chat-credit-warning")).toHaveTextContent(
    "Out of usage credits"
  );
  fireEvent.click(
    within(screen.getByTestId("chat-credit-warning")).getByRole("button", {
      name: "Close",
    })
  );
  expect(screen.queryByTestId("chat-credit-warning")).toBeNull();

  // A spent grant whose package is unknown stays silent: it may be unlimited.
  current = summary(0, "grant-unknown");
  current.active_grants[0]!.package_code = null;
  fireEvent(window, new Event("focus"));
  await waitFor(() => expect(getBillingSummary).toHaveBeenCalledTimes(3));
  expect(screen.queryByTestId("chat-credit-warning")).toBeNull();
});
