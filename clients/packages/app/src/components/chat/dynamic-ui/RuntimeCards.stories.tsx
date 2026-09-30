import type { Meta, StoryObj } from "@storybook/react-vite";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { messages } from "@comma/i18n";
import * as fixtures from "@comma/chat-contract/dynamic-ui-card-fixtures";
import {
  cardCss,
  cardEngine,
  type CardEngine,
  type CardKind,
  type TimerData,
} from "@comma/chat-contract/dynamic-ui-cards";
import { dynamicUiDocument } from "@comma/chat-contract/dynamic-ui-runtime";
import { Button } from "@comma/ui";
import { cardBrandIcons, cardCopy, cardIconMarkup, cardTokenProbe } from "./cardHost";

/**
 * The `comma.card` runtime templates, rendered by the same engine the sandboxed
 * iframe runs. Storybook's own Comma tokens stand in for the host-resolved ones.
 */
const meta = {
  title: "Chat/Runtime cards",
  parameters: { layout: "fullscreen" },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

// The gallery data is Chinese, so its chrome is too.
const zhCopy = cardCopy(messages, "zh-CN");

const RuntimeCard = ({
  kind,
  data,
  variant,
  seed = "story",
}: {
  kind: CardKind;
  data: unknown;
  variant?: string;
  seed?: string;
}) => {
  const host = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const target = host.current;
    if (!target) return;
    const engine: CardEngine = cardEngine({
      seed,
      locale: "zh-CN",
      copy: zhCopy,
      icons: cardIconMarkup(),
      state: {},
      send: (message) => {
        if (message.type === "brand-icons")
          void cardBrandIcons(message.names).then((logos) =>
            engine.receiveIcons(logos)
          );
      },
    });
    target.replaceChildren(engine.mount(target, { kind, data, variant }, "card"));
    return () => engine.dispose();
  }, [kind, data, variant, seed]);
  return <div ref={host} />;
};

const Variant = ({ name, children }: { name: string; children: ReactNode }) => (
  <section className="flex flex-col gap-md">
    <h2 className="m-0 text-sm font-medium text-secondary">{name}</h2>
    <div className="grid grid-cols-2 gap-xl">
      <div className="bg-main-panel-bg rounded-2xl p-2xl" data-theme="Light mode">
        {children}
      </div>
      <div className="dark bg-main-panel-bg rounded-2xl p-2xl" data-theme="Dark mode">
        {children}
      </div>
    </div>
  </section>
);

const Gallery = ({ children }: { children: ReactNode }) => (
  <div
    className="flex w-[1360px] flex-col gap-4xl bg-window p-3xl"
    data-testid="widget-gallery"
  >
    <style>{cardCss}</style>
    {children}
  </div>
);

const gallery = (
  kind: CardKind,
  variants: Array<[name: string, variant: string, data: unknown]>
): Story => ({
  render: () => (
    <Gallery>
      {variants.map(([name, variant, data]) => (
        <Variant key={name} name={name}>
          <RuntimeCard data={data} kind={kind} variant={variant} />
        </Variant>
      ))}
    </Gallery>
  ),
});

export const Forecast = gallery("forecast", [
  ["天气 A · 今日概览", "today", fixtures.forecastFixture],
  ["天气 B · 一周温度条", "week", fixtures.forecastFixture],
  [
    "天气 C · 紧凑单行（窄栏）",
    "compact",
    { ...fixtures.forecastFixture, days: fixtures.forecastFixture.days?.slice(0, 2) },
  ],
]);

export const Options = gallery("options", [
  ["候选 A · 时刻表", "timetable", fixtures.trainOptionsFixture],
  ["候选 B · 首选 + 备选", "pick", fixtures.hotelOptionsFixture],
  ["候选 C · 筛选 + 紧凑列表", "list", fixtures.trainOptionsFixture],
]);

export const Metric = gallery("metric", [
  ["指标 A · 单指标 + 趋势", "single", fixtures.metricFixture],
  ["指标 B · 指标网格", "grid", fixtures.metricGridFixture],
  ["指标 C · 目标进度", "goal", fixtures.goalFixture],
]);

export const Trend = gallery("trend", [
  ["趋势 A · 面积图 + 区间切换", "area", fixtures.trendFixture],
  ["趋势 B · 柱状图 + 均值线", "bars", fixtures.barTrendFixture],
  ["趋势 C · 自选列表", "watchlist", fixtures.watchlistFixture],
]);

export const Comparison = gallery("comparison", [
  ["对比 A · 并列列", "columns", fixtures.comparisonFixture],
  ["对比 B · 属性表（窄栏变卡片）", "table", fixtures.planComparisonFixture],
  ["对比 C · 对决条", "versus", fixtures.versusFixture],
]);

export const Schedule = gallery("schedule", [
  ["日程 A · 今日日程", "agenda", fixtures.agendaFixture],
  ["日程 B · 行程时间线", "timeline", fixtures.itineraryFixture],
  ["日程 C · 阶段进度", "stages", fixtures.stagesFixture],
]);

export const Checklist = gallery("checklist", [
  ["清单 A · 进度清单", "progress", fixtures.checklistFixture],
  ["清单 B · 分组清单", "grouped", fixtures.groupedChecklistFixture],
]);

export const Composition = gallery("composition", [
  ["构成 A · 堆叠条", "stacked", fixtures.compositionFixture],
  ["构成 B · 环形图", "donut", fixtures.storageFixture],
]);

export const Place = gallery("place", [
  [
    "地点 A · 单个地点",
    "single",
    { ...fixtures.placeFixture, places: fixtures.placeFixture.places.slice(0, 1) },
  ],
  ["地点 B · 附近列表", "nearby", fixtures.placeFixture],
]);

export const Feed = gallery("feed", [
  ["动态 A · 新闻列表", "news", fixtures.newsFixture],
  ["动态 B · 各应用摘要", "digest", fixtures.digestFixture],
]);

/** A countdown that really runs: the deadline is set when the story mounts. */
const LiveTimer = ({ data, seconds }: { data: TimerData; seconds: number }) => {
  const [endsAt] = useState(() => new Date(Date.now() + seconds * 1000).toISOString());
  const [live] = useState(() => ({ ...data, endsAt }));
  return <RuntimeCard data={live} kind="timer" variant="countdown" />;
};

export const Timer: Story = {
  render: () => (
    <Gallery>
      <Variant name="倒计时 A · 专注计时（运行中）">
        <LiveTimer data={fixtures.timerFixture} seconds={1104} />
      </Variant>
      <Variant name="倒计时 A · 休息（已暂停）">
        <RuntimeCard
          data={fixtures.breakTimerFixture}
          kind="timer"
          variant="countdown"
        />
      </Variant>
      <Variant name="倒计时 A · 6 秒后结束">
        <LiveTimer
          data={{ ...fixtures.timerFixture, label: "收尾检查", totalSeconds: 300 }}
          seconds={6}
        />
      </Variant>
      <Variant name="倒计时 B · 倒数日">
        <RuntimeCard
          data={fixtures.eventCountdownFixture}
          kind="timer"
          variant="event"
        />
      </Variant>
    </Gallery>
  ),
};

/** Cards as one conversation might produce them, without a requested layout. */
const conversation: Array<[CardKind, unknown]> = [
  ["forecast", fixtures.forecastFixture],
  ["options", fixtures.trainOptionsFixture],
  ["comparison", fixtures.versusFixture],
  ["comparison", fixtures.comparisonFixture],
  ["schedule", fixtures.agendaFixture],
  ["schedule", fixtures.itineraryFixture],
  ["checklist", fixtures.groupedChecklistFixture],
  ["composition", fixtures.compositionFixture],
  ["composition", fixtures.storageFixture],
  ["trend", fixtures.watchlistFixture],
];

const AutoLayoutGallery = () => {
  const [round, setRound] = useState(1);
  return (
    <Gallery>
      <div className="flex items-center gap-lg">
        <p className="m-0 flex-1 text-sm text-secondary">
          每张卡片用自己的 ID
          在数据适用的布局里挑一个：同一张卡片永远一样，不同卡片各不相同。「换一批」相当于新对话里的一批新卡片。
        </p>
        <Button
          hierarchy="secondary-gray"
          onPress={() => setRound((value) => value + 1)}
          size="xs"
        >
          换一批
        </Button>
      </div>
      <div
        className="grid grid-cols-2 items-start gap-xl rounded-2xl bg-main-panel-bg p-2xl"
        data-theme="Light mode"
      >
        {conversation.map(([kind, data], index) => (
          <RuntimeCard
            key={`${kind}-${index}`}
            data={data}
            kind={kind}
            seed={`round-${round}-card-${index}`}
          />
        ))}
      </div>
    </Gallery>
  );
};

export const AutoLayout: Story = {
  name: "随机布局",
  render: () => <AutoLayoutGallery />,
};

/**
 * A card inside the real sandboxed runtime document. The host side uses the
 * same token probe, copy, icons and logo answers as the chat widget.
 */
const SandboxedCard = ({ kind, data }: { kind: CardKind; data: unknown }) => {
  const host = useRef<HTMLDivElement>(null);
  const frame = useRef<HTMLIFrameElement>(null);
  const [height, setHeight] = useState(160);
  const [scheme, setScheme] = useState<"light" | "dark">("light");
  useEffect(() => {
    const target = host.current;
    if (!target) return;
    const dark =
      target.closest("[data-theme]")?.getAttribute("data-theme") === "Dark mode";
    // A frame whose color scheme differs from its document paints an opaque canvas.
    setScheme(dark ? "dark" : "light");
    const probe = cardTokenProbe(target);
    let channel: MessageChannel | undefined;
    const onReady = (event: MessageEvent) => {
      const view = frame.current?.contentWindow;
      if (
        channel ||
        !view ||
        event.source !== view ||
        event.data?.type !== "comma-ui:ready"
      )
        return;
      const port = (channel = new MessageChannel()).port1;
      port.addEventListener("message", ({ data: message }) => {
        if (message?.type === "height") setHeight(message.value);
        if (message?.type === "brand-icons")
          void cardBrandIcons(message.names).then((icons) =>
            port.postMessage({ type: "brand-icons", icons })
          );
      });
      port.start();
      view.postMessage(
        {
          type: "comma-ui:init",
          payload: {
            version: 1,
            html: '<section id="card"></section>',
            script: `comma.card("card", ${JSON.stringify(kind)}, comma.data);`,
            data,
          },
          state: {},
          icons: cardIconMarkup(),
          theme: {
            scheme: dark ? "dark" : "light",
            font: getComputedStyle(target).fontFamily,
          },
          tokens: probe.read(),
          seed: "story",
          locale: "zh-CN",
          copy: zhCopy,
          cardState: {},
        },
        "*",
        [channel.port2]
      );
    };
    window.addEventListener("message", onReady);
    const hello = () =>
      frame.current?.contentWindow?.postMessage({ type: "comma-ui:hello" }, "*");
    const iframe = frame.current;
    iframe?.addEventListener("load", hello);
    hello();
    return () => {
      window.removeEventListener("message", onReady);
      iframe?.removeEventListener("load", hello);
      channel?.port1.postMessage({ type: "stop" });
      channel?.port1.close();
      probe.remove();
    };
  }, [kind, data]);
  return (
    <div ref={host}>
      <iframe
        ref={frame}
        className="block w-full border-0"
        sandbox="allow-scripts"
        srcDoc={dynamicUiDocument()}
        style={{ height, colorScheme: scheme }}
        title={kind}
      />
    </div>
  );
};

export const Sandboxed: Story = {
  name: "沙箱内渲染",
  render: () => (
    <Gallery>
      {(
        [
          ["天气", "forecast", fixtures.forecastFixture],
          ["对比", "comparison", fixtures.comparisonFixture],
          ["清单", "checklist", fixtures.checklistFixture],
          ["动态", "feed", fixtures.digestFixture],
        ] as const
      ).map(([name, kind, data]) => (
        <Variant key={name} name={name}>
          <SandboxedCard data={data} kind={kind} />
        </Variant>
      ))}
    </Gallery>
  ),
};
