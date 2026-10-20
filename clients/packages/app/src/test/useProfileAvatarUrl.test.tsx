import { act, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, expect, it, vi } from "vitest";
import { useProfileAvatarUrl } from "../components/useProfileAvatarUrl";

afterEach(() => vi.restoreAllMocks());

const shown = () => screen.getByTestId("avatar").textContent;

function Shown({ revision }: { revision?: string }) {
  return <span data-testid="avatar">{useProfileAvatarUrl(revision) ?? ""}</span>;
}

it("keeps the shown avatar's URL until the next revision replaces it", async () => {
  const reads: Array<{ revision: string; answer: () => void }> = [];
  const core = createScriptedCore({
    calls: (name, params) => {
      if (name !== "files.read") return null;
      const { revision } = params as { revision: string };
      return new Promise((resolve) =>
        reads.push({
          revision,
          answer: () => resolve({ bytes: new Uint8Array([1]), type: "image/png" }),
        })
      );
    },
  });
  let made = 0;
  vi.spyOn(URL, "createObjectURL").mockImplementation(() => `blob:${++made}`);
  const revoked = vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {});

  const view = render(core.wrap(<Shown revision="pending-1" />));
  await act(async () => {});
  expect(reads).toHaveLength(1);
  await act(async () => reads[0]!.answer());
  expect(shown()).toBe("blob:1");

  // The upload settled: the saved revision loads while the upload's bytes show.
  view.rerender(core.wrap(<Shown revision="avt_1" />));
  await act(async () => {});
  expect(reads).toHaveLength(2);
  expect(shown()).toBe("blob:1");
  expect(revoked).not.toHaveBeenCalled();

  await act(async () => reads[1]!.answer());
  expect(shown()).toBe("blob:2");
  expect(revoked).toHaveBeenCalledWith("blob:1");
  expect(revoked).not.toHaveBeenCalledWith("blob:2");

  view.unmount();
  expect(revoked).toHaveBeenCalledWith("blob:2");
});
