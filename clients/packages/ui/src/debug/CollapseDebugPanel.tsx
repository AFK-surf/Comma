import { Pane } from "tweakpane";
import { useEffect, useRef } from "react";
import {
  applyCollapseMotionToDocument,
  copyTextToClipboard,
  defaultCollapseMotion,
  resetCollapseMotionOnDocument,
  serializeCollapseMotionParams,
  type CollapseContentMotion,
  type CollapseMotionLayer,
  type CollapseMotionParams,
} from "./collapseMotion";
import {
  cubicBezierPluginBundle,
  type CubicBezierBladeApi,
} from "./tweakpane/cubicBezierBladePlugin";

export type CollapseDebugPanelProps = {
  initial?: Partial<CollapseMotionParams>;
  onChange?: (params: CollapseMotionParams) => void;
};

const bindMotionLayer = (
  folder: ReturnType<Pane["addFolder"]>,
  layer: CollapseMotionLayer,
  defaultLayer: CollapseMotionLayer,
  onChange: () => void
) => {
  folder
    .addBinding(layer, "durationMs", {
      label: "duration",
      min: 0,
      max: 1200,
      step: 10,
      unit: "ms",
    })
    .on("change", onChange);

  const easingBlade = folder.addBlade({
    view: "cubic-bezier",
    label: "easing",
    value: layer.bezier,
    defaultValue: defaultLayer.bezier,
  }) as CubicBezierBladeApi;

  easingBlade.on("change", (event) => {
    layer.bezier = event.value;
    onChange();
  });
};

const bindContentMotion = (
  pane: Pane,
  content: CollapseContentMotion,
  defaultContent: CollapseContentMotion,
  onChange: () => void
) => {
  const folder = pane.addFolder({ title: "content", expanded: true });
  bindMotionLayer(folder, content, defaultContent, onChange);

  const hiddenFolder = folder.addFolder({ title: "hidden transform", expanded: true });

  hiddenFolder
    .addBinding(content.hidden, "opacity", {
      label: "opacity",
      min: 0,
      max: 1,
      step: 0.01,
    })
    .on("change", onChange);

  hiddenFolder
    .addBinding(content.hidden, "scale", {
      label: "scale",
      min: 0.5,
      max: 1.2,
      step: 0.01,
    })
    .on("change", onChange);

  hiddenFolder
    .addBinding(content.hidden, "translateX", {
      label: "translateX",
      min: -48,
      max: 48,
      step: 1,
      unit: "px",
    })
    .on("change", onChange);

  hiddenFolder
    .addBinding(content.hidden, "translateY", {
      label: "translateY",
      min: -48,
      max: 48,
      step: 1,
      unit: "px",
    })
    .on("change", onChange);
};

/** Storybook-only debug panel with separate container/content motion controls. */
export const CollapseDebugPanel = ({ initial, onChange }: CollapseDebugPanelProps) => {
  const paneHostRef = useRef<HTMLDivElement>(null);
  const paramsRef = useRef<CollapseMotionParams>({
    container: {
      ...defaultCollapseMotion.container,
      ...initial?.container,
      bezier: {
        ...defaultCollapseMotion.container.bezier,
        ...initial?.container?.bezier,
      },
    },
    content: {
      ...defaultCollapseMotion.content,
      ...initial?.content,
      bezier: {
        ...defaultCollapseMotion.content.bezier,
        ...initial?.content?.bezier,
      },
      hidden: {
        ...defaultCollapseMotion.content.hidden,
        ...initial?.content?.hidden,
      },
    },
  });

  useEffect(() => {
    const host = paneHostRef.current;
    if (!host) return;

    const pane = new Pane({
      title: "Collapse motion",
      expanded: true,
    });
    pane.element.style.width = "280px";
    pane.registerPlugin(cubicBezierPluginBundle);
    host.appendChild(pane.element);

    const sync = () => {
      applyCollapseMotionToDocument(paramsRef.current);
      onChange?.(paramsRef.current);
    };

    bindMotionLayer(
      pane.addFolder({ title: "container", expanded: true }),
      paramsRef.current.container,
      defaultCollapseMotion.container,
      sync
    );
    bindContentMotion(
      pane,
      paramsRef.current.content,
      defaultCollapseMotion.content,
      sync
    );

    let copyFeedbackTimer: ReturnType<typeof setTimeout> | null = null;
    const copyAllButton = pane.addButton({ title: "copy all params" });
    copyAllButton.on("click", () => {
      void copyTextToClipboard(serializeCollapseMotionParams(paramsRef.current)).then(
        () => {
          if (copyFeedbackTimer) clearTimeout(copyFeedbackTimer);
          copyAllButton.title = "copied";
          copyFeedbackTimer = setTimeout(() => {
            copyAllButton.title = "copy all params";
            copyFeedbackTimer = null;
          }, 1200);
        }
      );
    });

    sync();

    return () => {
      if (copyFeedbackTimer) clearTimeout(copyFeedbackTimer);
      pane.dispose();
      host.replaceChildren();
      resetCollapseMotionOnDocument();
    };
  }, [onChange]);

  return <div ref={paneHostRef} className="fixed top-4 right-4 z-[9999] w-[280px]" />;
};
