import { composeStories, setProjectAnnotations } from "@storybook/react-vite";
import { storyNameFromExport } from "storybook/internal/csf";
import { beforeAll, describe, it, vi } from "vitest";
import preview from "../../../.storybook/preview";

// Every story runs here, in jsdom, with the Storybook preview's decorators and
// globals, and runs its play function. A story whose play function or
// rendering needs real layout, CSS, canvas or browser APIs carries the
// `browser` tag instead; the `storybook` project runs it in Chromium.

// Storybook bundles its own user-event, which waits between interactions on
// timers nothing moves on the test clock (test-clock.ts). Play functions get
// the shared user-event instead, which moves that clock as it waits. After each
// interaction what it started runs, as a browser renders before the play
// function's next step.
vi.mock("storybook/test", async (importOriginal) => {
  const { userEvent } = await import("@testing-library/user-event");
  const { act } = await import("@testing-library/react");
  const settled = Object.fromEntries(
    Object.entries(userEvent).map(([name, method]) => [
      name,
      typeof method === "function" && name !== "setup"
        ? async (...args: unknown[]) => {
            const result = await (method as (...a: unknown[]) => unknown)(...args);
            await act(() => vi.advanceTimersByTimeAsync(0));
            return result;
          }
        : method,
    ])
  );
  return {
    ...(await importOriginal<typeof import("storybook/test")>()),
    userEvent: settled,
  };
});

type StoryModule = Parameters<typeof composeStories>[0] &
  Record<string, { name?: string; storyName?: string }>;

const annotations = setProjectAnnotations([preview]);
beforeAll(annotations.beforeAll);

const storyFiles = import.meta.glob<StoryModule>([
  "/packages/ui/src/**/*.stories.tsx",
  "/packages/app/src/**/*.stories.tsx",
]);

for (const [path, load] of Object.entries(storyFiles)) {
  const module = await load();
  // Tests take the story's display name, as the Storybook Vitest plugin names them.
  const stories = Object.entries(composeStories(module))
    .filter(
      ([, story]) => story.tags.includes("test") && !story.tags.includes("browser")
    )
    .map(([exportName, story]) => {
      const { name, storyName } = module[exportName]!;
      return { name: name ?? storyName ?? storyNameFromExport(exportName), story };
    });
  if (stories.length === 0) continue;

  describe(path.slice(1), () => {
    for (const { name, story } of stories) it(name, () => story.run());
  });
}
