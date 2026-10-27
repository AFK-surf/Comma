import { afterEach, beforeEach, expect, test } from "vitest";
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
} from "@testing-library/react";
import { App } from "./App";
import { createMockComma, type MockComma } from "./comma/mock";

let mock: MockComma;

beforeEach(() => {
  mock = createMockComma({
    viewer: { id: "v1", name: "Ada", avatarUrl: null, guest: false },
  });
  Object.defineProperty(globalThis, "comma", {
    value: mock,
    configurable: true,
  });
});

afterEach(() => {
  cleanup();
  Reflect.deleteProperty(globalThis, "comma");
});

// The mock answers with promises only, so settling them is the wait.
const settle = (run: () => void) =>
  act(async () => {
    run();
  });

test("writes a note in a sheet, opens it and deletes it", async () => {
  await settle(() => render(<App />));
  expect(screen.getByRole("button", { name: "Notes" })).toBeTruthy();

  // The bar's action; the empty list offers the same.
  await settle(() =>
    fireEvent.click(screen.getAllByRole("button", { name: "New note" })[0]!),
  );
  fireEvent.change(screen.getByLabelText("Note"), {
    target: { value: "Buy milk\nand eggs" },
  });
  await settle(() => fireEvent.click(screen.getByRole("button", { name: "Add" })));
  expect(mock.mock.stores.user.get("notes")?.value).toEqual([
    expect.objectContaining({ text: "Buy milk\nand eggs" }),
  ]);

  // The first line is the note's title; the row opens the note.
  await settle(() => fireEvent.click(screen.getByRole("button", { name: /Buy milk/ })));
  expect(screen.getByRole("heading", { name: "Buy milk", level: 2 })).toBeTruthy();
  expect(screen.getByText("and eggs")).toBeTruthy();
  await settle(() =>
    fireEvent.click(screen.getByRole("button", { name: "Delete note" })),
  );
  await settle(() => fireEvent.click(screen.getByRole("button", { name: "Delete" })));
  expect(mock.mock.stores.user.get("notes")?.value).toEqual([]);
});

test("opens a note kept by an earlier version of the app, which has no date", async () => {
  mock.mock.stores.user.set("notes", {
    value: [{ id: "old", text: "Old note\nfrom before" }],
    version: 1,
  });
  await settle(() => render(<App />));
  await settle(() => fireEvent.click(screen.getByRole("button", { name: /Old note/ })));
  expect(screen.getByRole("heading", { name: "Old note", level: 2 })).toBeTruthy();
});

test("keeps a note being written when the frame crosses into the regular size class", async () => {
  // A frame whose width the test sets: 639px is compact, 640px regular.
  let width = 639;
  const listeners = new Set<() => void>();
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: (query: string) => ({
      get matches() {
        const min = /min-width: (\d+)px/.exec(query);
        return min ? width >= Number(min[1]) : false;
      },
      addEventListener: (_: string, listener: () => void) => listeners.add(listener),
      removeEventListener: (_: string, listener: () => void) =>
        listeners.delete(listener),
    }),
  });
  try {
    await settle(() => render(<App />));
    await settle(() =>
      fireEvent.click(screen.getAllByRole("button", { name: "New note" })[0]!),
    );
    fireEvent.change(screen.getByLabelText("Note"), { target: { value: "Half a thought" } });

    await settle(() => {
      width = 640;
      for (const listener of listeners) listener();
    });
    expect((screen.getByLabelText("Note") as HTMLTextAreaElement).value).toBe(
      "Half a thought",
    );
  } finally {
    Reflect.deleteProperty(window, "matchMedia");
  }
});
