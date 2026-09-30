import type { Meta, StoryObj } from "@storybook/react-vite";
import type { ReactNode } from "react";
import { WidgetFailureNotice, type WidgetFailure } from "./WidgetFailureNotice";

/**
 * A widget that could not show under its text answer, as the chat renders it.
 * The app sheet adds the notice's top margin; the wrapper stands in for it here.
 */
const meta = {
  title: "Chat/Widget failure",
  parameters: { layout: "fullscreen" },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

const summary =
  "Shanghai tomorrow (Thu, Sep 24): mostly cloudy, 24–29°C, humidity about 63%, feels warm and a little muggy. Rain chance 0–10%, no umbrella needed. Air quality good (AQI 33).";

const Chat = ({
  theme,
  children,
}: {
  theme: "Light mode" | "Dark mode";
  children: ReactNode;
}) => (
  <div
    className={`flex flex-col gap-3xl bg-main-panel-bg p-3xl${theme === "Dark mode" ? " dark" : ""}`}
    data-theme={theme}
  >
    {children}
  </div>
);

const Failed = ({ failure }: { failure: WidgetFailure }) => (
  <div className="w-[720px] max-w-full">
    <p className="m-0 text-sm text-secondary">{summary}</p>
    <div className="pt-md">
      <WidgetFailureNotice failure={failure} onRetry={() => {}} />
    </div>
  </div>
);

const gallery = (
  <div className="grid grid-cols-2">
    {(["Light mode", "Dark mode"] as const).map((theme) => (
      <Chat key={theme} theme={theme}>
        <Failed failure={{ kind: "load", reason: "upstream_unavailable" }} />
        <Failed
          failure={{ kind: "display", reason: "UI tree exceeds its node budget" }}
        />
      </Chat>
    ))}
  </div>
);

export const States: Story = {
  name: "Load and display failures",
  render: () => gallery,
};
