import type { Meta, StoryObj } from "@storybook/react-vite";
import { useEffect, useRef, useState } from "react";
import { AiActivity, Button, Toaster, toast } from "../components";
import { motionDuration, motionEasing } from "../tokens";

/**
 * Every degraded/transient state in the client resolves to one of two shapes:
 * a toast (global, transient) or an inline item card (local, persistent).
 * These stories drive the real toast API and the real AiActivity component —
 * nothing here is a visual mock.
 */
const meta = {
  title: "Status feedback/Overview",
  parameters: { layout: "fullscreen" },
  decorators: [
    (Story) => (
      <>
        <Toaster />
        <div className="min-h-screen p-4xl">
          <Story />
        </div>
      </>
    ),
  ],
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

const Section = ({
  children,
  note,
  title,
}: {
  children: React.ReactNode;
  note?: string;
  title: string;
}) => (
  <section className="flex flex-col gap-md">
    <div className="flex flex-col gap-xxs">
      <h3 className="text-sm font-medium text-primary">{title}</h3>
      {note ? <p className="max-w-prose text-sm text-tertiary">{note}</p> : null}
    </div>
    <div className="flex flex-wrap items-center gap-sm">{children}</div>
  </section>
);

const DismissAll = () => (
  <Button hierarchy="tertiary-gray" onPress={() => toast.dismissAll()} size="sm">
    Dismiss all
  </Button>
);

export const Intents: Story = {
  render: () => (
    <div className="flex flex-col gap-3xl">
      <Section
        note="info and success shipped originally; warning and error were added so failures stop rendering as neutral notices."
        title="Four intents"
      >
        <Button
          hierarchy="secondary-gray"
          onPress={() =>
            toast.info("Copied message", { description: "Message copied to clipboard" })
          }
          size="sm"
        >
          info
        </Button>
        <Button
          hierarchy="secondary-gray"
          onPress={() =>
            toast.success("Update ready", {
              description: "Restart Comma to finish installing.",
            })
          }
          size="sm"
        >
          success
        </Button>
        <Button
          hierarchy="secondary-gray"
          onPress={() =>
            toast.warning("Connection interrupted", {
              description: "Showing the most recently synced content.",
            })
          }
          size="sm"
        >
          warning
        </Button>
        <Button
          hierarchy="secondary-gray"
          onPress={() =>
            toast.error("demo.aep upload failed", {
              description: "Reconnect this workspace's Comma Connector.",
            })
          }
          size="sm"
        >
          error
        </Button>
        <DismissAll />
      </Section>

      <Section
        note="Titles are text-sm/medium across all three variants; the status glyph is 20px so it sits on the 20px text line."
        title="Three variants"
      >
        <Button
          hierarchy="secondary-gray"
          onPress={() => toast.info("Single line only")}
          size="sm"
        >
          single
        </Button>
        <Button
          hierarchy="secondary-gray"
          onPress={() =>
            toast.info("With a description", {
              description: "A second line of detail.",
            })
          }
          size="sm"
        >
          description
        </Button>
        <Button
          hierarchy="secondary-gray"
          onPress={() =>
            toast.error("Send failed", {
              actions: [
                { label: "Retry" },
                { hierarchy: "tertiary-gray", label: "Discard" },
              ],
              description: "network unreachable",
            })
          }
          size="sm"
        >
          action (never auto-dismisses)
        </Button>
        <DismissAll />
      </Section>
    </div>
  ),
};

const DedupDemo = () => {
  const [count, setCount] = useState(0);

  return (
    <div className="flex flex-wrap items-center gap-sm">
      <Button
        hierarchy="secondary-gray"
        onPress={() => {
          const next = count + 1;
          setCount(next);
          toast.error(`${next} attachments failed to upload`, {
            description: "Reconnect this workspace's Comma Connector.",
            id: "chat-upload-error",
          });
        }}
        size="sm"
      >
        Fail another upload (shared id)
      </Button>
      <Button
        hierarchy="secondary-gray"
        onPress={() => {
          setCount((value) => value + 1);
          toast.error("Upload failed", { description: "No shared id — stacks up." });
        }}
        size="sm"
      >
        Same toast, no id
      </Button>
      <Button
        hierarchy="tertiary-gray"
        onPress={() => {
          setCount(0);
          toast.dismissAll();
        }}
        size="sm"
      >
        Reset
      </Button>
    </div>
  );
};

export const Deduplication: Story = {
  render: () => (
    <Section
      note="Product surfaces pass a fixed id so a repeating condition updates one toast in place instead of stacking. Three failed images produce one toast; the counter in the title is the only thing that changes. The right-hand button shows what omitting the id looks like."
      title="Dedup by toast id"
    >
      <DedupDemo />
    </Section>
  ),
};

const MotionReadout = () => (
  <dl className="grid grid-cols-[auto_1fr] gap-x-lg gap-y-xxs text-sm">
    <dt className="text-tertiary">enter</dt>
    <dd className="font-medium tabular-nums text-primary">
      {motionDuration.toastEnter}ms · {motionEasing.smoothOut}
    </dd>
    <dt className="text-tertiary">exit</dt>
    <dd className="font-medium tabular-nums text-primary">
      {motionDuration.toastExit}ms · {motionEasing.smoothOut}
    </dd>
    <dt className="text-tertiary">hover expand</dt>
    <dd className="font-medium tabular-nums text-primary">
      {motionDuration.spatialMove}ms · {motionEasing.smoothOut}
    </dd>
    <dt className="text-tertiary">shadow</dt>
    <dd className="font-medium tabular-nums text-primary">
      {motionDuration.stateChange}ms
    </dd>
  </dl>
);

const MotionDemo = () => {
  const idRef = useRef(0);

  const showTransient = () => {
    idRef.current += 1;
    const id = `motion-${idRef.current}`;
    toast.info(`Enter ${motionDuration.toastEnter}ms`, {
      description: `Auto-dismiss, then exit ${motionDuration.toastExit}ms`,
      duration: 1200,
      id,
    });
  };

  const showThenDismiss = () => {
    idRef.current += 1;
    const id = `motion-${idRef.current}`;
    toast.info("Watch the exit", {
      description: "Dismissed programmatically after 800ms",
      duration: Number.POSITIVE_INFINITY,
      id,
    });
    window.setTimeout(() => toast.dismiss(id), 800);
  };

  return (
    <div className="flex flex-wrap items-center gap-sm">
      <Button hierarchy="secondary-gray" onPress={showTransient} size="sm">
        Enter → auto exit
      </Button>
      <Button hierarchy="secondary-gray" onPress={showThenDismiss} size="sm">
        Enter → dismiss
      </Button>
      <Button
        hierarchy="secondary-gray"
        onPress={() => {
          for (let index = 0; index < 4; index += 1) {
            window.setTimeout(() => {
              idRef.current += 1;
              toast.info(`Stacked #${idRef.current}`, {
                description: "Max 3 visible; the rest collapse behind.",
                duration: Number.POSITIVE_INFINITY,
                id: `motion-${idRef.current}`,
              });
            }, index * 220);
          }
        }}
        size="sm"
      >
        Stack 4 (hover to expand)
      </Button>
      <DismissAll />
    </div>
  );
};

/**
 * The motion story: sonner ships 400ms default-ease transitions, which the Comma
 * layer retimes on tokens. Switch the Motion toolbar to "reduced" to confirm
 * sonner's prefers-reduced-motion reset still wins over the retiming.
 */
export const Motion: Story = {
  render: () => (
    <div className="flex flex-col gap-3xl">
      <Section
        note="Enter and exit are asymmetric in length, not in curve: arriving is announced, leaving gets out of the way sooner. Both run on the strong ease-out curve. In a stack the toast behind starts sliding into the dismissed one's slot on the same frame, so the leaver has to clear out first; an ease-in exit sat still and opaque for its first beat while the follower slid over it. The stack lift on hover and the copy it reveals share one clock."
        title="Timing"
      >
        <MotionReadout />
      </Section>
      <Section
        note="Trigger each phase in isolation. Stacking is capped at 3 visible toasts; hovering expands the collapsed peek."
        title="Play the phases"
      >
        <MotionDemo />
      </Section>
      <Section
        note="Reduced motion is not handled by the retiming above. Sonner's own prefers-reduced-motion rule zeroes every toast transition with !important, and the Comma overrides deliberately stay unlayered but non-important so that reset keeps winning. Comma's manual setting is covered separately: the data-comma-reduced-motion rule in styles.css zeroes transition-duration on every element, which is also what covers the stack list itself — sonner's reset does not reach it."
        title="Reduced motion"
      >
        <p className="max-w-prose text-sm text-tertiary">
          Toggle the <strong className="text-secondary">Motion</strong> item in the
          toolbar, then replay the buttons above.
        </p>
      </Section>
    </div>
  ),
};

const SlowMotionDemo = () => {
  const [slow, setSlow] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const root = document.documentElement;
    if (!slow) {
      root.style.removeProperty("--motion-duration-toast-enter");
      root.style.removeProperty("--motion-duration-toast-exit");
      return undefined;
    }
    root.style.setProperty(
      "--motion-duration-toast-enter",
      `${motionDuration.toastEnter * 6}ms`
    );
    root.style.setProperty(
      "--motion-duration-toast-exit",
      `${motionDuration.toastExit * 6}ms`
    );
    return () => {
      root.style.removeProperty("--motion-duration-toast-enter");
      root.style.removeProperty("--motion-duration-toast-exit");
    };
  }, [slow]);

  return (
    <div className="flex flex-wrap items-center gap-sm" ref={rootRef}>
      <Button
        hierarchy={slow ? "primary" : "secondary-gray"}
        onPress={() => setSlow((value) => !value)}
        size="sm"
      >
        {slow ? "Slow motion: on (6×)" : "Slow motion: off"}
      </Button>
      <Button
        hierarchy="secondary-gray"
        onPress={() => {
          const id = `slow-${Date.now()}`;
          toast.info("Slow enter and exit", {
            description: "Both phases stretched 6× for inspection.",
            duration: slow ? 2400 : 1200,
            id,
          });
        }}
        size="sm"
      >
        Show toast
      </Button>
      <DismissAll />
    </div>
  );
};

/** Stretches only the two duration tokens, so the curve stays authentic. */
export const MotionSlowMotion: Story = {
  name: "Motion / slow motion",
  render: () => (
    <Section
      note="Overrides --motion-duration-toast-enter / --motion-duration-toast-exit on the document root at 6×. The easing curves are untouched, so this shows the real motion, just stretched. The shadow channel runs on --motion-duration-state-change and stays at 1×."
      title="Inspect the curve"
    >
      <SlowMotionDemo />
    </Section>
  ),
};

/**
 * The other half of the system: conditions that must stay on screen next to
 * the thing they describe render as an inline item card instead of a toast.
 */
export const InlineItemCard: Story = {
  render: () => (
    <div className="flex max-w-[680px] flex-col gap-3xl">
      <Section
        note="Failure keeps the copy in text-primary and puts the error color on the 20px leading glyph only. The chevron stays visible (not hover-revealed) because a failed turn is a debugging entry point."
        title="AI activity — failed"
      >
        <div className="w-full">
          <AiActivity
            events={[
              { id: "e1", phase: "thinking", status: "complete", summary: "Planning" },
              {
                id: "e2",
                phase: "execution",
                status: "failed",
                summary: "Generation failed",
                toolName: "write_file",
              },
            ]}
            phase="execution"
            status="failed"
            summary="Generation failed · model overloaded"
          />
        </div>
      </Section>
      <Section
        note="Same treatment, running state, for comparison: no card chrome, shimmering copy, chevron hidden until hover."
        title="AI activity — running"
      >
        <div className="w-full">
          <AiActivity
            events={[
              { id: "e1", phase: "thinking", status: "complete", summary: "Planning" },
            ]}
            phase="thinking"
            status="running"
            summary="Thinking"
          />
        </div>
      </Section>
    </div>
  ),
};
