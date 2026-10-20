import { createScriptedCore } from "@comma/test-utils/scripted-core";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { StrictMode, type ReactNode } from "react";
import { afterEach, expect, it, vi } from "vitest";
import { CreditWarningToast } from "../CreditWarningToast";
import { Toaster, toast } from "@comma/ui/components/toast";

afterEach(() => {
  act(() => toast.dismissAll());
  vi.restoreAllMocks();
});

/** Chat surfaces over a core whose `creditWarning` is `warning`; what they subscribe to and call is noted. */
function setup(warning: unknown) {
  const calls: [string, unknown][] = [];
  const watching: string[] = [];
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "creditWarning" ? warning : undefined),
    calls: (name, params) => {
      calls.push([name, params]);
      return null;
    },
    onSubscribe: (topic) => watching.push(String(topic.workspace)),
    onUnsubscribe: (topic) =>
      watching.splice(watching.indexOf(String(topic.workspace)), 1),
  });
  const show = (ui: ReactNode) =>
    core.wrap(
      <>
        {ui}
        <Toaster />
      </>
    );
  const named = (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p);
  return { core, show, named, watching };
}

const dismissButton = () =>
  within(screen.getByTestId("out-of-credits")).getByRole("button", {
    name: "Dismiss notification",
  });

it("shows one toast for every chat surface of a workspace; closing it tells the core once", async () => {
  const t = setup({ percent: 50, threshold: 50 });
  render(
    t.show(
      <StrictMode>
        <CreditWarningToast workspaceId="workspace" active />
        <CreditWarningToast workspaceId="workspace" active />
      </StrictMode>
    )
  );
  await waitFor(() => expect(screen.getAllByTestId("out-of-credits")).toHaveLength(1));
  expect(screen.getByTestId("out-of-credits")).toHaveTextContent(
    "50% of usage credits remaining"
  );
  fireEvent.click(dismissButton());
  await waitFor(() => expect(screen.queryByTestId("out-of-credits")).toBeNull());
  expect(t.named("billing.dismissWarning")).toEqual([{ workspace: "workspace" }]);

  // The core says the warning is gone (the dismissal took): nothing comes back.
  act(() => t.core.emit("creditWarning", null));
  await act(async () => {});
  expect(screen.queryByTestId("out-of-credits")).toBeNull();

  // Lower: it shows again.
  act(() => t.core.emit("creditWarning", { percent: 10, threshold: 10 }));
  expect(await screen.findByTestId("out-of-credits")).toHaveTextContent(
    "10% of usage credits remaining"
  );
});

it("removes the toast without dismissing it when the warning ends", async () => {
  const t = setup({ percent: 5, threshold: 5 });
  render(t.show(<CreditWarningToast workspaceId="workspace" active />));
  await screen.findByTestId("out-of-credits");
  act(() => t.core.emit("creditWarning", null));
  await waitFor(() => expect(screen.queryByTestId("out-of-credits")).toBeNull());
  expect(t.named("billing.dismissWarning")).toEqual([]);
});

it("shows the out-of-credits toast when the core says no credits remain", async () => {
  const t = setup({ percent: 0, threshold: 0 });
  render(t.show(<CreditWarningToast workspaceId="workspace" active />));
  const spent = await screen.findByTestId("out-of-credits");
  expect(spent).toHaveTextContent("Out of Comma credits");
  expect(within(spent).getByRole("button", { name: "Add credits" })).toBeVisible();
  fireEvent.click(dismissButton());
  await waitFor(() =>
    expect(t.named("billing.dismissWarning")).toEqual([{ workspace: "workspace" }])
  );
});

it("reads again on focus while the page shows, not while it is hidden, and follows the workspace", async () => {
  let visibility: DocumentVisibilityState = "visible";
  vi.spyOn(document, "visibilityState", "get").mockImplementation(() => visibility);
  const t = setup(null);
  const view = render(t.show(<CreditWarningToast workspaceId="workspace" active />));
  await waitFor(() => expect(t.watching).toEqual(["workspace"]));

  act(() => {
    window.dispatchEvent(new FocusEvent("focus"));
  });
  await waitFor(() =>
    expect(t.named("billing.refresh")).toEqual([{ workspace: "workspace" }])
  );

  visibility = "hidden";
  act(() => {
    document.dispatchEvent(new Event("visibilitychange"));
    window.dispatchEvent(new FocusEvent("focus"));
  });
  await act(async () => {});
  expect(t.named("billing.refresh")).toHaveLength(1);
  visibility = "visible";
  act(() => {
    document.dispatchEvent(new Event("visibilitychange"));
  });

  view.rerender(t.show(<CreditWarningToast workspaceId="other" active />));
  await waitFor(() => expect(t.watching).toContain("other"));
});
