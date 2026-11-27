import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { cleanup, render } from "@comma/test-utils/render";
import {
  createMemoryHistory,
  createRootRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import { afterEach, expect, it } from "vitest";
import { page } from "vitest/browser";
import { InboxJoinedRowView } from "../TaskRequestInbox";

afterEach(cleanup);

it("draws a joined person's face whole inside the row's icon slot", async () => {
  await page.viewport(400, 200);
  const core = createScriptedCore({ values: () => undefined });
  const root = createRootRoute({
    component: () =>
      core.wrap(
        <div className="w-[338px] bg-main-panel-bg p-md">
          <InboxJoinedRowView
            onDelete={() => undefined}
            row={{
              kind: "people_joined",
              id: "people-joined:g1",
              updatedAt: 0,
              person: { id: "u2", name: null, email: "catsjuice+1@cue.surf" },
              avatar: null,
            }}
          />
        </div>
      ),
  });
  const router = createRouter({
    routeTree: root,
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  await router.load();
  const { container } = render(<RouterProvider router={router} />);

  const slot = container
    .querySelector('[data-slot="task-list-item-icon"]')!
    .getBoundingClientRect();
  const face = container
    .querySelector(".comma-user-avatar > span")!
    .getBoundingClientRect();
  // The slot clips what overflows it: a face larger than it shows as a square with its corners cut.
  expect(face.width).toBeLessThanOrEqual(slot.width);
  expect(face.height).toBeLessThanOrEqual(slot.height);
});
