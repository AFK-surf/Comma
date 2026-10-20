import { screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { SubscriptionRef } from "effect";
import { expect, it, vi } from "vitest";
import type { AdminLookup, AdminUser } from "../src/adminApi";
import { makeSearchModel } from "../src/adminSearch";
import { AdminSearchPalette } from "../src/AdminSearchPalette";
import { mountModel, ok, settle, onTestClock } from "./support";

const ada: AdminUser = { id: "usr_ada", email: "ada@example.com", name: "Ada" };

it("waits for typing to pause, searches once, and opens the chosen account", async () => {
  const lookup = vi.fn(
    (): ReturnType<typeof ok<AdminLookup>> =>
      ok({ data: [{ match: "email", user: ada, workspace: null }] })
  );
  const view = mountModel(makeSearchModel, { api: { lookup } });
  const onOpenUser = vi.fn();
  view.render(
    <AdminSearchPalette
      model={view.model}
      onOpenSection={vi.fn()}
      onOpenUser={onOpenUser}
      sections={[{ label: "Users", section: "users" }]}
    />
  );
  await onTestClock(view.runtime.runPromise(view.model.setOpen(true)));
  await settle();
  const user = userEvent.setup({ delay: null });

  const input = screen.getByRole("combobox", { name: "Search accounts" });
  await user.click(input);
  await user.paste("a");
  await settle();
  expect(screen.getAllByText(/Type an email, or paste/).length).toBeGreaterThan(0);

  await user.paste("da@");
  await settle();
  expect(lookup).not.toHaveBeenCalled();
  await view.advance("250 millis");
  expect(lookup).toHaveBeenCalledTimes(1);
  expect(lookup).toHaveBeenCalledWith("ada@");

  await user.click(screen.getByRole("option", { name: /ada@example\.com/ }));
  await settle();
  expect(onOpenUser).toHaveBeenCalledWith("usr_ada");
  const state = await onTestClock(
    view.runtime.runPromise(SubscriptionRef.get(view.model.state))
  );
  expect(state).toEqual({ open: false, query: "", results: { status: "idle" } });
});
