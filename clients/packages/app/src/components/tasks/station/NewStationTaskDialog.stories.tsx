import type { Meta, StoryObj } from "@storybook/react-vite";
import { CoreClient, CoreProvider } from "@comma/core-client";
import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRouter,
} from "@tanstack/react-router";
import { useState } from "react";
import "../../../styles.css";
import { NewStationTaskDialog } from "./NewStationTaskDialog";

const workspace = "storybook-workspace";

const catalogModel = (id: string, name: string, vendor: string) => ({
  id,
  name,
  vendor,
  efforts: [],
  serving: ["profile"],
});

/** A core that lists `stations` and the workspace's models, and answers the dialog's calls. */
function storyCore(stations: unknown[]) {
  return new CoreClient(
    (onMessage) => ({
      post(raw) {
        const message = raw as {
          id: number;
          call?: string;
          params?: { name?: string };
          subscribe?: { topic: string };
        };
        const answer = (data: unknown) => queueMicrotask(() => onMessage(data));
        if (message.subscribe?.topic === "stations")
          answer({
            id: message.id,
            value: { workspace, loading: false, stations },
          });
        else if (message.subscribe?.topic === "models")
          answer({
            id: message.id,
            value: {
              workspace,
              catalog: { sources: {}, models: [] },
              presets: [],
              profiles: [],
              moreProfiles: false,
              models: [
                catalogModel("claude-opus-5-5", "Claude Opus 5.5", "anthropic"),
                catalogModel("gpt-5.5", "GPT 5.5", "openai"),
              ],
              agents: null,
              error: false,
            },
          });
        else if (
          message.call === "chat.uploadTaskFile" ||
          message.call === "stations.upload"
        )
          answer({
            id: message.id,
            ok: {
              name: message.params?.name,
              path: `/uploads/${"s".repeat(22)}-${message.params?.name}`,
              size: 1_200_000,
            },
          });
        else if (message.call === "stations.profiles")
          answer({
            id: message.id,
            ok: [
              {
                id: "work",
                name: "Work",
                runtimes: ["claude"],
                model: "claude-opus-5-5",
                models: ["claude-opus-5-5", "claude-sonnet-5-5"],
              },
            ],
          });
        else if (message.call) answer({ id: message.id, ok: null });
      },
      close() {},
    }),
    { schedule: () => undefined }
  );
}

function StoryDialog() {
  return <NewStationTaskDialog onClose={() => {}} workspace={workspace} />;
}

function DialogStory({ stations }: { stations: unknown[] }) {
  const [client] = useState(() => storyCore(stations));
  const [router] = useState(() =>
    createRouter({
      routeTree: createRootRoute({ component: StoryDialog }),
      history: createMemoryHistory({ initialEntries: ["/"] }),
    })
  );
  return (
    <CoreProvider client={client}>
      <RouterProvider router={router} />
    </CoreProvider>
  );
}

const meta = {
  title: "App/Tasks/NewStationTaskDialog",
  component: DialogStory,
  parameters: { layout: "fullscreen" },
} satisfies Meta<typeof DialogStory>;

export default meta;
type Story = StoryObj<typeof meta>;

/** No computer of the workspace is reached: the Task runs in Comma's cloud, on a model of the workspace. */
export const Cloud: Story = { args: { stations: [] } };

/** A computer is connected: its models are offered beside Create. */
export const MachineConnected: Story = {
  args: {
    stations: [
      {
        id: "st_mac",
        name: "MacBook Pro",
        version: "1",
        present: true,
        enrolledAt: null,
        enrolledBy: null,
        link: { state: "online" },
      },
    ],
  },
};
