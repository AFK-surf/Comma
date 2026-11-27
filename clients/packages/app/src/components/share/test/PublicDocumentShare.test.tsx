import { render, screen } from "@comma/test-utils/render";
import { expect, it } from "vitest";
import { PublicShareError, type PublicShareClient } from "../publicShareApi";
import { PublicTaskShareApp } from "../PublicTaskShareApp";

it("shows a document link as the document's page, with no Task around it", async () => {
  const client: PublicShareClient = {
    summary: async () => ({
      kind: "document",
      file_name: "plan.md",
      size: 30,
      shared_at: 1_700_000_000,
    }),
    document: async () =>
      new Blob(["# Plan\n\nThe plugin talks to the desktop.\n"], {
        type: "text/markdown",
      }),
    // A document link has no Messages: the server answers none.
    messages: async () => {
      throw new PublicShareError("not_found");
    },
    attachment: async () => {
      throw new PublicShareError("not_found");
    },
  };
  render(<PublicTaskShareApp client={client} />);
  const page = await screen.findByTestId("share-view-document");
  expect(await screen.findByText("The plugin talks to the desktop.")).toBeVisible();
  expect(page.textContent).toContain("plan.md");
  expect(screen.getByRole("button", { name: "Download" })).toBeVisible();
  expect(screen.queryByTestId("share-view-thread")).toBeNull();
  expect(document.title).toBe("plan.md");
});
