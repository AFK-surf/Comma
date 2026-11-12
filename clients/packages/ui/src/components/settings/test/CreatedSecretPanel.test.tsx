import { act, fireEvent, render, screen } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import { CreatedSecretPanel } from "../CreatedSecretPanel";
import { toast, Toaster } from "../../toast";

afterEach(() => {
  act(() => toast.dismissAll());
});

it("confirms secret and example copies without exposing their values in feedback", async () => {
  const onCopy = vi.fn().mockResolvedValue(undefined);
  render(
    <>
      <CreatedSecretPanel
        label="New credential"
        name="Integration"
        badge="Shown once"
        description="Save this credential"
        secret="private-secret"
        example="command --token private-secret"
        copyLabel="Copy secret"
        copiedLabel="Copied"
        copyExampleLabel="Copy command"
        doneLabel="Done"
        onCopy={onCopy}
        onDismiss={() => {}}
      />
      <Toaster />
    </>
  );
  fireEvent.click(screen.getByRole("button", { name: "Copy secret" }));
  expect(await screen.findByTestId("copy-feedback")).toHaveTextContent("Copied");
  expect(onCopy).toHaveBeenLastCalledWith("private-secret");
  expect(screen.getByTestId("copy-feedback")).not.toHaveTextContent("private-secret");

  onCopy.mockRejectedValueOnce(new Error("denied"));
  fireEvent.click(screen.getByRole("button", { name: "Copy command" }));
  expect(await screen.findByText("Couldn’t copy")).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Copy command" })).toBeInTheDocument();

  fireEvent.click(screen.getByRole("button", { name: "Copy command" }));
  expect(
    await screen.findByRole("button", { name: "Copy secret" })
  ).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Copied" })).toBeInTheDocument();
  expect(onCopy).toHaveBeenLastCalledWith("command --token private-secret");
  expect(screen.getByTestId("copy-feedback")).not.toHaveTextContent("private-secret");
});
