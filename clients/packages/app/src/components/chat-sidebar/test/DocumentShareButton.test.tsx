import { fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { expect, it } from "vitest";
import { DocumentShareButton } from "../DocumentShareButton";

const target = {
  groupId: "grp",
  conversationId: "cnv",
  messageId: "m2",
  attachmentIndex: 1,
  fileName: "plan.md",
};
const link = (message: string) => ({
  url: "https://comma.test/s/one",
  file_name: "plan.md",
  message_id: message,
  index: 1,
  created_at: 1,
  shared_at: 2,
});

it("creates a document's public link of the version shown, and stops it", async () => {
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    calls: (name, params) => {
      calls.push([name, params]);
      return name === "documentShare.publish" ? link("m2") : null;
    },
  });
  render(core.wrap(<DocumentShareButton target={target} />));
  fireEvent.click(screen.getByRole("button", { name: "Share" }));
  // The document has no link yet: the dialog offers to make one.
  fireEvent.click(await screen.findByRole("button", { name: "Create public link" }));
  expect(await screen.findByLabelText("Public link")).toHaveValue(
    "https://comma.test/s/one"
  );
  expect(calls).toEqual([
    ["documentShare.get", { group: "grp", conversation: "cnv", fileName: "plan.md" }],
    [
      "documentShare.publish",
      { group: "grp", conversation: "cnv", message: "m2", index: 1 },
    ],
  ]);
  // The link shows the version on the page: there is nothing to update.
  expect(screen.queryByTestId("document-share-other-version")).toBeNull();

  fireEvent.click(screen.getByRole("button", { name: "Link actions" }));
  fireEvent.click(await screen.findByRole("menuitem", { name: "Stop sharing" }));
  expect(
    await screen.findByRole("button", { name: "Create public link" })
  ).toBeVisible();
  expect(calls.at(-1)).toEqual([
    "documentShare.revoke",
    { group: "grp", conversation: "cnv", fileName: "plan.md" },
  ]);
});

it("says a link shows another version than the page, and moves the link to the page's", async () => {
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    calls: (name, params) => {
      calls.push([name, params]);
      return name === "documentShare.get" ? link("m1") : link("m2");
    },
  });
  render(core.wrap(<DocumentShareButton target={target} />));
  fireEvent.click(screen.getByRole("button", { name: "Share" }));
  const notice = await screen.findByTestId("document-share-other-version");
  expect(notice.textContent).toContain("another version");
  fireEvent.click(screen.getByRole("button", { name: /^Update link/u }));
  // The link now shows the page's version: the notice goes.
  await waitFor(() =>
    expect(screen.queryByTestId("document-share-other-version")).toBeNull()
  );
  expect(screen.getByLabelText("Public link")).toHaveValue("https://comma.test/s/one");
  expect(calls.at(-1)).toEqual([
    "documentShare.publish",
    { group: "grp", conversation: "cnv", message: "m2", index: 1 },
  ]);
});
