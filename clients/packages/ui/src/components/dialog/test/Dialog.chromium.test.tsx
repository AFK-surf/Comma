import "@comma/ui/styles.css";

import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import { page, userEvent } from "vitest/browser";

// Focus return when a dialog closes while its opener is still inert, in real
// Chromium. A closing dialog nested over Settings lifts Settings' `inert` in a
// React passive-effect cleanup, and that cleanup can run after React Aria's
// one-frame focus return.

let root: Root | undefined;

function Fixture() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <div data-testid="opener-region">
        <Button hierarchy="primary" onPress={() => setOpen(true)}>
          Open dialog
        </Button>
      </div>
      <Button hierarchy="secondary-gray">Elsewhere</Button>
      <Dialog
        isOpen={open}
        onOpenChange={setOpen}
        title="Crop avatar"
        actions={[{ label: "Cancel", hierarchy: "secondary-gray" }]}
      />
    </>
  );
}

const nextFrame = () =>
  new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));

/** Opens the dialog, closes it with the opener held inert past its focus return. */
async function closeWhileOpenerInert() {
  const host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  root.render(<Fixture />);
  const opener = page.getByRole("button", { name: "Open dialog" });
  await userEvent.click(opener);
  await expect.element(page.getByRole("dialog")).toBeVisible();

  // Stands in for the outer modal whose `inert` outlives the closing dialog.
  const region = page.getByTestId("opener-region").element() as HTMLElement;
  region.inert = true;
  await userEvent.keyboard("{Escape}");
  for (const animation of document.getAnimations()) animation.finish();
  await expect.element(page.getByRole("dialog")).not.toBeInTheDocument();
  // React Aria's return has run and missed the inert opener.
  await nextFrame();
  await nextFrame();
  expect(document.activeElement).toBe(document.body);
  return { opener: opener.element(), region };
}

afterEach(() => {
  root?.unmount();
  root = undefined;
  document.body.replaceChildren();
});

describe("Dialog focus return", () => {
  it("returns focus to the opener once it is no longer inert", async () => {
    const { opener, region } = await closeWhileOpenerInert();

    region.inert = false;

    await expect.poll(() => document.activeElement).toBe(opener);
  });

  it("leaves focus where it went while the opener was inert", async () => {
    const { region } = await closeWhileOpenerInert();
    const elsewhere = page.getByRole("button", { name: "Elsewhere" }).element();

    (elsewhere as HTMLElement).focus();
    region.inert = false;
    await nextFrame();

    expect(document.activeElement).toBe(elsewhere);
  });
});
