import { act, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import type { AdminApiShape, AdminAuditEvent, AdminPage } from "../src/adminApi";
import { makeAuditLogModel } from "../src/AuditLogModel";
import { AuditLogPanel, AuditLogView } from "../src/AuditLogView";
import { mountModel, ok, pending, refuse, settle } from "./support";

const newest: AdminAuditEvent = {
  id: "audit_newest",
  action: "revoke_user_session",
  outcome: "succeeded",
  actor: { type: "comma_user", user_id: "usr_admin", email: "owner@example.com" },
  target: { type: "session", id: "sess_web" },
  reason: "Remove a stale browser Session",
  error_code: null,
  created_at: 1_784_880_000,
  updated_at: 1_784_880_001,
};

const older: AdminAuditEvent = {
  id: "audit_older",
  action: "create_user",
  outcome: "rejected",
  actor: { type: "comma_user", user_id: "usr_admin", email: "owner@example.com" },
  target: { type: "user", id: "target@example.com" },
  reason: "Request did not pass validation",
  error_code: "invalid_confirmation",
  created_at: 1_784_879_000,
  updated_at: 1_784_879_001,
};

const firstPage: AdminPage<AdminAuditEvent> = {
  data: [newest],
  hasMore: true,
  nextCursor: "audit-page-2",
};

async function mountAuditLog(api: Partial<AdminApiShape>) {
  const view = mountModel(makeAuditLogModel(), { api });
  view.render(<AuditLogView model={view.model} />);
  await settle();
  return view;
}

it("loads the newest page, opens an event and loads the next page", async () => {
  const next = pending<AdminPage<AdminAuditEvent>>();
  const listAuditEvents = vi
    .fn()
    .mockReturnValueOnce(ok(firstPage))
    .mockReturnValueOnce(next.effect);
  await mountAuditLog({ listAuditEvents });
  const user = userEvent.setup({ delay: null });

  expect(listAuditEvents).toHaveBeenCalledWith({ limit: 50 });
  const table = screen.getByRole("table", { name: "Admin audit events" });
  expect(within(table).getByText("Revoke user session")).toBeInTheDocument();
  expect(within(table).getByText("owner@example.com")).toBeInTheDocument();
  expect(screen.getByText("1 event loaded")).toBeInTheDocument();

  await user.click(within(table).getByRole("button", { name: "View audit event" }));
  await settle();
  const dialog = screen.getByRole("dialog", { name: "Revoke user session" });
  expect(
    within(dialog).getByText("Remove a stale browser Session")
  ).toBeInTheDocument();
  expect(within(dialog).getByText("sess_web")).toBeInTheDocument();
  await user.click(within(dialog).getByRole("button", { name: "Close" }));
  await settle();
  expect(
    screen.queryByRole("dialog", { name: "Revoke user session" })
  ).not.toBeInTheDocument();

  await user.click(screen.getByRole("button", { name: "Load more" }));
  await settle();
  expect(listAuditEvents).toHaveBeenLastCalledWith({
    cursor: "audit-page-2",
    limit: 50,
  });
  expect(screen.getByRole("button", { name: "Loading…" })).toBeDisabled();

  act(() => next.succeed({ data: [older], hasMore: false }));
  await settle();
  expect(screen.getByText("2 events loaded")).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "Load more" })).not.toBeInTheDocument();
  await user.click(
    within(screen.getByRole("table", { name: "Admin audit events" }))
      .getAllByRole("button", { name: "View audit event" })
      .at(-1)!
  );
  await settle();
  expect(screen.getByRole("dialog", { name: "Create user" })).toHaveTextContent(
    "invalid_confirmation"
  );
});

it("starts again from the newest page when the cursor expired", async () => {
  const listAuditEvents = vi
    .fn()
    .mockReturnValueOnce(ok(firstPage))
    .mockReturnValueOnce(refuse(400, "invalid_cursor"))
    .mockReturnValueOnce(ok({ data: [older], hasMore: false }));
  await mountAuditLog({ listAuditEvents });
  const user = userEvent.setup({ delay: null });

  await user.click(screen.getByRole("button", { name: "Load more" }));
  await settle();

  expect(listAuditEvents).toHaveBeenCalledTimes(3);
  expect(listAuditEvents).toHaveBeenLastCalledWith({ limit: 50 });
  expect(screen.getByText("Create user", { selector: "strong" })).toBeInTheDocument();
  expect(
    screen.queryByText("Revoke user session", { selector: "strong" })
  ).not.toBeInTheDocument();
});

it("shows a failed page and a failed load with a retry", async () => {
  const listAuditEvents = vi
    .fn()
    .mockReturnValueOnce(ok(firstPage))
    .mockReturnValueOnce(refuse(500, "internal", "Audit storage is unavailable."))
    .mockReturnValueOnce(refuse(500, "internal", "Audit storage is unavailable."))
    .mockReturnValueOnce(ok({ data: [], hasMore: false }));
  await mountAuditLog({ listAuditEvents });
  const user = userEvent.setup({ delay: null });

  await user.click(screen.getByRole("button", { name: "Load more" }));
  await settle();
  expect(screen.getByRole("alert")).toHaveTextContent("Audit storage is unavailable.");
  expect(screen.getByRole("button", { name: "Load more" })).toBeEnabled();

  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await settle();
  expect(screen.getByText("Audit events couldn’t be loaded")).toBeInTheDocument();
  expect(screen.getByRole("alert")).toHaveTextContent("Audit storage is unavailable.");

  await user.click(screen.getByRole("button", { name: "Retry" }));
  await settle();
  expect(screen.getByText("No audit events yet")).toBeInTheDocument();
});

it("denies access when the operator may not use Admin", async () => {
  const view = await mountAuditLog({
    listAuditEvents: vi.fn(() => refuse(403, "forbidden")),
  });

  expect(view.links.denyAccess).toHaveBeenCalledTimes(1);
  expect(screen.getByText("Loading audit events…")).toBeInTheDocument();
});

it("filters by action and operator, and keeps a fixed target", async () => {
  const listAuditEvents = vi.fn(() => ok({ data: [], hasMore: false }));
  const view = mountModel(
    makeAuditLogModel({ targetId: "usr_one", targetType: "user" }),
    {
      api: { listAuditEvents },
    }
  );
  view.render(<AuditLogPanel model={view.model} />);
  await settle();
  const user = userEvent.setup({ delay: null });

  expect(listAuditEvents).toHaveBeenLastCalledWith({
    limit: 50,
    targetId: "usr_one",
    targetType: "user",
  });
  await user.click(screen.getByRole("button", { name: /Filter by action/ }));
  await user.click(await screen.findByRole("option", { name: "Create user" }));
  await settle();
  expect(listAuditEvents).toHaveBeenLastCalledWith({
    action: "create_user",
    limit: 50,
    targetId: "usr_one",
    targetType: "user",
  });
  expect(screen.getByText("No event matches these filters.")).toBeInTheDocument();

  await user.click(screen.getByRole("textbox", { name: "Filter by operator email" }));
  await user.paste("ops@example.com");
  await user.keyboard("{Enter}");
  await settle();
  expect(listAuditEvents).toHaveBeenLastCalledWith({
    action: "create_user",
    actorEmail: "ops@example.com",
    limit: 50,
    targetId: "usr_one",
    targetType: "user",
  });

  await user.click(screen.getByRole("button", { name: "Clear" }));
  await settle();
  expect(listAuditEvents).toHaveBeenLastCalledWith({
    limit: 50,
    targetId: "usr_one",
    targetType: "user",
  });
});
