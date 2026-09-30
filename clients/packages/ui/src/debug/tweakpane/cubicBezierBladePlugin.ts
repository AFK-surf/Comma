import {
  BladeApi,
  BladeController,
  ClassName,
  createPlugin,
  createValue,
  Emitter,
  parseRecord,
  TpChangeEvent,
  ViewProps,
  type ApiChangeEvents,
  type BaseBladeParams,
  type BladePlugin,
  type EventListenable,
  type Value,
  type ValueEvents,
  type View,
} from "@tweakpane/core";
import type { CubicBezier } from "../collapseMotion";
import {
  clampCubicBezierToEditor,
  cubicBezierEditorBounds,
  formatCubicBezierCss,
} from "../collapseMotion";

const SIZE = 160;
const PAD = 12;
const PLOT = SIZE - PAD * 2;
const { xMin, xMax, yMin, yMax } = cubicBezierEditorBounds;

const cn = ClassName("cbez");

const bezierEquals = (left: CubicBezier, right: CubicBezier) =>
  left.x1 === right.x1 &&
  left.y1 === right.y1 &&
  left.x2 === right.x2 &&
  left.y2 === right.y2;

const clamp = (value: number, min: number, max: number) =>
  Math.min(max, Math.max(min, value));

const toSvg = (x: number, y: number) => ({
  sx: PAD + ((clamp(x, xMin, xMax) - xMin) / (xMax - xMin)) * PLOT,
  sy: PAD + (1 - (clamp(y, yMin, yMax) - yMin) / (yMax - yMin)) * PLOT,
});

const fromSvg = (sx: number, sy: number) => ({
  x: clamp(xMin + ((sx - PAD) / PLOT) * (xMax - xMin), xMin, xMax),
  y: clamp(yMin + (1 - (sy - PAD) / PLOT) * (yMax - yMin), yMin, yMax),
});

export interface CubicBezierBladeParams extends BaseBladeParams {
  view: "cubic-bezier";
  value: CubicBezier;
  label?: string;
  defaultValue?: CubicBezier;
}

type CubicBezierViewConfig = {
  doc: Document;
  viewProps: ViewProps;
  label: string | undefined;
  onDrag: (handle: "p1" | "p2", clientX: number, clientY: number) => void;
  onDragEnd: () => void;
  onReset: () => void;
};

class CubicBezierView implements View {
  public readonly element: HTMLElement;
  private readonly svg: SVGSVGElement;
  private readonly guideStart: SVGLineElement;
  private readonly guideEnd: SVGLineElement;
  private readonly curve: SVGPathElement;
  private readonly handleP1: SVGCircleElement;
  private readonly handleP2: SVGCircleElement;
  private readonly anchorStart: SVGCircleElement;
  private readonly anchorEnd: SVGCircleElement;
  private readonly readoutText: HTMLElement;
  private readonly copyButton: HTMLButtonElement;
  private copyFeedbackTimer: ReturnType<typeof setTimeout> | null = null;
  private dragHandle: "p1" | "p2" | null = null;

  constructor(config: CubicBezierViewConfig) {
    const { doc, viewProps, label, onDrag, onDragEnd, onReset } = config;

    this.element = doc.createElement("div");
    this.element.classList.add(cn());
    viewProps.bindClassModifiers(this.element);

    if (label) {
      const labelRow = doc.createElement("div");
      labelRow.classList.add(cn("lr"));

      const labelElement = doc.createElement("div");
      labelElement.classList.add(cn("l"));
      labelElement.textContent = label;
      labelRow.appendChild(labelElement);

      const resetButton = doc.createElement("button");
      resetButton.type = "button";
      resetButton.classList.add(cn("r"));
      resetButton.textContent = "reset";
      resetButton.addEventListener("click", onReset);
      labelRow.appendChild(resetButton);

      this.element.appendChild(labelRow);
    }

    const content = doc.createElement("div");
    content.classList.add(cn("c"));
    this.element.appendChild(content);

    this.svg = doc.createElementNS("http://www.w3.org/2000/svg", "svg");
    this.svg.classList.add(cn("g"));
    this.svg.setAttribute("viewBox", `0 0 ${SIZE} ${SIZE}`);
    this.svg.setAttribute("aria-label", "Cubic bezier easing editor");
    content.appendChild(this.svg);

    this.guideStart = createSvgLine(doc);
    this.guideEnd = createSvgLine(doc, true);
    this.curve = doc.createElementNS("http://www.w3.org/2000/svg", "path");
    this.curve.classList.add(cn("curve"));
    this.handleP1 = createHandle(doc, cn("h"));
    this.handleP2 = createHandle(doc, cn("h"));

    this.anchorStart = createAnchor(doc);
    this.anchorEnd = createAnchor(doc);
    this.svg.append(
      this.guideStart,
      this.guideEnd,
      this.curve,
      this.anchorStart,
      this.anchorEnd,
      this.handleP1,
      this.handleP2
    );

    const bindHandle = (handle: "p1" | "p2", circle: SVGCircleElement) => {
      circle.addEventListener("pointerdown", (event) => {
        this.dragHandle = handle;
        circle.setPointerCapture(event.pointerId);
        onDrag(handle, event.clientX, event.clientY);
        event.preventDefault();
      });
      circle.addEventListener("pointermove", (event) => {
        if (this.dragHandle !== handle) return;
        onDrag(handle, event.clientX, event.clientY);
      });
      circle.addEventListener("pointerup", (event) => {
        if (this.dragHandle !== handle) return;
        this.dragHandle = null;
        circle.releasePointerCapture(event.pointerId);
        onDragEnd();
      });
      circle.addEventListener("pointercancel", (event) => {
        if (this.dragHandle !== handle) return;
        this.dragHandle = null;
        circle.releasePointerCapture(event.pointerId);
        onDragEnd();
      });
    };

    bindHandle("p1", this.handleP1);
    bindHandle("p2", this.handleP2);

    const readoutRow = doc.createElement("div");
    readoutRow.classList.add(cn("mr"));
    content.appendChild(readoutRow);

    this.readoutText = doc.createElement("code");
    this.readoutText.classList.add(cn("m"));
    readoutRow.appendChild(this.readoutText);

    this.copyButton = doc.createElement("button");
    this.copyButton.type = "button";
    this.copyButton.classList.add(cn("cp"));
    this.copyButton.textContent = "copy";
    this.copyButton.setAttribute("aria-label", "Copy cubic-bezier value");
    this.copyButton.addEventListener("click", () => {
      void this.copyCssValue();
    });
    readoutRow.appendChild(this.copyButton);
  }

  private async copyCssValue() {
    const text = this.readoutText.textContent ?? "";
    if (!text) return;

    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const textarea = this.readoutText.ownerDocument.createElement("textarea");
      textarea.value = text;
      textarea.setAttribute("readonly", "true");
      textarea.style.position = "fixed";
      textarea.style.left = "-9999px";
      this.readoutText.ownerDocument.body.appendChild(textarea);
      textarea.select();
      this.readoutText.ownerDocument.execCommand("copy");
      textarea.remove();
    }

    if (this.copyFeedbackTimer) {
      clearTimeout(this.copyFeedbackTimer);
    }
    this.copyButton.textContent = "copied";
    this.copyFeedbackTimer = setTimeout(() => {
      this.copyButton.textContent = "copy";
      this.copyFeedbackTimer = null;
    }, 1200);
  }

  render(value: CubicBezier) {
    const normalized = clampCubicBezierToEditor(value);
    const p0 = toSvg(0, 0);
    const p1 = toSvg(normalized.x1, normalized.y1);
    const p2 = toSvg(normalized.x2, normalized.y2);
    const p3 = toSvg(1, 1);

    setLine(this.guideStart, p0.sx, p0.sy, p1.sx, p1.sy);
    setLine(this.guideEnd, p3.sx, p3.sy, p2.sx, p2.sy);
    this.curve.setAttribute(
      "d",
      `M ${p0.sx} ${p0.sy} C ${p1.sx} ${p1.sy}, ${p2.sx} ${p2.sy}, ${p3.sx} ${p3.sy}`
    );
    this.handleP1.setAttribute("cx", String(p1.sx));
    this.handleP1.setAttribute("cy", String(p1.sy));
    this.handleP2.setAttribute("cx", String(p2.sx));
    this.handleP2.setAttribute("cy", String(p2.sy));
    this.anchorStart.setAttribute("cx", String(p0.sx));
    this.anchorStart.setAttribute("cy", String(p0.sy));
    this.anchorEnd.setAttribute("cx", String(p3.sx));
    this.anchorEnd.setAttribute("cy", String(p3.sy));
    this.readoutText.textContent = formatCubicBezierCss(normalized);
  }

  pointerToValue(clientX: number, clientY: number) {
    const rect = this.svg.getBoundingClientRect();
    return fromSvg(
      ((clientX - rect.left) / rect.width) * SIZE,
      ((clientY - rect.top) / rect.height) * SIZE
    );
  }
}

class CubicBezierBladeController extends BladeController<CubicBezierView> {
  public readonly value: Value<CubicBezier>;

  constructor(
    doc: Document,
    config: {
      blade: CubicBezierBladeController["blade"];
      label: string | undefined;
      value: CubicBezier;
      defaultValue: CubicBezier;
      viewProps: ViewProps;
    }
  ) {
    const value = createValue(clampCubicBezierToEditor(config.value), {
      equals: bezierEquals,
    });
    let view!: CubicBezierView;

    view = new CubicBezierView({
      doc,
      label: config.label,
      onDrag: (handle, clientX, clientY) => {
        const current = value.rawValue;
        const point = view.pointerToValue(clientX, clientY);
        value.setRawValue(
          clampCubicBezierToEditor(
            handle === "p1"
              ? { ...current, x1: point.x, y1: point.y }
              : { ...current, x2: point.x, y2: point.y }
          ),
          { forceEmit: false, last: false }
        );
      },
      onDragEnd: () => {
        value.setRawValue(clampCubicBezierToEditor(value.rawValue), {
          forceEmit: true,
          last: true,
        });
      },
      onReset: () => {
        value.setRawValue(clampCubicBezierToEditor(config.defaultValue), {
          forceEmit: true,
          last: true,
        });
      },
      viewProps: config.viewProps,
    });

    super({
      blade: config.blade,
      view,
      viewProps: config.viewProps,
    });

    this.value = value;
    this.value.emitter.on("change", () => {
      view.render(this.value.rawValue);
    });
    view.render(this.value.rawValue);
  }
}

export class CubicBezierBladeApi
  extends BladeApi<CubicBezierBladeController>
  implements EventListenable<ApiChangeEvents<CubicBezier>>
{
  private readonly emitter = new Emitter<ApiChangeEvents<CubicBezier>>();

  constructor(controller: CubicBezierBladeController) {
    super(controller);
    this.handleValueChange = this.handleValueChange.bind(this);
    controller.value.emitter.on("change", this.handleValueChange);
  }

  get label(): string | undefined {
    return (
      this.controller.view.element.querySelector(`.${cn("l")}`)?.textContent ??
      undefined
    );
  }

  get value(): CubicBezier {
    return this.controller.value.rawValue;
  }

  set value(value: CubicBezier) {
    this.controller.value.setRawValue(value);
  }

  on<EventName extends keyof ApiChangeEvents<CubicBezier>>(
    eventName: EventName,
    handler: (ev: ApiChangeEvents<CubicBezier>[EventName]) => void
  ): this {
    const bound = handler.bind(this);
    this.emitter.on(
      eventName,
      (ev) => {
        bound(ev);
      },
      { key: handler }
    );
    return this;
  }

  off<EventName extends keyof ApiChangeEvents<CubicBezier>>(
    eventName: EventName,
    handler: (ev: ApiChangeEvents<CubicBezier>[EventName]) => void
  ): this {
    this.emitter.off(eventName, handler);
    return this;
  }

  private handleValueChange(ev: ValueEvents<CubicBezier>["change"]) {
    this.emitter.emit("change", new TpChangeEvent(this, ev.rawValue, ev.options.last));
  }
}

export const CubicBezierBladePlugin: BladePlugin<CubicBezierBladeParams> = createPlugin(
  {
    id: "cubic-bezier",
    type: "blade",
    accept(params) {
      const result = parseRecord<CubicBezierBladeParams>(params, (p) => ({
        view: p.required.constant("cubic-bezier"),
        value: p.required.object({
          x1: p.required.number,
          y1: p.required.number,
          x2: p.required.number,
          y2: p.required.number,
        }),
        label: p.optional.string,
        defaultValue: p.optional.object({
          x1: p.required.number,
          y1: p.required.number,
          x2: p.required.number,
          y2: p.required.number,
        }),
      }));
      return result ? { params: result } : null;
    },
    controller(args) {
      return new CubicBezierBladeController(args.document, {
        blade: args.blade,
        label: args.params.label,
        value: args.params.value,
        defaultValue: args.params.defaultValue ?? args.params.value,
        viewProps: args.viewProps,
      });
    },
    api(args) {
      if (args.controller instanceof CubicBezierBladeController) {
        return new CubicBezierBladeApi(args.controller);
      }
      return null;
    },
  }
);

export const cubicBezierPluginBundle = {
  id: "cubic-bezier",
  plugins: [CubicBezierBladePlugin],
  css: `
.${cn()} {
  display: flex;
  flex-direction: column;
  gap: calc(var(--cnt-usz, 20px) * 0.25);
}
.${cn("lr")} {
  align-items: center;
  display: flex;
  justify-content: space-between;
  padding: 0 calc(var(--cnt-usz, 20px) * 0.4);
}
.${cn("l")} {
  color: var(--lbl-fg, rgba(187, 187, 187, 0.7));
  flex: none;
  font-size: calc(var(--cnt-usz, 20px) * 0.55);
  font-weight: 500;
  line-height: 1.2;
}
.${cn("r")}, .${cn("cp")} {
  background: transparent;
  border: none;
  color: var(--btn-bg, #007bff);
  cursor: pointer;
  font-size: calc(var(--cnt-usz, 20px) * 0.45);
  line-height: 1.2;
  padding: 0;
  text-transform: lowercase;
}
.${cn("r")}:hover, .${cn("cp")}:hover {
  text-decoration: underline;
}
.${cn("mr")} {
  align-items: stretch;
  display: flex;
  gap: calc(var(--cnt-usz, 20px) * 0.2);
}
.${cn("c")} {
  display: flex;
  flex-direction: column;
  gap: calc(var(--cnt-usz, 20px) * 0.25);
  padding: 0 calc(var(--cnt-usz, 20px) * 0.4) calc(var(--cnt-usz, 20px) * 0.2);
}
.${cn("g")} {
  background: var(--in-bg, rgba(255, 255, 255, 0.05));
  border: 1px solid var(--in-bg, rgba(255, 255, 255, 0.08));
  border-radius: calc(var(--cnt-usz, 20px) * 0.2);
  display: block;
  overflow: hidden;
  touch-action: none;
  user-select: none;
  width: 100%;
}
.${cn("g")} line {
  stroke: var(--mo-fg, rgba(187, 187, 187, 0.35));
  stroke-dasharray: 4 3;
  stroke-width: 1;
}
.${cn("curve")} {
  fill: none;
  stroke: var(--btn-bg, #007bff);
  stroke-width: 2;
}
.${cn("g")} circle.${cn("a")} {
  fill: var(--mo-fg, rgba(187, 187, 187, 0.35));
}
.${cn("h")} {
  cursor: grab;
  fill: var(--cnt-bg, #1e1e1e);
  stroke: var(--btn-bg, #007bff);
  stroke-width: 2;
}
.${cn("h")}:active {
  cursor: grabbing;
}
.${cn("m")} {
  background: var(--in-bg, rgba(255, 255, 255, 0.05));
  border-radius: calc(var(--cnt-usz, 20px) * 0.15);
  color: var(--lbl-fg, rgba(187, 187, 187, 0.7));
  flex: 1;
  font-family: Menlo, Monaco, Consolas, monospace;
  font-size: calc(var(--cnt-usz, 20px) * 0.45);
  line-height: 1.4;
  min-width: 0;
  padding: calc(var(--cnt-usz, 20px) * 0.15) calc(var(--cnt-usz, 20px) * 0.25);
  word-break: break-all;
}
.${cn("cp")} {
  align-self: stretch;
  border-radius: calc(var(--cnt-usz, 20px) * 0.15);
  flex: none;
  padding: calc(var(--cnt-usz, 20px) * 0.15) calc(var(--cnt-usz, 20px) * 0.25);
  white-space: nowrap;
}
`,
};

const createSvgLine = (doc: Document, dashed = false) => {
  const line = doc.createElementNS("http://www.w3.org/2000/svg", "line");
  if (dashed) {
    line.setAttribute("stroke-dasharray", "4 3");
  }
  return line;
};

const createAnchor = (doc: Document) => {
  const circle = doc.createElementNS("http://www.w3.org/2000/svg", "circle");
  circle.classList.add(cn("a"));
  circle.setAttribute("r", "3");
  return circle;
};

const createHandle = (doc: Document, className: string) => {
  const circle = doc.createElementNS("http://www.w3.org/2000/svg", "circle");
  circle.classList.add(className);
  circle.setAttribute("r", "6");
  return circle;
};

const setLine = (
  line: SVGLineElement,
  x1: number,
  y1: number,
  x2: number,
  y2: number
) => {
  line.setAttribute("x1", String(x1));
  line.setAttribute("y1", String(y1));
  line.setAttribute("x2", String(x2));
  line.setAttribute("y2", String(y2));
};
