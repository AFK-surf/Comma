import { CoreClient, CoreProvider, type ListedScreen } from "@comma/core-client";
import type { Meta, StoryObj } from "@storybook/react-vite";
import "../../styles.css";
import { ScreenDebugBar } from "./ScreenDebugBar";

const screen: ListedScreen = {
  id: "simulator:A119A827-41D5-49E0-9689-710DB19BF30E",
  instance: "i1",
  name: "iPhone 17 Pro",
  title: "iPhone 17 Pro · iOS 27.2",
  width: 1206,
  height: 2622,
  peek: true,
  capabilities: {
    input: "touch",
    buttons: [],
    panels: [],
    debug: {
      actions: ["restart", "screenshot", "record", "install", "appearance"],
      install: [".ipa", ".zip"],
    },
  },
};

/** A core that says the device records now and stands dark. */
const recordingCore = () =>
  new CoreClient(
    (onMessage) => ({
      post(raw) {
        const { id } = raw as { id: number };
        queueMicrotask(() =>
          onMessage({ id, ok: { recording: true, appearance: "dark" } })
        );
      },
      close() {},
    }),
    { schedule: () => undefined }
  );

const meta = {
  component: ScreenDebugBar,
  title: "Remote screen/ScreenDebugBar",
  args: {
    workspace: "wsp_1",
    device: "dev_1",
    screen,
    live: true,
    picture: () => null,
  },
  decorators: [
    (Story, { parameters }) => (
      <div
        className="comma-remote-screen-panel"
        data-state="live"
        style={{ width: (parameters as { width?: number }).width ?? 360 }}
      >
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof ScreenDebugBar>;

export default meta;
type Story = StoryObj<typeof meta>;

/** All five, on a simulator. */
export const Simulator: Story = {};
/** A recording going on, the device dark: Stop in red, and the way back to light. */
export const Recording: Story = {
  decorators: [
    (Story) => (
      <CoreProvider client={recordingCore()}>
        <Story />
      </CoreProvider>
    ),
  ],
};
/** A panel as narrow as the sidebar goes: the row wraps. */
export const Narrow: Story = { parameters: { width: 112 } };
/** An emulator whose Android has no dark theme: only what it can do. */
export const OlderAndroid: Story = {
  args: {
    screen: {
      ...screen,
      id: "android:emulator-5554",
      capabilities: {
        ...screen.capabilities,
        debug: {
          actions: ["restart", "screenshot", "record", "install"],
          install: [".apk"],
        },
      },
    },
  },
};
