import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import { Button, Toaster, toast } from "../index";
import type { ToastPosition } from "./toastApi";

const meta = {
  title: "App components/Toast",
  parameters: {
    layout: "fullscreen",
  },
  decorators: [
    (Story) => (
      <>
        <Toaster />
        <div className="flex min-h-screen items-center justify-center p-xl">
          <Story />
        </div>
      </>
    ),
  ],
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

const ToastDemo = ({ onShow, label }: { onShow: () => void; label: string }) => (
  <div className="flex flex-col items-center gap-md">
    <Button hierarchy="secondary-gray" onPress={onShow}>
      {label}
    </Button>
    <Button hierarchy="tertiary-gray" onPress={() => toast.dismissAll()}>
      Dismiss all
    </Button>
  </div>
);

export const Single: Story = {
  render: () => (
    <ToastDemo label="Show toast" onShow={() => toast("Titled copied to clipboard")} />
  ),
};

export const WithDescription: Story = {
  render: () => (
    <ToastDemo
      label="Show toast"
      onShow={() =>
        toast("Titled copied to clipboard", {
          description: "Keep it short and recognizable",
        })
      }
    />
  ),
};

export const Action: Story = {
  render: () => (
    <ToastDemo
      label="Show toast"
      onShow={() =>
        toast.success("Download complete", {
          description: "Keep it short and recognizable",
          actions: [
            { label: "Reveal in Finder", hierarchy: "secondary-gray" },
            { label: "Open file", hierarchy: "tertiary-gray" },
          ],
        })
      }
    />
  ),
};

const StackDemo = () => {
  const [count, setCount] = useState(0);

  return (
    <ToastDemo
      label="Push toast"
      onShow={() => {
        setCount((value) => value + 1);
        toast("Titled copied to clipboard", {
          description: `Toast #${count + 1} — hover the stack to expand`,
        });
      }}
    />
  );
};

export const Stack: Story = {
  render: () => <StackDemo />,
};

const positions: ToastPosition[] = [
  "top-left",
  "top-center",
  "top-right",
  "bottom-left",
  "bottom-center",
  "bottom-right",
];

export const Position: Story = {
  render: () => (
    <div className="flex flex-col items-center gap-md">
      <p className="text-sm text-secondary">Click a corner to push a toast there.</p>
      <div className="grid grid-cols-3 gap-sm">
        {positions.map((position) => (
          <Button
            key={position}
            hierarchy="secondary-gray"
            onPress={() =>
              toast(`Toast at ${position}`, {
                position,
                description: "Per-toast position overrides the Toaster default.",
              })
            }
          >
            {position}
          </Button>
        ))}
      </div>
      <Button hierarchy="tertiary-gray" onPress={() => toast.dismissAll()}>
        Dismiss all
      </Button>
    </div>
  ),
};

const TopRightStackDemo = () => {
  const [count, setCount] = useState(0);

  return (
    <ToastDemo
      label="Push toast"
      onShow={() => {
        setCount((value) => value + 1);
        toast("Titled copied to clipboard", {
          description: `Top-right toast #${count + 1}`,
        });
      }}
    />
  );
};

/** The product default is bottom-right; this shows the top-right override. */
export const TopRightStack: Story = {
  decorators: [
    (Story) => (
      <>
        <Toaster position="top-right" />
        <div className="flex min-h-screen items-center justify-center p-xl">
          <Story />
        </div>
      </>
    ),
  ],
  render: () => <TopRightStackDemo />,
};
