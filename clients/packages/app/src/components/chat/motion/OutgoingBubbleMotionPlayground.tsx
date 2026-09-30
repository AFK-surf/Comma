import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  RouterProvider,
} from "@tanstack/react-router";
import { Pane } from "tweakpane";
import { Button, ScrollArea, motionMessageSend } from "@comma/ui";
import {
  ConversationView,
  type ConversationViewActions,
} from "../conversation/ConversationView";
import { fixedDraftSource } from "../composer/conversationDraft";
import type { OutgoingBubblePlaybackRate } from "./outgoingBubbleMotion";
import type {
  ChatMessage,
  ConversationChannelState,
} from "../model/conversationChannel";
import {
  createOutgoingBubbleTimeline,
  messageSendChannels,
  messageSendSpringRanges,
  messageSendBezierRanges,
  messageSendPulseRanges,
  normalizeMessageSendMotion,
} from "./outgoingBubbleMotionModel";

const labels = { width: "Width", position: "Position", height: "Height" };
const colors = { width: "#3563e9", position: "#8b5cf6", height: "#d17a1e" };
const presets = {
  "Single line": "A small message with a gentle spring.",
  Multiline:
    "这条消息从输入框过渡到最终气泡。\n宽度支持 Spring 和贝塞尔曲线。\n位置和高度可独立调整响应时间、阻尼和延迟。",
  "Long text":
    "消息发送时，文字从输入框的原始状态开始，随着气泡宽度变化调整换行。".repeat(55),
};

function demoMessage(
  messageId: string,
  role: ChatMessage["role"],
  text: string
): ChatMessage {
  return {
    messageId,
    role,
    text,
    parts: [{ kind: "markdown", text }],
    attachments: [],
    refs: [],
    blocksKey: undefined,
    createdBy: undefined,
    error: undefined,
    status: "active",
    createdAt: Date.now(),
    delivery: "sent",
    source: "server",
  };
}

const context = demoMessage(
  "context",
  "assistant",
  "Try a short or multiline message. Tune each curve, then replay to compare the motion.\n\n".repeat(
    10
  )
);
function initialState(): ConversationChannelState {
  return {
    activity: undefined,
    assistantDraft: undefined,
    awaitingReply: false,
    awaitingSince: undefined,
    awaitingTimedOut: false,
    connection: "live",
    conversation: {
      id: "motion-preview",
      group_id: "preview",
      kind: "user_chat",
      title: "Send animation",
      status: "completed",
    },
    draft: presets.Multiline,
    draftAttachments: [],
    errorKind: undefined,
    lastBackoffMs: 0,
    messages: [context],
    pending: [],
    participantStatus: undefined,
    serverMessages: [],
    status: "ready",
    syncWarning: undefined,
  };
}

const springFields = {
  response: "Response (s)",
  dampingRatio: "Damping ratio",
  initialVelocity: "Initial velocity",
  delayMs: "Delay (ms)",
  maxOvershootPx: "Rebound limit (px)",
};
const bezierFields = {
  durationMs: "Duration (ms)",
  x1: "X1",
  y1: "Y1",
  x2: "X2",
  y2: "Y2",
  delayMs: "Delay (ms)",
};
const bezierRanges = {
  ...messageSendBezierRanges,
  delayMs: messageSendSpringRanges.delayMs,
};
const pulseFields = {
  amount: "Compression ratio",
  response: "Response (s)",
  dampingRatio: "Damping ratio",
  delayMs: "Delay (ms)",
};
function MotionControls({
  label,
  config,
  onChange,
  fields,
  ranges,
}: {
  label: string;
  config: Record<string, number>;
  onChange: (config: Record<string, number>) => void;
  fields: Record<string, string>;
  ranges: Record<string, { min: number; max: number; step: number }>;
}) {
  const host = useRef<HTMLDivElement>(null);
  const pane = useRef<Pane | undefined>(undefined);
  const params = useRef({ ...config });
  const callback = useRef(onChange);
  callback.current = onChange;
  useEffect(() => {
    if (!host.current) return;
    const editor = new Pane({ container: host.current });
    pane.current = editor;
    for (const name of Object.keys(fields)) {
      const binding = editor.addBinding(params.current, name, {
        label: fields[name]!,
        ...ranges[name]!,
      });
      binding.element
        .querySelector("input")
        ?.setAttribute("aria-label", `${label} ${fields[name]}`);
      binding.on("change", () => {
        // Keep copied slider values readable instead of exporting floating-point noise.
        params.current[name] = Number(params.current[name]!.toFixed(4));
        callback.current({ ...params.current });
      });
    }
    return () => {
      editor.dispose();
      pane.current = undefined;
    };
  }, [label, fields, ranges]);
  useEffect(() => {
    Object.assign(params.current, config);
    pane.current?.refresh();
  }, [config]);
  return <div ref={host} data-spring-controls={label.toLowerCase()} />;
}

function Playground() {
  const [config, setConfig] = useState(() => normalizeMessageSendMotion());
  const [state, setState] = useState(initialState);
  const draftSource = useMemo(() => fixedDraftSource(state.draft), [state.draft]);
  const [variant, setVariant] = useState<"route" | "side-chat">("route");
  const [replay, setReplay] = useState(0);
  const [playbackRate, setPlaybackRate] = useState<OutgoingBubblePlaybackRate>(1);
  const [copied, setCopied] = useState(false);
  const [copyError, setCopyError] = useState(false);
  const [distances, setDistances] = useState({
    width: 400,
    position: 240,
    height: 100,
  });
  const preview = useRef<HTMLDivElement>(null);
  const sequence = useRef(0);
  const lastText = useRef(presets.Multiline);
  const source = useRef<DOMRect | undefined>(undefined);
  const actions = useMemo<ConversationViewActions>(
    () => ({
      discard() {},
      refresh() {},
      removeAttachment() {},
      retry() {},
      retryAttachment() {},
      setDraft(draft) {
        setState((current) => ({ ...current, draft }));
      },
      send(text) {
        source.current = preview.current
          ?.querySelector(".comma-chat-composer")
          ?.getBoundingClientRect();
        lastText.current = text;
        const id = `preview-${++sequence.current}`;
        setState((current) => ({
          ...current,
          draft: "",
          messages: [context, demoMessage(id, "user", text)],
        }));
      },
    }),
    []
  );
  useLayoutEffect(() => {
    if (!source.current || state.messages.length < 2) return;
    const frame = requestAnimationFrame(() => {
      const target = preview.current
        ?.querySelector(".comma-chat-user-bubble-slot")
        ?.getBoundingClientRect();
      if (!target || !source.current) return;
      setDistances({
        width: target.width - source.current.width,
        height: target.height - source.current.height,
        position: Math.hypot(
          target.right - source.current.right,
          target.bottom - source.current.bottom
        ),
      });
    });
    return () => cancelAnimationFrame(frame);
  }, [state.messages]);
  useEffect(() => {
    if (!replay) return;
    let frame = requestAnimationFrame(() => {
      frame = requestAnimationFrame(() => {
        const button = Array.from(
          preview.current?.querySelectorAll<HTMLButtonElement>(
            ".comma-chat-composer button"
          ) ?? []
        ).find((element) => element.getAttribute("aria-label")?.startsWith("Send"));
        button?.click();
      });
    });
    return () => cancelAnimationFrame(frame);
  }, [replay]);
  const timeline = useMemo(
    () => createOutgoingBubbleTimeline(config, distances),
    [config, distances]
  );
  const replaySend = (rate: OutgoingBubblePlaybackRate = 1) => {
    setPlaybackRate(rate);
    setState((current) => ({
      ...initialState(),
      draft: current.draft || lastText.current,
    }));
    setReplay((current) => current + 1);
  };
  const reset = () => {
    setConfig(normalizeMessageSendMotion(motionMessageSend));
    setCopied(false);
  };

  return (
    <div
      className="grid h-screen min-h-0 gap-5 bg-window p-5 text-primary"
      style={{ gridTemplateColumns: "minmax(0, 1fr) 340px" }}
      data-testid="message-send-playground"
    >
      <section className="flex min-h-0 min-w-0 flex-col gap-4">
        <header className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-semibold">Message send motion</h1>
            <p className="text-sm text-secondary">
              Independent curves · shared bubble/text scale · local preview
            </p>
          </div>
          <Button onClick={() => replaySend(1)}>Replay send</Button>
        </header>
        <div className="flex flex-wrap items-center gap-2">
          {([0.25, 0.5, 0.75] as const).map((rate) => (
            <Button
              key={rate}
              hierarchy="secondary-gray"
              size="sm"
              onClick={() => replaySend(rate)}
            >
              Replay {rate}×
            </Button>
          ))}
          {Object.entries(presets).map(([name, text]) => (
            <Button
              key={name}
              hierarchy="secondary-gray"
              size="sm"
              onClick={() => setState((current) => ({ ...current, draft: text }))}
            >
              {name}
            </Button>
          ))}
          <Button
            hierarchy="secondary-gray"
            size="sm"
            onClick={() => {
              setVariant((current) => (current === "route" ? "side-chat" : "route"));
              setState(initialState());
            }}
          >
            {variant === "route" ? "Preview side chat" : "Preview main chat"}
          </Button>
        </div>
        <div
          ref={preview}
          className={`relative flex min-h-0 flex-1 flex-col rounded-2xl border border-secondary bg-primary ${variant === "side-chat" ? "comma-side-chat-host" : ""}`}
          style={{
            position: "relative",
            flex: "1 1 0%",
            bottom: "auto",
            left: "auto",
            width: variant === "side-chat" ? "min(100%, 440px)" : "100%",
            alignSelf: "center",
          }}
        >
          <ConversationView
            key={variant}
            draftSource={draftSource}
            state={state}
            actions={actions}
            variant={variant}
            outgoingMotion={config}
            outgoingPlaybackRate={playbackRate}
          />
        </div>
        <div className="flex flex-wrap items-center justify-between gap-2 text-sm text-secondary">
          <span data-testid="motion-total-duration">
            Replay: {Math.round(timeline.durationMs / playbackRate)} ms ({playbackRate}
            ×)
          </span>
          <span>
            Each curve includes its start delay. Changes apply on the next send.
          </span>
        </div>
      </section>
      <ScrollArea
        className="min-h-0 rounded-2xl border border-secondary bg-primary"
        edgeEffect="none"
      >
        <div className="flex flex-col gap-4 p-4">
          <div className="flex items-center justify-between gap-2">
            <h2 className="font-semibold">Motion controls</h2>
            <Button hierarchy="secondary-gray" size="sm" onClick={reset}>
              Reset
            </Button>
          </div>
          {messageSendChannels.map((channel) => {
            const max = Math.max(
              1.1,
              ...timeline.frames.map((frame) => frame[channel] + 0.08)
            );
            const x = (time: number) => 20 + (time / timeline.durationMs) * 270;
            const y = (value: number) => 100 - (value / max) * 88;
            const path = timeline.frames
              .map(
                (frame, i) =>
                  `${i === 0 ? "M" : "L"}${x(frame.timeMs).toFixed(2)},${y(frame[channel]).toFixed(2)}`
              )
              .join(" ");
            return (
              <section
                key={channel}
                className="rounded-xl border border-secondary p-3"
                aria-label={`${labels[channel]} motion`}
              >
                <div className="flex items-center justify-between text-sm">
                  <h3 className="font-semibold" style={{ color: colors[channel] }}>
                    {labels[channel]}
                  </h3>
                  <span className="text-tertiary">
                    {config[channel].delayMs} →{" "}
                    {Math.round(timeline.channels[channel].endMs)} ms
                  </span>
                </div>
                <svg
                  viewBox="0 0 310 116"
                  aria-label={`${labels[channel]} motion curve`}
                  className="my-2 w-full"
                >
                  <title>{labels[channel]} motion curve</title>
                  <line
                    x1="20"
                    x2="290"
                    y1={y(1)}
                    y2={y(1)}
                    stroke="currentColor"
                    opacity="0.2"
                    strokeDasharray="3 3"
                  />
                  <line
                    x1="20"
                    x2="290"
                    y1="100"
                    y2="100"
                    stroke="currentColor"
                    opacity="0.15"
                  />
                  <text x="0" y={y(1) + 3} fill="currentColor" fontSize="9">
                    1
                  </text>
                  <text x="0" y="103" fill="currentColor" fontSize="9">
                    0
                  </text>
                  <path
                    d={path}
                    fill="none"
                    stroke={colors[channel]}
                    strokeWidth="2"
                    data-spring-curve={channel}
                  />
                </svg>
                {channel === "width" && (
                  <div className="mb-3 flex gap-2">
                    {(["spring", "bezier"] as const).map((mode) => (
                      <Button
                        key={mode}
                        hierarchy={
                          config.widthCurve.mode === mode ? "primary" : "secondary-gray"
                        }
                        size="sm"
                        aria-pressed={config.widthCurve.mode === mode}
                        onClick={() => {
                          setConfig((current) => ({
                            ...current,
                            widthCurve: { ...current.widthCurve, mode },
                          }));
                          setCopied(false);
                        }}
                      >
                        {mode === "spring" ? "Spring" : "Bézier"}
                      </Button>
                    ))}
                  </div>
                )}
                {channel === "width" && config.widthCurve.mode === "bezier" ? (
                  <MotionControls
                    key="bezier"
                    label="Width"
                    fields={bezierFields}
                    ranges={bezierRanges}
                    config={{
                      durationMs: config.widthCurve.durationMs,
                      x1: config.widthCurve.x1,
                      y1: config.widthCurve.y1,
                      x2: config.widthCurve.x2,
                      y2: config.widthCurve.y2,
                      delayMs: config.width.delayMs,
                    }}
                    onChange={({ delayMs, ...value }) => {
                      setConfig((current) => ({
                        ...current,
                        width: {
                          ...current.width,
                          delayMs: delayMs ?? current.width.delayMs,
                        },
                        widthCurve: { ...current.widthCurve, ...value },
                      }));
                      setCopied(false);
                    }}
                  />
                ) : (
                  <MotionControls
                    key="spring"
                    label={labels[channel]}
                    fields={springFields}
                    ranges={messageSendSpringRanges}
                    config={config[channel]}
                    onChange={(value) => {
                      setConfig((current) => ({
                        ...current,
                        [channel]: { ...current[channel], ...value },
                      }));
                      setCopied(false);
                    }}
                  />
                )}
              </section>
            );
          })}
          <section
            className="rounded-xl border border-secondary p-3"
            aria-label="Surface pulse"
          >
            <h3 className="text-sm font-semibold">Surface pulse</h3>
            <p className="mt-1 text-xs text-secondary">
              Squeeze, release, then settle. Bubble and text scale together with fixed
              line breaks.
            </p>
            <svg
              viewBox="0 0 310 116"
              aria-label="Surface compression curve"
              className="my-2 w-full"
            >
              <title>Surface compression curve</title>
              <line
                x1="20"
                x2="290"
                y1="50"
                y2="50"
                stroke="currentColor"
                opacity="0.2"
                strokeDasharray="3 3"
              />
              <text x="0" y="45" fill="currentColor" fontSize="9">
                100%
              </text>
              <path
                fill="none"
                stroke="#db2777"
                strokeWidth="2"
                data-spring-curve="surfacePulse"
                d={timeline.frames
                  .map(
                    (frame, i) =>
                      `${i ? "L" : "M"}${20 + frame.offset * 270},${50 - (frame.surfaceScale - 1) * 900}`
                  )
                  .join(" ")}
              />
            </svg>
            <MotionControls
              label="Surface"
              config={config.surfacePulse}
              fields={pulseFields}
              ranges={messageSendPulseRanges}
              onChange={(value) => {
                setConfig((current) => ({
                  ...current,
                  surfacePulse: { ...current.surfacePulse, ...value },
                }));
                setCopied(false);
              }}
            />
          </section>
          <p className="text-xs text-secondary">
            Text uses the final bubble width from the first frame. Overflow is clipped;
            bubble and text move and scale together without rewrapping or fading.
          </p>
          <p className="text-xs text-secondary">
            Response sets the pace. Damping below 1 adds rebound. The pixel limit keeps
            overshoot small for large movements.
          </p>
          <Button
            hierarchy="secondary-gray"
            onClick={() => {
              setCopyError(false);
              void navigator.clipboard
                .writeText(JSON.stringify(config, null, 2))
                .then(() => setCopied(true))
                .catch(() => setCopyError(true));
            }}
          >
            {copied ? "Copied configuration" : "Copy configuration"}
          </Button>
          {copyError && (
            <output className="text-xs text-secondary">
              Clipboard access failed. Copy the configuration JSON below.
            </output>
          )}
          <details className="text-xs text-secondary">
            <summary>Configuration JSON</summary>
            <pre
              className="mt-2 whitespace-pre-wrap break-all"
              data-testid="motion-config"
            >
              {JSON.stringify(config, null, 2)}
            </pre>
          </details>
        </div>
      </ScrollArea>
    </div>
  );
}

export function OutgoingBubbleMotionPlayground() {
  const [router] = useState(() => {
    const root = createRootRoute({ component: Outlet });
    const route = createRoute({
      getParentRoute: () => root,
      path: "/",
      component: Playground,
    });
    return createRouter({
      routeTree: root.addChildren([route]),
      history: createMemoryHistory({ initialEntries: ["/"] }),
    });
  });
  return <RouterProvider router={router} />;
}
