import { useEffect, useRef, useState } from "react";
import { ScrollArea } from "@comma/ui";
import { getNativeBridge, type SideChatDebugSettings } from "@comma/native-bridge";
import { Pane } from "tweakpane";
import {
  useSideChatDebugSettings,
  type BackdropSettingsPatch,
} from "./useSideChatDebugSettings";

type NumericSettingKey = {
  [Key in keyof SideChatDebugSettings]: SideChatDebugSettings[Key] extends number
    ? Key
    : never;
}[keyof SideChatDebugSettings];

const GROUPS: {
  title: string;
  expanded: boolean;
  fields: {
    key: NumericSettingKey;
    label: string;
    min: number;
    max: number;
    step: number;
    scale?: number;
  }[];
}[] = [
  {
    title: "背景 · Background",
    expanded: true,
    fields: [
      {
        key: "tintOpacity",
        label: "暗色叠加 / Tint %",
        min: 0,
        max: 100,
        step: 1,
        scale: 100,
      },
      { key: "blurRadius", label: "模糊 / Blur px", min: 0, max: 90, step: 1 },
      {
        key: "maxMaskAlpha",
        label: "遮罩 / Mask %",
        min: 0,
        max: 100,
        step: 1,
        scale: 100,
      },
      { key: "maskGamma", label: "渐变曲线 / Gamma", min: 0.2, max: 3, step: 0.05 },
    ],
  },
  {
    title: "边缘羽化 · Feather",
    expanded: true,
    fields: [
      { key: "topFeather", label: "上 / Top px", min: 0, max: 220, step: 1 },
      { key: "bottomFeather", label: "下 / Bottom px", min: 0, max: 220, step: 1 },
      { key: "leftFeather", label: "左 / Left px", min: 0, max: 220, step: 1 },
      { key: "rightFeather", label: "右 / Right px", min: 0, max: 220, step: 1 },
    ],
  },
  {
    title: "高级 · Solid region",
    expanded: false,
    fields: [
      {
        key: "solidOutsetTop",
        label: "顶部扩展 / Top px",
        min: -120,
        max: 160,
        step: 1,
      },
      {
        key: "solidOutsetBottom",
        label: "底部扩展 / Bottom px",
        min: -120,
        max: 160,
        step: 1,
      },
      {
        key: "solidOutsetLeft",
        label: "左侧扩展 / Left px",
        min: -120,
        max: 160,
        step: 1,
      },
      {
        key: "solidOutsetRight",
        label: "右侧扩展 / Right px",
        min: -120,
        max: 160,
        step: 1,
      },
    ],
  },
];

export function SideChatBackdropPanel({
  platform,
  os,
}: {
  platform: string | undefined;
  os: string | undefined;
}) {
  if (platform !== "electron" || os !== "macos") {
    return (
      <output className="comma-side-chat-backdrop__unavailable">
        {platform
          ? "此面板需要 macOS 上的 Comma Dev 桌面应用，才能调整原生 Side Chat 背景。"
          : "读取原生连接…"}
      </output>
    );
  }
  return <LiveBackdropPanel />;
}

function LiveBackdropPanel() {
  const { settings, busy, error, update, reset } = useSideChatDebugSettings();
  const [copyStatus, setCopyStatus] = useState("");

  const copy = async () => {
    if (!settings) return;
    const { revision: _revision, ...values } = settings;
    try {
      await getNativeBridge().clipboard.writeText({
        text: JSON.stringify(values, null, 2),
      });
      setCopyStatus("参数已复制");
    } catch {
      setCopyStatus("复制失败，请重试");
    }
  };

  return (
    <ScrollArea className="comma-side-chat-backdrop" edgeEffect="none">
      <section
        aria-label="Side Chat background controls"
        className="comma-side-chat-backdrop__content"
      >
        <header>
          <h2>Side Chat 背景</h2>
          <p>
            拖动滑块，背景会立即更新。参数仅保留到应用退出。预览关闭后，可从 Window →
            Open Side Chat 再打开。
          </p>
        </header>
        <div className="comma-side-chat-backdrop__actions">
          <button type="button" onClick={reset} disabled={!settings || busy}>
            恢复默认 / Reset
          </button>
          <button
            type="button"
            onClick={() => void copy()}
            disabled={!settings || busy}
          >
            复制参数 / Copy
          </button>
          <output>{busy ? "应用中…" : settings ? "实时生效" : "读取参数…"}</output>
        </div>
        {error ? <p role="alert">{error}</p> : null}
        {copyStatus ? <output>{copyStatus}</output> : null}
        {settings ? <BackdropControls settings={settings} onChange={update} /> : null}
        <p className="note">
          暗色叠加越低，背景越亮；模糊越大，桌面细节越少。羽化越宽，边缘过渡越柔和。高级选项控制实心区域的边界。
        </p>
      </section>
    </ScrollArea>
  );
}

function BackdropControls({
  settings,
  onChange,
}: {
  settings: SideChatDebugSettings;
  onChange: (patch: BackdropSettingsPatch) => void;
}) {
  const container = useRef<HTMLDivElement>(null);
  const paneRef = useRef<Pane | null>(null);
  const values = useRef<Record<string, number | boolean>>({});
  const initial = useRef(settings);
  const refreshing = useRef(false);

  useEffect(() => {
    if (!container.current) return;
    const pane = new Pane({ container: container.current });
    paneRef.current = pane;
    values.current.showBackdrop = initial.current.showBackdrop;
    const visibility = pane.addBinding(values.current, "showBackdrop", {
      label: "显示背景 / Show",
    });
    visibility.element
      .querySelector("input")
      ?.setAttribute("aria-label", "显示背景 / Show");
    visibility.on("change", ({ value }) => {
      if (!refreshing.current) onChange({ showBackdrop: Boolean(value) });
    });

    for (const group of GROUPS) {
      const folder = pane.addFolder({ title: group.title, expanded: group.expanded });
      for (const field of group.fields) {
        const scale = field.scale ?? 1;
        values.current[field.key] = initial.current[field.key] * scale;
        const binding = folder.addBinding(values.current, field.key, field);
        binding.element.querySelector("input")?.setAttribute("aria-label", field.label);
        const slider = binding.element.querySelector("[tabindex]");
        slider?.setAttribute("role", "slider");
        slider?.setAttribute("aria-label", field.label);
        slider?.setAttribute("aria-valuemin", String(field.min));
        slider?.setAttribute("aria-valuemax", String(field.max));
        slider?.setAttribute("aria-valuenow", String(values.current[field.key]));
        binding.on("change", ({ value }) => {
          if (!refreshing.current) onChange({ [field.key]: Number(value) / scale });
        });
      }
    }
    return () => {
      pane.dispose();
      paneRef.current = null;
    };
    // Bindings mount once; the effect below refreshes their shared object without
    // replacing focused numeric inputs while owner snapshots arrive.
  }, [onChange]);

  useEffect(() => {
    values.current.showBackdrop = settings.showBackdrop;
    for (const group of GROUPS) {
      for (const field of group.fields) {
        values.current[field.key] = settings[field.key] * (field.scale ?? 1);
      }
    }
    // Tweakpane also emits change during programmatic refresh. Owner snapshots
    // and failed-edit rollback must never issue a new mutation.
    refreshing.current = true;
    try {
      paneRef.current?.refresh();
    } finally {
      refreshing.current = false;
    }
    for (const slider of container.current?.querySelectorAll('[role="slider"]') ?? []) {
      const field = GROUPS.flatMap((group) => group.fields).find(
        (candidate) => candidate.label === slider.getAttribute("aria-label")
      );
      if (field)
        slider.setAttribute("aria-valuenow", String(values.current[field.key]));
    }
  }, [settings]);

  return (
    <div
      className="comma-workbench-pane comma-side-chat-backdrop__pane"
      ref={container}
    />
  );
}
