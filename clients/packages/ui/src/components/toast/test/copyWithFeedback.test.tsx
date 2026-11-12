import { messages } from "@comma/i18n";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { afterEach, expect, it } from "vitest";
import { copyWithFeedback, toast, Toaster } from "..";

afterEach(() => {
  act(() => toast.dismissAll());
});

it("waits for the clipboard and replaces repeated feedback with a failure", async () => {
  render(<Toaster />);
  let resolveWrite!: () => void;
  const write = new Promise<void>((resolve) => {
    resolveWrite = resolve;
  });
  const pendingCopy = copyWithFeedback(() => write, messages);
  expect(screen.queryByTestId("copy-feedback")).not.toBeInTheDocument();

  await act(async () => {
    resolveWrite();
    expect(await pendingCopy).toBe(true);
  });
  expect(await screen.findByTestId("copy-feedback")).toHaveTextContent("Copied");

  await act(async () => {
    await copyWithFeedback(() => Promise.resolve(), messages);
  });
  expect(screen.getAllByTestId("copy-feedback")).toHaveLength(1);

  await act(async () => {
    expect(
      await copyWithFeedback(() => Promise.reject(new Error("denied")), messages)
    ).toBe(false);
  });
  await waitFor(() => {
    expect(screen.getByTestId("copy-feedback")).toHaveTextContent("Couldn’t copy");
  });
  expect(screen.getAllByTestId("copy-feedback")).toHaveLength(1);
  expect(screen.getByTestId("copy-feedback")).toHaveTextContent(
    "Nothing was copied to the clipboard."
  );
});

it("names what was copied, keeps a surface's toast id, and can stay quiet on failure", async () => {
  render(<Toaster />);
  await act(async () => {
    await copyWithFeedback(() => Promise.resolve(), messages, {
      copied: "Link copied",
      copiedDetail: "Paste it anywhere",
      id: "share-feedback",
    });
  });
  expect(await screen.findByTestId("copy-feedback")).toHaveTextContent("Link copied");
  expect(screen.getByTestId("copy-feedback")).toHaveTextContent("Paste it anywhere");

  await act(async () => {
    expect(
      await copyWithFeedback(() => Promise.reject(new Error("denied")), messages, {
        id: "share-feedback",
        reportFailure: false,
      })
    ).toBe(false);
  });
  expect(screen.getAllByTestId("copy-feedback")).toHaveLength(1);
  expect(screen.getByTestId("copy-feedback")).toHaveTextContent("Link copied");
});
