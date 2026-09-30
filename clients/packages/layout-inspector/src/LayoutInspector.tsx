import { IconSettingsGear2 as SettingsIcon } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconSettingsGear2";
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import { createPortal } from "react-dom";
import {
  resolveAuthoredLayoutValues,
  type AuthoredLayoutValue,
  type AuthoredLayoutValues,
  type InspectedLayoutProperty,
} from "./authored-values";
import {
  buildElementSourceReport,
  buildPendingChangesPrompt,
  describeElementTarget,
  variableOptionsForProperty,
  type PendingLayoutChange,
  type ResolveLayoutVariables,
} from "./live-edits";
import { resolveOverlayLabelCollisions } from "./label-collisions";
import {
  measureElement,
  type LayoutGeometryLimit,
  type LayoutMeasurement,
} from "./measure-layout";
import type { BoxEdges, InspectorRect, OverlaySegment } from "./geometry";
import {
  clampInspectorPanelPosition,
  positionInspectorPanel,
  type InspectorPanelPosition,
  type InspectorPanelSize,
} from "./panel-position";
import { formatOriginalOptionLabel } from "./property-options";
import { formatLayoutSourceLocation } from "./source-location";
import "./layout-inspector.css";

export type LayoutInspectorProps = {
  defaultActive?: boolean;
  defaultOverlayVisibility?: Partial<LayoutOverlayVisibility>;
  defaultValueDisplayMode?: LayoutValueDisplayMode;
  resolveVariables?: ResolveLayoutVariables;
};

export type LayoutOverlayVisibility = {
  border: boolean;
  gap: boolean;
  padding: boolean;
};

export type LayoutValueDisplayMode = "pixels" | "variables";

const inspectorUiAttribute = "data-comma-layout-inspector-ui";
const maximumSurroundingResizeTargets = 128;
const edgeNames = ["top", "right", "bottom", "left"] as const;
const valueDisplayModes: Array<{
  label: string;
  value: LayoutValueDisplayMode;
}> = [
  { label: "Pixels", value: "pixels" },
  { label: "Variables", value: "variables" },
];
const defaultOverlayVisibilityValue: LayoutOverlayVisibility = {
  border: false,
  gap: true,
  padding: true,
};
const resizeDirections: Record<string, readonly [number, number]> = {
  ArrowDown: [0, 1],
  ArrowLeft: [-1, 0],
  ArrowRight: [1, 0],
  ArrowUp: [0, -1],
};

type RuntimeOverride = {
  element: HTMLElement | SVGElement;
  previewPriority: string;
  previewValue: string;
  priority: string;
  property: InspectedLayoutProperty;
  value: string;
};

type InspectorPanelDrag = {
  moved: boolean;
  panel: InspectorPanelSize;
  pointerId: number;
  startLeft: number;
  startPointerX: number;
  startPointerY: number;
  startTop: number;
};

type InspectorPanelResize = {
  minimum: InspectorPanelSize;
  pointerId: number;
  startHeight: number;
  startPointerX: number;
  startPointerY: number;
  startWidth: number;
};

type CollapsiblePropertyGroupKind = "border" | "gap" | "margin" | "padding";

type PropertyNavigationTarget = {
  group: CollapsiblePropertyGroupKind;
  property?: InspectedLayoutProperty;
};

const defaultExpandedPropertyGroups: Record<CollapsiblePropertyGroupKind, boolean> = {
  border: true,
  gap: true,
  margin: true,
  padding: true,
};

export function LayoutInspector({
  defaultActive = false,
  defaultOverlayVisibility,
  defaultValueDisplayMode = "pixels",
  resolveVariables,
}: LayoutInspectorProps) {
  const [active, setActive] = useState(defaultActive);
  const [overlayVisibility, setOverlayVisibility] = useState<LayoutOverlayVisibility>(
    () => ({
      ...defaultOverlayVisibilityValue,
      ...defaultOverlayVisibility,
    })
  );
  const [valueDisplayMode, setValueDisplayMode] = useState(defaultValueDisplayMode);
  const [measurement, setMeasurement] = useState<LayoutMeasurement | null>(null);
  const [pinned, setPinned] = useState(false);
  const [authoredValues, setAuthoredValues] = useState<AuthoredLayoutValues | null>(
    null
  );
  const [selectedElementKey, setSelectedElementKey] = useState<string | null>(null);
  const [pendingChanges, setPendingChanges] = useState<PendingLayoutChange[]>([]);
  const [copyStatus, setCopyStatus] = useState<"idle" | "copied" | "failed">("idle");
  const targetRef = useRef<Element | null>(null);
  const elementKeysRef = useRef(new WeakMap<Element, string>());
  const elementSequenceRef = useRef(0);
  const runtimeOverridesRef = useRef(new Map<string, RuntimeOverride>());
  const suspendScheduledMeasurementRef = useRef<() => void>(() => undefined);

  const getElementKey = useCallback((element: Element) => {
    const existing = elementKeysRef.current.get(element);
    if (existing) return existing;

    elementSequenceRef.current += 1;
    const key = `element-${elementSequenceRef.current}`;
    elementKeysRef.current.set(element, key);
    return key;
  }, []);

  const releaseInvalidTarget = useCallback((element: Element) => {
    const releasedIds = new Set<string>();
    for (const [id, override] of runtimeOverridesRef.current) {
      if (override.element !== element) continue;
      restoreInlineOverride(override);
      runtimeOverridesRef.current.delete(id);
      releasedIds.add(id);
    }

    if (releasedIds.size > 0) {
      setPendingChanges((current) =>
        current.filter((change) => !releasedIds.has(change.id))
      );
      setCopyStatus("idle");
    }

    if (targetRef.current !== element) return;
    targetRef.current = null;
    setMeasurement(null);
    setPinned(false);
    setAuthoredValues(null);
    setSelectedElementKey(null);
  }, []);

  const refreshElement = useCallback(
    (element: Element) => {
      if (!element.isConnected) {
        releaseInvalidTarget(element);
        return false;
      }

      const nextMeasurement = measureElement(element);
      if (!nextMeasurement) {
        releaseInvalidTarget(element);
        return false;
      }

      setMeasurement(nextMeasurement);
      setAuthoredValues(resolveAuthoredLayoutValues(element));
      return true;
    },
    [releaseInvalidTarget]
  );

  const resetChange = useCallback(
    (id: string) => {
      const override = runtimeOverridesRef.current.get(id);
      if (!override) return;

      restoreInlineOverride(override);
      runtimeOverridesRef.current.delete(id);
      setPendingChanges((current) => current.filter((change) => change.id !== id));
      setCopyStatus("idle");
      if (targetRef.current === override.element) refreshElement(override.element);
    },
    [refreshElement]
  );

  const clearChanges = useCallback(() => {
    const currentTarget = targetRef.current;
    for (const override of runtimeOverridesRef.current.values()) {
      restoreInlineOverride(override);
    }
    runtimeOverridesRef.current.clear();
    setPendingChanges([]);
    setCopyStatus("idle");
    if (currentTarget) refreshElement(currentTarget);
  }, [refreshElement]);

  const changeValueDisplayMode = useCallback(
    (mode: LayoutValueDisplayMode) => {
      setValueDisplayMode(mode);
      const element = targetRef.current;
      if (!element) return;

      if (mode === "pixels" && !pinned) {
        setAuthoredValues(null);
        return;
      }
      if (mode !== "pixels") {
        setAuthoredValues(resolveAuthoredLayoutValues(element));
      }
    },
    [pinned]
  );

  const applyVariable = useCallback(
    (property: InspectedLayoutProperty, variable: string | null) => {
      const element = targetRef.current;
      if (!element || !authoredValues || !measurement) return;
      if (!(element instanceof HTMLElement || element instanceof SVGElement)) return;
      if (!element.isConnected || !measureElement(element)) {
        releaseInvalidTarget(element);
        return;
      }

      const elementKey = getElementKey(element);
      const id = `${elementKey}:${property}`;
      if (!variable) {
        resetChange(id);
        return;
      }

      const pendingChange = pendingChanges.find((change) => change.id === id);
      const baselineExpression =
        pendingChange?.beforeExpression ?? authoredValues[property].expression;
      if (
        baselineExpression &&
        compactCssExpression(baselineExpression) === `var(${variable})`
      ) {
        resetChange(id);
        return;
      }

      const existingOverride = runtimeOverridesRef.current.get(id);
      const override =
        existingOverride ??
        ({
          element,
          previewPriority: "",
          previewValue: "",
          priority: element.style.getPropertyPriority(property),
          property,
          value: element.style.getPropertyValue(property),
        } satisfies RuntimeOverride);
      if (existingOverride && !inlineOverrideOwnsCurrentValue(existingOverride)) {
        override.priority = element.style.getPropertyPriority(property);
        override.value = element.style.getPropertyValue(property);
      }

      const originalValue = authoredValues[property];
      const preview = applyInlinePreview(element, property, `var(${variable})`);
      override.previewPriority = preview.priority;
      override.previewValue = preview.value;
      runtimeOverridesRef.current.set(id, override);
      const afterComputed = preview.computed;

      setPendingChanges((current) => {
        const existingChange = current.find((change) => change.id === id);
        if (existingChange) {
          return current.map((change) =>
            change.id === id
              ? {
                  ...change,
                  afterComputed,
                  afterVariable: variable,
                }
              : change
          );
        }

        return [
          ...current,
          {
            afterComputed,
            afterVariable: variable,
            beforeComputed: originalValue.computed,
            beforeConfidence: originalValue.confidence,
            beforeExpression: originalValue.expression ?? originalValue.computed,
            beforeVariables: originalValue.variables,
            elementKey,
            id,
            nodeLabel: measurement.nodeLabel,
            property,
            ...(originalValue.selector
              ? { sourceSelector: originalValue.selector }
              : {}),
            target: describeElementTarget(element),
          },
        ];
      });
      setCopyStatus("idle");
      refreshElement(element);
    },
    [
      authoredValues,
      getElementKey,
      measurement,
      pendingChanges,
      refreshElement,
      releaseInvalidTarget,
      resetChange,
    ]
  );

  const copyPrompt = useCallback(async () => {
    const copied = await copyText(buildPendingChangesPrompt(pendingChanges));
    setCopyStatus(copied ? "copied" : "failed");
  }, [pendingChanges]);

  const changeOverlayVisibility = useCallback(
    (kind: keyof LayoutOverlayVisibility, visible: boolean) => {
      setOverlayVisibility((current) => ({
        ...current,
        [kind]: visible,
      }));
    },
    []
  );

  useEffect(() => {
    const handleShortcut = (event: KeyboardEvent) => {
      if (
        event.code !== "KeyL" ||
        !event.shiftKey ||
        (!event.metaKey && !event.ctrlKey)
      ) {
        return;
      }

      event.preventDefault();
      suspendScheduledMeasurementRef.current();
      setActive((current) => !current);
    };

    window.addEventListener("keydown", handleShortcut, true);
    return () => window.removeEventListener("keydown", handleShortcut, true);
  }, []);

  useEffect(() => {
    if (!active) return;

    let animationFrame = 0;
    let measurementsEnabled = true;
    let scheduledElement: Element | null = null;
    const previousCursor = document.body.style.cursor;
    let mutationObserver: MutationObserver | null = null;
    let resizeObserver: ResizeObserver | null = null;
    const mutationOptions: MutationObserverInit = {
      attributes: true,
      ...(pinned
        ? {
            characterData: true,
          }
        : {
            attributeFilter: ["class", "hidden", "style"],
          }),
      childList: true,
      subtree: true,
    };

    document.body.style.cursor = "crosshair";

    const observeResizeTargets = (element: Element | null) => {
      resizeObserver?.disconnect();
      if (!element) return;
      for (const observedElement of surroundingResizeTargets(
        element,
        pinned,
        maximumSurroundingResizeTargets
      )) {
        resizeObserver?.observe(observedElement);
      }
    };

    const observe = (element: Element | null) => {
      observeResizeTargets(element);
      mutationObserver?.disconnect();
      mutationObserver?.observe(document.documentElement, mutationOptions);
      const root = element?.getRootNode();
      if (root instanceof ShadowRoot) {
        mutationObserver?.observe(root, mutationOptions);
      }
    };

    const selectTarget = (element: Element | null, resolveSource = false) => {
      if (!element) return;
      if (!element.isConnected) {
        releaseInvalidTarget(element);
        observe(null);
        return;
      }

      const nextMeasurement = measureElement(element);
      if (!nextMeasurement) {
        if (targetRef.current === element) releaseInvalidTarget(element);
        observe(null);
        return;
      }

      const targetChanged = targetRef.current !== element;
      if (targetChanged) {
        targetRef.current = element;
        observe(element);
        setSelectedElementKey(getElementKey(element));
      }

      setMeasurement(nextMeasurement);
      if (resolveSource || (targetChanged && valueDisplayMode !== "pixels")) {
        setAuthoredValues(resolveAuthoredLayoutValues(element));
      } else if (targetChanged) {
        setAuthoredValues(null);
      }
    };

    const cancelScheduledMeasurement = () => {
      if (animationFrame !== 0) window.cancelAnimationFrame(animationFrame);
      animationFrame = 0;
      scheduledElement = null;
    };
    const suspendScheduledMeasurement = () => {
      measurementsEnabled = false;
      cancelScheduledMeasurement();
    };
    suspendScheduledMeasurementRef.current = suspendScheduledMeasurement;

    const scheduleMeasurement = (element = targetRef.current) => {
      if (!measurementsEnabled || !element) return;
      scheduledElement = element;
      if (animationFrame !== 0) return;
      animationFrame = window.requestAnimationFrame(() => {
        animationFrame = 0;
        const nextElement = scheduledElement;
        scheduledElement = null;
        if (nextElement) selectTarget(nextElement);
      });
    };
    const handleViewportChange = () => scheduleMeasurement();

    resizeObserver =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver(handleViewportChange);
    observe(targetRef.current);
    mutationObserver =
      typeof MutationObserver === "undefined"
        ? null
        : new MutationObserver((records) => {
            const element = targetRef.current;
            const externalRecords = records.filter(
              (record) => !isInspectorUiMutation(record)
            );
            if (
              element &&
              pinned &&
              externalRecords.some((record) => record.type === "childList")
            ) {
              observeResizeTargets(element);
            }
            if (
              element &&
              (mutationsAffectTarget(externalRecords, element) ||
                (pinned && externalRecords.length > 0))
            ) {
              scheduleMeasurement(element);
            }
          });
    observe(targetRef.current);

    const handlePointerMove = (event: PointerEvent) => {
      if (pinned) return;
      const element = inspectableElementAtPoint(event);
      if (element) scheduleMeasurement(element);
    };

    const handlePointerDown = (event: PointerEvent) => {
      if (event.button !== 0 || isInspectorUi(event.target)) return;
      const element = inspectableElementAtPoint(event) ?? targetRef.current;
      if (!element) return;

      event.preventDefault();
      event.stopPropagation();
      cancelScheduledMeasurement();
      selectTarget(element, true);
      setPinned(true);
    };

    const blockBusinessClick = (event: MouseEvent) => {
      if (isInspectorUi(event.target)) return;
      event.preventDefault();
      event.stopPropagation();
    };

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      if (
        document.querySelector(
          ".comma-layout-inspector__settings-menu, .comma-layout-inspector__changes-menu"
        )
      ) {
        return;
      }

      event.preventDefault();
      event.stopPropagation();
      suspendScheduledMeasurement();
      if (pinned) {
        setPinned(false);
        if (valueDisplayMode === "pixels") setAuthoredValues(null);
      } else {
        setActive(false);
      }
    };

    document.addEventListener("pointermove", handlePointerMove, true);
    document.addEventListener("pointerdown", handlePointerDown, true);
    document.addEventListener("click", blockBusinessClick, true);
    window.addEventListener("keydown", handleKeyDown, true);
    window.addEventListener("resize", handleViewportChange);
    window.addEventListener("scroll", handleViewportChange, true);

    return () => {
      suspendScheduledMeasurement();
      suspendScheduledMeasurementRef.current = () => undefined;
      mutationObserver?.disconnect();
      resizeObserver?.disconnect();
      document.body.style.cursor = previousCursor;
      document.removeEventListener("pointermove", handlePointerMove, true);
      document.removeEventListener("pointerdown", handlePointerDown, true);
      document.removeEventListener("click", blockBusinessClick, true);
      window.removeEventListener("keydown", handleKeyDown, true);
      window.removeEventListener("resize", handleViewportChange);
      window.removeEventListener("scroll", handleViewportChange, true);
    };
  }, [active, getElementKey, pinned, releaseInvalidTarget, valueDisplayMode]);

  useEffect(
    () => () => {
      for (const override of runtimeOverridesRef.current.values()) {
        restoreInlineOverride(override);
      }
      runtimeOverridesRef.current.clear();
    },
    []
  );

  if (!active || typeof document === "undefined") return null;

  return createPortal(
    <div
      className="comma-layout-inspector"
      data-comma-layout-inspector-ui="true"
      data-pinned={pinned ? "true" : "false"}
      data-react-aria-top-layer="true"
      data-value-display-mode={valueDisplayMode}
    >
      <output className="comma-layout-inspector__status">
        <span className="comma-layout-inspector__status-dot" />
        {pinned
          ? "Layout Inspector · pinned · Esc to release"
          : "Layout Inspector · hover to inspect · click to pin"}
      </output>

      {measurement ? (
        <>
          <ElementOverlay
            authoredValues={authoredValues}
            measurement={measurement}
            overlayVisibility={overlayVisibility}
            valueDisplayMode={valueDisplayMode}
          />
          {pinned && authoredValues ? (
            <InspectorPanel
              authoredValues={authoredValues}
              copyStatus={copyStatus}
              measurement={measurement}
              onClearChanges={clearChanges}
              onCopyPrompt={() => void copyPrompt()}
              onOverlayVisibilityChange={changeOverlayVisibility}
              onResetChange={resetChange}
              onValueDisplayModeChange={changeValueDisplayMode}
              onVariableChange={applyVariable}
              pendingChanges={pendingChanges}
              overlayVisibility={overlayVisibility}
              resolveVariables={resolveVariables}
              selectedElementKey={selectedElementKey}
              valueDisplayMode={valueDisplayMode}
            />
          ) : null}
        </>
      ) : null}
    </div>,
    document.body
  );
}

function ElementOverlay({
  authoredValues,
  measurement,
  overlayVisibility,
  valueDisplayMode,
}: {
  authoredValues: AuthoredLayoutValues | null;
  measurement: LayoutMeasurement;
  overlayVisibility: LayoutOverlayVisibility;
  valueDisplayMode: LayoutValueDisplayMode;
}) {
  const badgePosition = positionDimensionBadge(measurement.rect);
  const overlayRef = useRef<HTMLDivElement>(null);
  const visibleSegments = measurement.segments.filter(
    (segment) => segment.kind === "margin" || overlayVisibility[segment.kind] !== false
  );

  useLayoutEffect(() => {
    const overlay = overlayRef.current;
    if (!overlay) return;

    let animationFrame = 0;
    const arrange = () => arrangeRenderedOverlayLabels(overlay);
    const scheduleArrangement = () => {
      window.cancelAnimationFrame(animationFrame);
      animationFrame = window.requestAnimationFrame(arrange);
    };

    arrange();

    const resizeObserver =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver(scheduleArrangement);
    for (const element of overlay.querySelectorAll<HTMLElement>(
      ".comma-layout-inspector__segment-label, .comma-layout-inspector__dimension"
    )) {
      resizeObserver?.observe(element);
    }
    void document.fonts?.ready.then(scheduleArrangement);

    return () => {
      window.cancelAnimationFrame(animationFrame);
      resizeObserver?.disconnect();
    };
  }, [authoredValues, measurement, overlayVisibility, valueDisplayMode]);

  return (
    <div className="comma-layout-inspector__overlay" ref={overlayRef}>
      <svg aria-hidden="true" className="comma-layout-inspector__leader-layer">
        {visibleSegments.map((segment) => (
          <g
            data-inspector-kind={segment.kind}
            data-inspector-leader={segment.key}
            data-inspector-property={segment.property}
            data-visible="false"
            key={segment.key}
          >
            <line />
            <circle r="2" />
          </g>
        ))}
      </svg>
      {visibleSegments.map((segment) => (
        <Segment
          authoredValue={authoredValues?.[segment.property]}
          key={segment.key}
          segment={segment}
          valueDisplayMode={valueDisplayMode}
        />
      ))}
      <div
        className="comma-layout-inspector__border-box"
        data-testid="layout-inspector-border-box"
        style={rectStyle(measurement.rect)}
      />
      <div
        className="comma-layout-inspector__dimension"
        data-testid="layout-inspector-dimension"
        style={{
          left: badgePosition.left,
          top: badgePosition.top,
        }}
      >
        <strong>{measurement.nodeLabel}</strong>
        {measurement.geometry.limits.length > 0 ? (
          <em data-testid="layout-inspector-geometry-limited">Limited geometry</em>
        ) : null}
        <span>
          {formatOverlayValue(
            authoredValues?.width,
            measurement.rect.width,
            valueDisplayMode
          )}{" "}
          ×{" "}
          {formatOverlayValue(
            authoredValues?.height,
            measurement.rect.height,
            valueDisplayMode
          )}
        </span>
      </div>
    </div>
  );
}

function Segment({
  authoredValue,
  segment,
  valueDisplayMode,
}: {
  authoredValue: AuthoredLayoutValue | undefined;
  segment: OverlaySegment;
  valueDisplayMode: LayoutValueDisplayMode;
}) {
  return (
    <>
      <div
        className="comma-layout-inspector__segment"
        data-inspector-kind={segment.kind}
        data-inspector-property={segment.property}
        data-inspector-segment={segment.key}
        data-inspector-value={segment.value}
        style={rectStyle(segment.rect)}
      />
      <div
        className="comma-layout-inspector__segment-label"
        data-inspector-axis={segment.axis}
        data-inspector-kind={segment.kind}
        data-inspector-property={segment.property}
        style={segmentLabelStyle(segment.rect)}
      >
        {segmentPrefix(segment.kind)}{" "}
        {formatOverlayValue(authoredValue, segment.value, valueDisplayMode)}
      </div>
    </>
  );
}

function InspectorPanel({
  authoredValues,
  copyStatus,
  measurement,
  onClearChanges,
  onCopyPrompt,
  onOverlayVisibilityChange,
  onResetChange,
  onValueDisplayModeChange,
  onVariableChange,
  pendingChanges,
  overlayVisibility,
  resolveVariables,
  selectedElementKey,
  valueDisplayMode,
}: {
  authoredValues: AuthoredLayoutValues;
  copyStatus: "idle" | "copied" | "failed";
  measurement: LayoutMeasurement;
  onClearChanges: () => void;
  onCopyPrompt: () => void;
  onOverlayVisibilityChange: (
    kind: keyof LayoutOverlayVisibility,
    visible: boolean
  ) => void;
  onResetChange: (id: string) => void;
  onValueDisplayModeChange: (mode: LayoutValueDisplayMode) => void;
  onVariableChange: (
    property: InspectedLayoutProperty,
    variable: string | null
  ) => void;
  pendingChanges: PendingLayoutChange[];
  overlayVisibility: LayoutOverlayVisibility;
  resolveVariables: ResolveLayoutVariables | undefined;
  selectedElementKey: string | null;
  valueDisplayMode: LayoutValueDisplayMode;
}) {
  const settingsMenuId = useId();
  const panelRef = useRef<HTMLElement>(null);
  const settingsRef = useRef<HTMLDivElement>(null);
  const manualPositionRef = useRef(false);
  const dragRef = useRef<InspectorPanelDrag | null>(null);
  const resizeRef = useRef<InspectorPanelResize | null>(null);
  const pendingPropertyNavigationRef = useRef<PropertyNavigationTarget | null>(null);
  const [dragging, setDragging] = useState(false);
  const [resizing, setResizing] = useState(false);
  const [panelSize, setPanelSize] = useState<InspectorPanelSize | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [expandedPropertyGroups, setExpandedPropertyGroups] = useState(
    defaultExpandedPropertyGroups
  );
  const [position, setPosition] = useState<InspectorPanelPosition>(() => {
    const viewport = viewportRect();
    return positionInspectorPanel({
      anchor: measurement.rect,
      panel: estimatedPanelSize(viewport),
      viewport,
    });
  });
  const activeChange = (property: InspectedLayoutProperty) =>
    pendingChanges.find(
      (change) =>
        change.elementKey === selectedElementKey && change.property === property
    );
  const activeVariable = (property: InspectedLayoutProperty) =>
    activeChange(property)?.afterVariable;
  const originalValue = (property: InspectedLayoutProperty) =>
    restoreBaselineValue(authoredValues[property], activeChange(property));

  const focusPropertyTarget = useCallback(
    ({ group, property }: PropertyNavigationTarget) => {
      const panel = panelRef.current;
      const groupElement = panel?.querySelector<HTMLElement>(
        `[data-property-group="${group}"]`
      );
      const focusTarget = property
        ? panel?.querySelector<HTMLSelectElement>(
            `[data-layout-property="${property}"]`
          )
        : groupElement?.querySelector<HTMLButtonElement>(
            "[data-property-group-toggle]"
          );
      const scrollTarget = property ? (focusTarget ?? groupElement) : groupElement;
      scrollTarget?.scrollIntoView?.({
        block: property ? "center" : "start",
        inline: "nearest",
      });
      focusTarget?.focus({ preventScroll: true });
    },
    []
  );

  useLayoutEffect(() => {
    const target = pendingPropertyNavigationRef.current;
    if (!target || !expandedPropertyGroups[target.group]) return;

    pendingPropertyNavigationRef.current = null;
    focusPropertyTarget(target);
  }, [expandedPropertyGroups, focusPropertyTarget]);

  const navigateToProperty = useCallback(
    (target: PropertyNavigationTarget) => {
      if (expandedPropertyGroups[target.group]) {
        focusPropertyTarget(target);
        return;
      }

      pendingPropertyNavigationRef.current = target;
      setExpandedPropertyGroups((current) => ({
        ...current,
        [target.group]: true,
      }));
    },
    [expandedPropertyGroups, focusPropertyTarget]
  );

  const togglePropertyGroup = useCallback((group: CollapsiblePropertyGroupKind) => {
    pendingPropertyNavigationRef.current = null;
    setExpandedPropertyGroups((current) => ({
      ...current,
      [group]: !current[group],
    }));
  }, []);

  const resetAutomaticPosition = useCallback(() => {
    manualPositionRef.current = false;
    const viewport = viewportRect();
    setPosition(
      positionInspectorPanel({
        anchor: measurement.rect,
        panel: measuredPanelSize(panelRef.current, viewport),
        viewport,
      })
    );
  }, [measurement.rect]);

  useLayoutEffect(() => {
    const panel = panelRef.current;
    if (!panel) return;

    const updatePosition = () => {
      const viewport = viewportRect();
      const measuredSize = measuredPanelSize(panel, viewport);
      setPosition((current) => {
        if (manualPositionRef.current) {
          return {
            ...clampInspectorPanelPosition({
              panel: measuredSize,
              position: current,
              viewport,
            }),
            side: "manual",
          };
        }

        return positionInspectorPanel({
          anchor: measurement.rect,
          panel: measuredSize,
          viewport,
        });
      });
    };

    updatePosition();
    const resizeObserver =
      typeof ResizeObserver === "undefined" ? null : new ResizeObserver(updatePosition);
    resizeObserver?.observe(panel);
    window.addEventListener("resize", updatePosition);

    return () => {
      resizeObserver?.disconnect();
      window.removeEventListener("resize", updatePosition);
    };
  }, [measurement.rect]);

  useEffect(() => {
    if (!settingsOpen) return;

    const closeOnOutsidePointer = (event: PointerEvent) => {
      if (
        event.target instanceof Node &&
        !settingsRef.current?.contains(event.target)
      ) {
        setSettingsOpen(false);
      }
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.stopPropagation();
      setSettingsOpen(false);
    };

    document.addEventListener("pointerdown", closeOnOutsidePointer, true);
    document.addEventListener("keydown", closeOnEscape, true);
    return () => {
      document.removeEventListener("pointerdown", closeOnOutsidePointer, true);
      document.removeEventListener("keydown", closeOnEscape, true);
    };
  }, [settingsOpen]);

  const handleDragStart = (event: React.PointerEvent<HTMLElement>) => {
    if (event.button !== 0) return;

    event.preventDefault();
    event.stopPropagation();
    event.currentTarget.setPointerCapture?.(event.pointerId);
    const viewport = viewportRect();
    dragRef.current = {
      moved: false,
      panel: measuredPanelSize(panelRef.current, viewport),
      pointerId: event.pointerId,
      startLeft: position.left,
      startPointerX: event.clientX,
      startPointerY: event.clientY,
      startTop: position.top,
    };
    setDragging(true);
  };

  const handleDragMove = (event: React.PointerEvent<HTMLElement>) => {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;

    const deltaX = event.clientX - drag.startPointerX;
    const deltaY = event.clientY - drag.startPointerY;
    if (!drag.moved && Math.hypot(deltaX, deltaY) < 2) return;

    drag.moved = true;
    manualPositionRef.current = true;
    const viewport = viewportRect();
    setPosition({
      ...clampInspectorPanelPosition({
        panel: drag.panel,
        position: {
          left: drag.startLeft + deltaX,
          top: drag.startTop + deltaY,
        },
        viewport,
      }),
      side: "manual",
    });
  };

  const handleDragEnd = (event: React.PointerEvent<HTMLElement>) => {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;

    dragRef.current = null;
    setDragging(false);
    if (event.currentTarget.hasPointerCapture?.(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  };

  const applyPanelSize = useCallback(
    (requestedSize: InspectorPanelSize, minimum: InspectorPanelSize) => {
      const viewport = viewportRect();
      const nextSize = clampResizablePanelSize({
        minimum,
        requested: requestedSize,
        viewport,
      });

      manualPositionRef.current = true;
      setPanelSize(nextSize);
      setPosition((current) => ({
        ...clampInspectorPanelPosition({
          panel: nextSize,
          position: current,
          viewport,
        }),
        side: "manual",
      }));
    },
    []
  );

  const handleResizeStart = (event: React.PointerEvent<HTMLButtonElement>) => {
    if (event.button !== 0) return;

    event.preventDefault();
    event.stopPropagation();
    event.currentTarget.setPointerCapture?.(event.pointerId);
    const viewport = viewportRect();
    const currentSize = measuredPanelSize(panelRef.current, viewport);
    resizeRef.current = {
      minimum: minimumResizablePanelSize(panelRef.current, viewport),
      pointerId: event.pointerId,
      startHeight: currentSize.height,
      startPointerX: event.clientX,
      startPointerY: event.clientY,
      startWidth: currentSize.width,
    };
    setResizing(true);
  };

  const handleResizeMove = (event: React.PointerEvent<HTMLButtonElement>) => {
    const resize = resizeRef.current;
    if (!resize || resize.pointerId !== event.pointerId) return;

    applyPanelSize(
      {
        height: resize.startHeight + event.clientY - resize.startPointerY,
        width: resize.startWidth + event.clientX - resize.startPointerX,
      },
      resize.minimum
    );
  };

  const handleResizeEnd = (event: React.PointerEvent<HTMLButtonElement>) => {
    const resize = resizeRef.current;
    if (!resize || resize.pointerId !== event.pointerId) return;

    resizeRef.current = null;
    setResizing(false);
    if (event.currentTarget.hasPointerCapture?.(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  };

  const handleResizeKeyDown = (event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (event.key === "Home") {
      event.preventDefault();
      setPanelSize(null);
      return;
    }

    const direction = resizeDirections[event.key];
    if (!direction) return;

    event.preventDefault();
    const viewport = viewportRect();
    const currentSize = measuredPanelSize(panelRef.current, viewport);
    const step = event.shiftKey ? 24 : 8;
    applyPanelSize(
      {
        height: currentSize.height + direction[1] * step,
        width: currentSize.width + direction[0] * step,
      },
      minimumResizablePanelSize(panelRef.current, viewport)
    );
  };

  return (
    <section
      aria-label="Selected element layout"
      className="comma-layout-inspector__panel"
      data-dragging={dragging ? "true" : "false"}
      data-placement={position.side}
      data-resizing={resizing ? "true" : "false"}
      data-testid="layout-inspector-panel"
      ref={panelRef}
      style={{
        left: position.left,
        top: position.top,
        ...(panelSize
          ? {
              height: panelSize.height,
              width: panelSize.width,
            }
          : {}),
      }}
    >
      <header
        className="comma-layout-inspector__panel-header"
        onDoubleClick={resetAutomaticPosition}
        onPointerCancel={handleDragEnd}
        onPointerDown={handleDragStart}
        onPointerMove={handleDragMove}
        onPointerUp={handleDragEnd}
        title="Drag to move · double-click to restore automatic placement"
      >
        <div className="comma-layout-inspector__panel-header-main">
          <p>Selected element</p>
          <h2>{measurement.nodeLabel}</h2>
        </div>
        <div className="comma-layout-inspector__panel-header-meta">
          <CopySourceButton element={measurement.element} key={selectedElementKey} />
          <span className="comma-layout-inspector__panel-display">
            {measurement.display}
          </span>
          <div
            className="comma-layout-inspector__settings-anchor"
            onPointerDown={(event) => event.stopPropagation()}
            ref={settingsRef}
          >
            <button
              aria-controls={settingsMenuId}
              aria-expanded={settingsOpen}
              aria-label="Inspector settings"
              className="comma-layout-inspector__settings-button"
              onClick={() => setSettingsOpen((current) => !current)}
              type="button"
            >
              <SettingsIcon ariaHidden data-comma-icon="" />
            </button>
            {settingsOpen ? (
              <InspectorSettingsMenu
                id={settingsMenuId}
                onOverlayVisibilityChange={onOverlayVisibilityChange}
                onValueDisplayModeChange={onValueDisplayModeChange}
                overlayVisibility={overlayVisibility}
                valueDisplayMode={valueDisplayMode}
              />
            ) : null}
          </div>
        </div>
      </header>

      <BoxModelView measurement={measurement} onNavigate={navigateToProperty} />

      <section
        aria-labelledby="comma-layout-properties-title"
        className="comma-layout-inspector__panel-section comma-layout-inspector__properties"
      >
        <PanelSectionHeader
          detail={`${measurement.boxSizing}${measurement.transformed ? " · transformed" : ""}`}
          id="comma-layout-properties-title"
          title="Properties"
        />

        <div
          className="comma-layout-inspector__properties-scroll"
          data-testid="layout-inspector-properties-scroll"
        >
          <section
            className="comma-layout-inspector__property-group"
            data-inspector-kind="size"
          >
            <h4>Size</h4>
            <dl className="comma-layout-inspector__property-list">
              <PropertyValue
                label="Width"
                onVariableChange={onVariableChange}
                originalValue={originalValue("width")}
                property="width"
                resolveVariables={resolveVariables}
                selectedVariable={activeVariable("width")}
                targetElement={measurement.element}
                value={authoredValues.width}
                visualValue={`${formatNumber(measurement.rect.width)}px visual`}
              />
              <PropertyValue
                label="Height"
                onVariableChange={onVariableChange}
                originalValue={originalValue("height")}
                property="height"
                resolveVariables={resolveVariables}
                selectedVariable={activeVariable("height")}
                targetElement={measurement.element}
                value={authoredValues.height}
                visualValue={`${formatNumber(measurement.rect.height)}px visual`}
              />
            </dl>
          </section>

          <EdgeValueGroup
            authoredValues={authoredValues}
            edges={measurement.margin}
            expanded={expandedPropertyGroups.margin}
            kind="margin"
            onToggle={() => togglePropertyGroup("margin")}
            onVariableChange={onVariableChange}
            pendingChanges={pendingChanges}
            resolveVariables={resolveVariables}
            selectedElementKey={selectedElementKey}
            targetElement={measurement.element}
            title="Margin"
          />
          <EdgeValueGroup
            authoredValues={authoredValues}
            edges={measurement.border}
            expanded={expandedPropertyGroups.border}
            kind="border"
            onToggle={() => togglePropertyGroup("border")}
            onVariableChange={onVariableChange}
            pendingChanges={pendingChanges}
            resolveVariables={resolveVariables}
            selectedElementKey={selectedElementKey}
            targetElement={measurement.element}
            title="Border width"
          />
          <EdgeValueGroup
            authoredValues={authoredValues}
            edges={measurement.padding}
            expanded={expandedPropertyGroups.padding}
            kind="padding"
            onToggle={() => togglePropertyGroup("padding")}
            onVariableChange={onVariableChange}
            pendingChanges={pendingChanges}
            resolveVariables={resolveVariables}
            selectedElementKey={selectedElementKey}
            targetElement={measurement.element}
            title="Padding"
          />

          {measurement.display.includes("flex") ||
          measurement.display.includes("grid") ? (
            <CollapsiblePropertyGroup
              expanded={expandedPropertyGroups.gap}
              kind="gap"
              onToggle={() => togglePropertyGroup("gap")}
              summary={`R ${formatPixel(measurement.gap.row)} · C ${formatPixel(measurement.gap.column)}`}
              title="Gap"
            >
              <dl className="comma-layout-inspector__property-list">
                <PropertyValue
                  label="Row gap"
                  onVariableChange={onVariableChange}
                  originalValue={originalValue("row-gap")}
                  property="row-gap"
                  resolveVariables={resolveVariables}
                  selectedVariable={activeVariable("row-gap")}
                  targetElement={measurement.element}
                  value={authoredValues["row-gap"]}
                />
                <PropertyValue
                  label="Column gap"
                  onVariableChange={onVariableChange}
                  originalValue={originalValue("column-gap")}
                  property="column-gap"
                  resolveVariables={resolveVariables}
                  selectedVariable={activeVariable("column-gap")}
                  targetElement={measurement.element}
                  value={authoredValues["column-gap"]}
                />
              </dl>
            </CollapsiblePropertyGroup>
          ) : null}
        </div>
      </section>

      <ChangesCard
        changes={pendingChanges}
        copyStatus={copyStatus}
        onClear={onClearChanges}
        onCopy={onCopyPrompt}
        onReset={onResetChange}
      />

      <button
        aria-label="Resize inspector panel"
        className="comma-layout-inspector__resize-handle"
        onDoubleClick={() => setPanelSize(null)}
        onKeyDown={handleResizeKeyDown}
        onPointerCancel={handleResizeEnd}
        onPointerDown={handleResizeStart}
        onPointerMove={handleResizeMove}
        onPointerUp={handleResizeEnd}
        title="Drag to resize · double-click or press Home to fit content"
        type="button"
      />
    </section>
  );
}

function PanelSectionHeader({
  detail,
  id,
  title,
}: {
  detail?: string | undefined;
  id: string;
  title: string;
}) {
  return (
    <header className="comma-layout-inspector__section-header">
      <h3 id={id}>{title}</h3>
      {detail ? <span>{detail}</span> : null}
    </header>
  );
}

function InspectorSettingsMenu({
  id,
  onOverlayVisibilityChange,
  onValueDisplayModeChange,
  overlayVisibility,
  valueDisplayMode,
}: {
  id: string;
  onOverlayVisibilityChange: (
    kind: keyof LayoutOverlayVisibility,
    visible: boolean
  ) => void;
  onValueDisplayModeChange: (mode: LayoutValueDisplayMode) => void;
  overlayVisibility: LayoutOverlayVisibility;
  valueDisplayMode: LayoutValueDisplayMode;
}) {
  return (
    <dialog
      aria-label="Inspector settings"
      className="comma-layout-inspector__settings-menu"
      id={id}
      open
    >
      <DisplaySettings onChange={onValueDisplayModeChange} value={valueDisplayMode} />
      <OverlayVisibilitySettings
        onChange={onOverlayVisibilityChange}
        value={overlayVisibility}
      />
    </dialog>
  );
}

function BoxModelView({
  measurement,
  onNavigate,
}: {
  measurement: LayoutMeasurement;
  onNavigate: (target: PropertyNavigationTarget) => void;
}) {
  const contentWidth = Math.max(
    0,
    measurement.rect.width -
      measurement.border.left -
      measurement.border.right -
      measurement.padding.left -
      measurement.padding.right
  );
  const contentHeight = Math.max(
    0,
    measurement.rect.height -
      measurement.border.top -
      measurement.border.bottom -
      measurement.padding.top -
      measurement.padding.bottom
  );
  const showsGap =
    measurement.display.includes("flex") || measurement.display.includes("grid");
  const transformed = measurement.geometry.limits.includes(
    "transformed-coordinate-space"
  );

  return (
    <section
      aria-labelledby="comma-layout-box-model-title"
      className="comma-layout-inspector__panel-section comma-layout-inspector__box-model"
      data-testid="layout-inspector-box-model"
    >
      <PanelSectionHeader
        detail={`${formatNumber(measurement.rect.width)} × ${formatNumber(measurement.rect.height)}`}
        id="comma-layout-box-model-title"
        title="Box model"
      />
      {measurement.geometry.boxModel ? (
        <BoxModelLayer
          edges={measurement.margin}
          kind="margin"
          label="Margin"
          onNavigate={onNavigate}
        >
          <BoxModelLayer
            edges={measurement.border}
            kind="border"
            label="Border"
            onNavigate={onNavigate}
          >
            <BoxModelLayer
              edges={measurement.padding}
              kind="padding"
              label="Padding"
              onNavigate={onNavigate}
            >
              <div className="comma-layout-inspector__box-content">
                <span>content</span>
                <strong>
                  {formatNumber(contentWidth)} × {formatNumber(contentHeight)}
                </strong>
              </div>
            </BoxModelLayer>
          </BoxModelLayer>
        </BoxModelLayer>
      ) : (
        <GeometryLimitNotice
          detail="Margin, border, padding, and gap overlays are omitted."
          reason={
            transformed ? "Transformed coordinate space" : "Unsupported box geometry"
          }
        />
      )}
      {showsGap && measurement.geometry.boxModel ? (
        measurement.geometry.gap ? (
          <div className="comma-layout-inspector__box-gap">
            <button
              aria-label="Show Gap properties"
              className="comma-layout-inspector__box-gap-name"
              onClick={() => onNavigate({ group: "gap" })}
              type="button"
            >
              Gap
            </button>
            <button
              aria-label="Show Row gap property"
              onClick={() =>
                onNavigate({
                  group: "gap",
                  property: "row-gap",
                })
              }
              type="button"
            >
              <span>Row</span>
              <strong>{formatNumber(measurement.gap.row)}</strong>
            </button>
            <button
              aria-label="Show Column gap property"
              onClick={() =>
                onNavigate({
                  group: "gap",
                  property: "column-gap",
                })
              }
              type="button"
            >
              <span>Column</span>
              <strong>{formatNumber(measurement.gap.column)}</strong>
            </button>
          </div>
        ) : (
          <GeometryLimitNotice
            detail="Gap overlays are omitted."
            reason={geometryLimitLabel(measurement.geometry.limits[0])}
          />
        )
      ) : null}
    </section>
  );
}

function GeometryLimitNotice({ detail, reason }: { detail: string; reason: string }) {
  return (
    <div
      className="comma-layout-inspector__geometry-limit"
      data-testid="layout-inspector-geometry-limit"
    >
      <strong>Limited geometry</strong>
      <span>{reason}</span>
      <p>{detail}</p>
    </div>
  );
}

function geometryLimitLabel(limit: LayoutGeometryLimit | undefined) {
  if (limit === "anonymous-text-flex-items") {
    return "Anonymous text flex items";
  }
  if (limit === "display-contents-flex-items") {
    return "display: contents flex items";
  }
  if (limit === "collapsed-grid-tracks") {
    return "Collapsed grid tracks";
  }
  if (limit === "transformed-coordinate-space") {
    return "Transformed coordinate space";
  }
  return "Unsupported layout geometry";
}

function BoxModelLayer({
  children,
  edges,
  kind,
  label,
  onNavigate,
}: {
  children: React.ReactNode;
  edges: BoxEdges;
  kind: "border" | "margin" | "padding";
  label: string;
  onNavigate: (target: PropertyNavigationTarget) => void;
}) {
  return (
    <div
      aria-label={`${label}: top ${formatPixel(edges.top)}, right ${formatPixel(edges.right)}, bottom ${formatPixel(edges.bottom)}, left ${formatPixel(edges.left)}`}
      className="comma-layout-inspector__box-layer"
      data-inspector-kind={kind}
    >
      <button
        aria-label={`Show ${label} properties`}
        className="comma-layout-inspector__box-name"
        onClick={() => onNavigate({ group: kind })}
        type="button"
      >
        {label}
      </button>
      {edgeNames.map((edge) => {
        const property = (
          kind === "border" ? `border-${edge}-width` : `${kind}-${edge}`
        ) as InspectedLayoutProperty;

        return (
          <button
            aria-label={`Show ${label} ${edge} property`}
            className="comma-layout-inspector__box-edge"
            data-edge={edge}
            key={edge}
            onClick={() =>
              onNavigate({
                group: kind,
                property,
              })
            }
            title={formatPixel(edges[edge])}
            type="button"
          >
            {formatNumber(edges[edge])}
          </button>
        );
      })}
      {children}
    </div>
  );
}

function DisplaySettings({
  onChange,
  value,
}: {
  onChange: (mode: LayoutValueDisplayMode) => void;
  value: LayoutValueDisplayMode;
}) {
  const labelId = useId();
  const radioName = useId();

  return (
    <fieldset
      aria-labelledby={labelId}
      className="comma-layout-inspector__display-settings comma-layout-inspector__setting-row"
    >
      <span className="comma-layout-inspector__setting-label" id={labelId}>
        Units
      </span>
      <div className="comma-layout-inspector__segmented-control">
        {valueDisplayModes.map((mode) => (
          <label data-selected={value === mode.value} key={mode.value}>
            <input
              checked={value === mode.value}
              name={radioName}
              onChange={() => onChange(mode.value)}
              type="radio"
              value={mode.value}
            />
            <span>{mode.label}</span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

function OverlayVisibilitySettings({
  onChange,
  value,
}: {
  onChange: (kind: keyof LayoutOverlayVisibility, visible: boolean) => void;
  value: LayoutOverlayVisibility;
}) {
  const layers: Array<{
    kind: keyof LayoutOverlayVisibility;
    label: string;
  }> = [
    { kind: "padding", label: "Padding" },
    { kind: "border", label: "Border" },
    { kind: "gap", label: "Gap" },
  ];

  return (
    <div className="comma-layout-inspector__overlay-settings">
      {layers.map(({ kind, label }) => (
        <label
          className="comma-layout-inspector__setting-row"
          data-inspector-kind={kind}
          key={kind}
        >
          <span className="comma-layout-inspector__setting-label">{label}</span>
          <span className="comma-layout-inspector__setting-control">
            <input
              aria-checked={value[kind]}
              aria-label={`Show ${kind} overlay`}
              checked={value[kind]}
              onChange={(event) => onChange(kind, event.currentTarget.checked)}
              role="switch"
              type="checkbox"
            />
            <span
              aria-hidden="true"
              className="comma-layout-inspector__switch-control"
            />
          </span>
        </label>
      ))}
    </div>
  );
}

function CollapsiblePropertyGroup({
  children,
  expanded,
  kind,
  onToggle,
  summary,
  title,
}: {
  children: React.ReactNode;
  expanded: boolean;
  kind: CollapsiblePropertyGroupKind;
  onToggle: () => void;
  summary: string;
  title: string;
}) {
  const contentId = useId();

  return (
    <section
      className="comma-layout-inspector__property-group"
      data-collapsible="true"
      data-collapsed={expanded ? "false" : "true"}
      data-inspector-kind={kind}
      data-property-group={kind}
    >
      <h4>
        <button
          aria-controls={contentId}
          aria-expanded={expanded}
          aria-label={`${expanded ? "Collapse" : "Expand"} ${title}`}
          data-property-group-toggle
          onClick={onToggle}
          type="button"
        >
          <span
            aria-hidden="true"
            className="comma-layout-inspector__property-group-chevron"
          />
          <span>{title}</span>
          <small>{summary}</small>
        </button>
      </h4>
      {expanded ? (
        <div className="comma-layout-inspector__property-group-content" id={contentId}>
          {children}
        </div>
      ) : null}
    </section>
  );
}

function EdgeValueGroup({
  authoredValues,
  edges,
  expanded,
  kind,
  onToggle,
  onVariableChange,
  pendingChanges,
  resolveVariables,
  selectedElementKey,
  targetElement,
  title,
}: {
  authoredValues: AuthoredLayoutValues;
  edges: BoxEdges;
  expanded: boolean;
  kind: "border" | "margin" | "padding";
  onToggle: () => void;
  onVariableChange: (
    property: InspectedLayoutProperty,
    variable: string | null
  ) => void;
  pendingChanges: PendingLayoutChange[];
  resolveVariables: ResolveLayoutVariables | undefined;
  selectedElementKey: string | null;
  targetElement: Element;
  title: string;
}) {
  return (
    <CollapsiblePropertyGroup
      expanded={expanded}
      kind={kind}
      onToggle={onToggle}
      summary={edgeNames
        .map((edge) => `${edge.at(0)?.toUpperCase()} ${formatNumber(edges[edge])}`)
        .join(" · ")}
      title={title}
    >
      <dl className="comma-layout-inspector__property-list">
        {edgeNames.map((edge) => {
          const property = (
            kind === "border" ? `border-${edge}-width` : `${kind}-${edge}`
          ) as InspectedLayoutProperty;
          const pendingChange = pendingChanges.find(
            (change) =>
              change.elementKey === selectedElementKey && change.property === property
          );

          return (
            <PropertyValue
              key={edge}
              label={`${title} ${edge}`}
              onVariableChange={onVariableChange}
              originalValue={restoreBaselineValue(
                authoredValues[property],
                pendingChange
              )}
              property={property}
              resolveVariables={resolveVariables}
              selectedVariable={pendingChange?.afterVariable}
              targetElement={targetElement}
              value={authoredValues[property]}
              visualValue={`${formatPixel(edges[edge])} used`}
            />
          );
        })}
      </dl>
    </CollapsiblePropertyGroup>
  );
}

function PropertyValue({
  label,
  onVariableChange,
  originalValue,
  property,
  resolveVariables,
  selectedVariable,
  targetElement,
  value,
  visualValue,
}: {
  label: string;
  onVariableChange: (
    property: InspectedLayoutProperty,
    variable: string | null
  ) => void;
  originalValue: AuthoredLayoutValue;
  property: InspectedLayoutProperty;
  resolveVariables: ResolveLayoutVariables | undefined;
  selectedVariable: string | undefined;
  targetElement: Element;
  value: AuthoredLayoutValue;
  visualValue?: string;
}) {
  const source =
    value.confidence === "authored"
      ? value.expression
      : value.confidence === "inferred"
        ? `≈ ${value.variables[0]}`
        : undefined;
  const options = (
    resolveVariables
      ? resolveVariables({
          authoredValue: value,
          element: targetElement,
          property,
        })
      : variableOptionsForProperty(property, value, targetElement)
  ).filter((option) => !originalValue.variables.includes(option.value));
  const originalLabel = formatOriginalOptionLabel(
    originalValue,
    Boolean(selectedVariable)
  );
  const meta = [
    value.computed || "—",
    source,
    visualValue && visualValue !== `${value.computed} used` ? visualValue : undefined,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <div
      className="comma-layout-inspector__property"
      data-confidence={value.confidence}
      title={value.selector}
    >
      <dt>
        <PropertyIcon property={property} />
        <span>
          <strong>{label}</strong>
          <small title={meta}>{meta}</small>
        </span>
      </dt>
      <dd>
        <select
          aria-label={`${humanizeProperty(property)} variable`}
          data-layout-property={property}
          onChange={(event) =>
            onVariableChange(property, event.currentTarget.value || null)
          }
          value={selectedVariable ?? ""}
        >
          <option value="">{originalLabel}</option>
          {options.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
      </dd>
    </div>
  );
}

function PropertyIcon({ property }: { property: InspectedLayoutProperty }) {
  const kind = property.startsWith("margin-")
    ? "margin"
    : property.startsWith("padding-")
      ? "padding"
      : property.startsWith("border-")
        ? "border"
        : property.endsWith("-gap")
          ? "gap"
          : "size";
  const direction =
    property === "width"
      ? "horizontal"
      : property === "height"
        ? "vertical"
        : property === "row-gap"
          ? "row"
          : property === "column-gap"
            ? "column"
            : (edgeNames.find((edge) => property.includes(`-${edge}`)) ?? "horizontal");

  return (
    <span
      aria-hidden="true"
      className="comma-layout-inspector__property-icon"
      data-direction={direction}
      data-inspector-kind={kind}
    />
  );
}

function ChangesCard({
  changes,
  copyStatus,
  onClear,
  onCopy,
  onReset,
}: {
  changes: PendingLayoutChange[];
  copyStatus: "idle" | "copied" | "failed";
  onClear: () => void;
  onCopy: () => void;
  onReset: (id: string) => void;
}) {
  const menuId = useId();
  const cardRef = useRef<HTMLElement>(null);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (changes.length === 0) setOpen(false);
  }, [changes.length]);

  useEffect(() => {
    if (!open) return;

    const closeOnOutsidePointer = (event: PointerEvent) => {
      if (event.target instanceof Node && !cardRef.current?.contains(event.target)) {
        setOpen(false);
      }
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.stopPropagation();
      setOpen(false);
    };

    document.addEventListener("pointerdown", closeOnOutsidePointer, true);
    document.addEventListener("keydown", closeOnEscape, true);
    return () => {
      document.removeEventListener("pointerdown", closeOnOutsidePointer, true);
      document.removeEventListener("keydown", closeOnEscape, true);
    };
  }, [open]);

  return (
    <section
      aria-label="Layout changes"
      className="comma-layout-inspector__changes-card"
      data-open={open ? "true" : "false"}
      data-testid="layout-inspector-pending"
      ref={cardRef}
    >
      <div className="comma-layout-inspector__changes-row">
        <button
          aria-controls={menuId}
          aria-expanded={open}
          className="comma-layout-inspector__changes-trigger"
          disabled={changes.length === 0}
          onClick={() => setOpen((current) => !current)}
          type="button"
        >
          <span>Changes</span>
          <strong>{changes.length}</strong>
        </button>
        <button disabled={changes.length === 0} onClick={onClear} type="button">
          Clear all
        </button>
        <button
          data-testid="copy-layout-prompt"
          disabled={changes.length === 0}
          onClick={onCopy}
          type="button"
        >
          {copyStatus === "copied"
            ? "Copied"
            : copyStatus === "failed"
              ? "Copy failed"
              : "Copy prompt"}
        </button>
      </div>

      {open ? (
        <dialog
          aria-label="Layout change list"
          className="comma-layout-inspector__changes-menu"
          id={menuId}
          open
        >
          <ol>
            {changes.map((change) => {
              const targetLabel = change.target.sourceLocation
                ? formatLayoutSourceLocation(change.target.sourceLocation)
                : change.target.selector;

              return (
                <li key={change.id}>
                  <div>
                    <code title={change.target.selector}>{targetLabel}</code>
                    <strong>{change.property}</strong>
                    <span>
                      {change.beforeExpression} → var({change.afterVariable})
                    </span>
                  </div>
                  <button
                    aria-label={`Clear ${change.property} on ${targetLabel}`}
                    onClick={() => onReset(change.id)}
                    type="button"
                  >
                    Clear
                  </button>
                </li>
              );
            })}
          </ol>
        </dialog>
      ) : null}
    </section>
  );
}

function inspectableElementAtPoint(event: PointerEvent) {
  const composedCandidate = event
    .composedPath()
    .find(
      (candidate): candidate is Element =>
        candidate instanceof Element && !isInspectorUi(candidate)
    );
  if (composedCandidate) return composedCandidate;

  return typeof document.elementsFromPoint === "function"
    ? (document
        .elementsFromPoint(event.clientX, event.clientY)
        .find((candidate) => !isInspectorUi(candidate)) ?? null)
    : null;
}

function isInspectorUi(target: EventTarget | null) {
  return (
    target instanceof Element &&
    (target.hasAttribute(inspectorUiAttribute) ||
      target.closest(`[${inspectorUiAttribute}]`) !== null)
  );
}

function surroundingResizeTargets(
  target: Element,
  includeSurroundings: boolean,
  limit: number
) {
  const targets: Element[] = [];
  const seen = new Set<Element>();
  const add = (element: Element) => {
    if (targets.length >= limit || seen.has(element) || isInspectorUi(element)) {
      return;
    }
    seen.add(element);
    targets.push(element);
  };

  add(target);
  if (!includeSurroundings) return targets;

  const ancestorChain: Element[] = [];
  let current: Element | null = target;
  while (current) {
    ancestorChain.push(current);
    const parent: Element | null = current.parentElement;
    if (parent) {
      current = parent;
      continue;
    }

    const root = current.getRootNode();
    if (!(root instanceof ShadowRoot)) break;
    current = root.host;
  }

  // Preserve the composed ancestor chain before spending the bounded remainder
  // on siblings. A large list near the target must not crowd out an ancestor
  // whose mutation-free resize can move the whole subtree.
  for (const ancestor of ancestorChain) add(ancestor);

  for (const chainElement of ancestorChain) {
    if (targets.length >= limit) break;
    const root = chainElement.getRootNode();
    const siblingParent =
      chainElement.parentElement ?? (root instanceof ShadowRoot ? root : null);
    if (!siblingParent) continue;

    const siblings: Element[] = Array.from(siblingParent.children);
    const currentIndex = siblings.indexOf(chainElement);
    for (
      let distance = 1;
      distance < siblings.length && targets.length < limit;
      distance += 1
    ) {
      const previous = siblings[currentIndex - distance];
      const next = siblings[currentIndex + distance];
      if (previous) add(previous);
      if (next) add(next);
    }
  }

  return targets;
}

function isInspectorUiMutation(record: MutationRecord) {
  if (isInspectorOwnedNode(record.target)) return true;
  if (record.type !== "childList") return false;

  const changedNodes = [...record.addedNodes, ...record.removedNodes];
  return changedNodes.length > 0 && changedNodes.every(isInspectorOwnedNode);
}

function isInspectorOwnedNode(node: Node) {
  if (node instanceof Element) return isInspectorUi(node);
  return node.parentElement ? isInspectorUi(node.parentElement) : false;
}

function mutationsAffectTarget(records: readonly MutationRecord[], target: Element) {
  return records.some((record) => {
    if (record.type === "attributes") {
      return (
        record.target instanceof Element && isComposedAncestor(record.target, target)
      );
    }

    if (record.type !== "childList") return false;
    return Array.from(record.removedNodes).some(
      (node) =>
        node === target || (node instanceof Element && isComposedAncestor(node, target))
    );
  });
}

function isComposedAncestor(ancestor: Element, target: Element) {
  let current: Element | null = target;

  while (current) {
    if (current === ancestor) return true;
    const root = current.getRootNode();
    current = current.parentElement ?? (root instanceof ShadowRoot ? root.host : null);
  }

  return false;
}

function restoreInlineOverride(override: RuntimeOverride) {
  if (!inlineOverrideOwnsCurrentValue(override)) return false;

  withSuppressedTransitions(override.element, () => {
    if (override.value) {
      override.element.style.setProperty(
        override.property,
        override.value,
        override.priority
      );
    } else {
      override.element.style.removeProperty(override.property);
    }
  });
  return true;
}

function inlineOverrideOwnsCurrentValue(override: RuntimeOverride) {
  return (
    override.element.style.getPropertyValue(override.property) ===
      override.previewValue &&
    override.element.style.getPropertyPriority(override.property) ===
      override.previewPriority
  );
}

function applyInlinePreview(
  element: HTMLElement | SVGElement,
  property: InspectedLayoutProperty,
  value: string
) {
  return withSuppressedTransitions(element, () => {
    element.style.setProperty(property, value, "important");

    return {
      computed: getComputedStyle(element).getPropertyValue(property).trim(),
      priority: element.style.getPropertyPriority(property),
      value: element.style.getPropertyValue(property),
    };
  });
}

function withSuppressedTransitions<Result>(
  element: HTMLElement | SVGElement,
  update: () => Result
) {
  const transitionProperty = {
    priority: element.style.getPropertyPriority("transition-property"),
    value: element.style.getPropertyValue("transition-property"),
  };

  element.style.setProperty("transition-property", "none", "important");
  void getComputedStyle(element).transitionProperty;
  try {
    const result = update();
    void element.getBoundingClientRect().top;
    return result;
  } finally {
    if (transitionProperty.value) {
      element.style.setProperty(
        "transition-property",
        transitionProperty.value,
        transitionProperty.priority
      );
    } else {
      element.style.removeProperty("transition-property");
    }
  }
}

function CopySourceButton({ element }: { element: Element }) {
  const [status, setStatus] = useState<"idle" | "copied" | "failed">("idle");

  const copySource = async () => {
    const copied = await copyText(buildElementSourceReport(element));
    setStatus(copied ? "copied" : "failed");
  };

  return (
    <button
      aria-label="Copy source"
      className="comma-layout-inspector__copy-source"
      onClick={() => void copySource()}
      onDoubleClick={(event) => event.stopPropagation()}
      onPointerDown={(event) => event.stopPropagation()}
      title="Copy source location and element locator"
      type="button"
    >
      <span aria-live="polite">
        {status === "copied"
          ? "Copied"
          : status === "failed"
            ? "Retry copy"
            : "Copy source"}
      </span>
    </button>
  );
}

async function copyText(value: string) {
  try {
    await navigator.clipboard.writeText(value);
    return true;
  } catch {
    const textArea = document.createElement("textarea");
    textArea.value = value;
    textArea.setAttribute("readonly", "");
    textArea.style.position = "fixed";
    textArea.style.opacity = "0";
    document.body.append(textArea);
    textArea.select();

    try {
      return document.execCommand("copy");
    } catch {
      return false;
    } finally {
      textArea.remove();
    }
  }
}

function humanizeProperty(property: InspectedLayoutProperty) {
  const words = property.replaceAll("-", " ");
  return `${words.at(0)?.toUpperCase() ?? ""}${words.slice(1)}`;
}

function compactCssExpression(value: string) {
  return value.replaceAll(/\s/g, "");
}

function restoreBaselineValue(
  current: AuthoredLayoutValue,
  change: PendingLayoutChange | undefined
): AuthoredLayoutValue {
  if (!change) return current;

  const variables =
    change.beforeVariables ??
    Array.from(
      change.beforeExpression.matchAll(/var\(\s*(--[\w-]+)/g),
      (match) => match[1]
    ).filter((variable): variable is string => variable !== undefined);

  return {
    computed: change.beforeComputed,
    confidence:
      change.beforeConfidence ?? (variables.length > 0 ? "authored" : "computed"),
    expression: change.beforeExpression,
    variables,
  };
}

function viewportRect(): InspectorRect {
  if (typeof window === "undefined") {
    return {
      height: 768,
      left: 0,
      top: 0,
      width: 1024,
    };
  }

  return {
    height: window.innerHeight,
    left: 0,
    top: 0,
    width: window.innerWidth,
  };
}

function estimatedPanelSize(viewport: InspectorRect): InspectorPanelSize {
  return {
    height: Math.max(1, viewport.height - 24),
    width: Math.max(1, Math.min(360, viewport.width - 24)),
  };
}

function measuredPanelSize(
  panel: HTMLElement | null,
  viewport: InspectorRect
): InspectorPanelSize {
  const bounds = panel?.getBoundingClientRect();
  const estimate = estimatedPanelSize(viewport);
  return {
    height: bounds && bounds.height > 0 ? bounds.height : estimate.height,
    width: bounds && bounds.width > 0 ? bounds.width : estimate.width,
  };
}

function minimumResizablePanelSize(
  panel: HTMLElement | null,
  viewport: InspectorRect
): InspectorPanelSize {
  const maximum = {
    height: Math.max(1, viewport.height - 24),
    width: Math.max(1, viewport.width - 24),
  };
  if (!panel) {
    return {
      height: Math.min(220, maximum.height),
      width: Math.min(320, maximum.width),
    };
  }

  const properties = panel.querySelector<HTMLElement>(
    ":scope > .comma-layout-inspector__properties"
  );
  const fixedHeight = Array.from(panel.children)
    .filter(
      (child): child is HTMLElement =>
        child instanceof HTMLElement &&
        child !== properties &&
        !child.classList.contains("comma-layout-inspector__resize-handle")
    )
    .reduce((total, child) => total + outerHeight(child), 0);
  const panelStyle = getComputedStyle(panel);
  const panelBorder =
    numericCssValue(panelStyle.borderTopWidth) +
    numericCssValue(panelStyle.borderBottomWidth);
  const propertiesMinimum = properties ? minimumOuterHeight(properties) : 220;
  const configuredMinimumWidth =
    numericCssValue(panelStyle.minWidth) > 0
      ? numericCssValue(panelStyle.minWidth)
      : 320;

  return {
    height: Math.min(
      Math.max(1, fixedHeight + panelBorder + propertiesMinimum),
      maximum.height
    ),
    width: Math.min(Math.max(1, configuredMinimumWidth), maximum.width),
  };
}

function minimumOuterHeight(element: HTMLElement) {
  const style = getComputedStyle(element);
  const minimum = numericCssValue(style.minHeight);
  const verticalChrome =
    numericCssValue(style.paddingTop) +
    numericCssValue(style.paddingBottom) +
    numericCssValue(style.borderTopWidth) +
    numericCssValue(style.borderBottomWidth);
  const margin = numericCssValue(style.marginTop) + numericCssValue(style.marginBottom);

  return minimum + (style.boxSizing === "border-box" ? 0 : verticalChrome) + margin;
}

function outerHeight(element: HTMLElement) {
  const style = getComputedStyle(element);
  return (
    element.getBoundingClientRect().height +
    numericCssValue(style.marginTop) +
    numericCssValue(style.marginBottom)
  );
}

function numericCssValue(value: string) {
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function clampResizablePanelSize({
  minimum,
  requested,
  viewport,
}: {
  minimum: InspectorPanelSize;
  requested: InspectorPanelSize;
  viewport: InspectorRect;
}): InspectorPanelSize {
  const maximum = {
    height: Math.max(1, viewport.height - 24),
    width: Math.max(1, viewport.width - 24),
  };
  const minimumWidth = Math.min(minimum.width, maximum.width);
  const minimumHeight = Math.min(minimum.height, maximum.height);

  return {
    height: Math.min(Math.max(requested.height, minimumHeight), maximum.height),
    width: Math.min(Math.max(requested.width, minimumWidth), maximum.width),
  };
}

function rectStyle(rect: InspectorRect): CSSProperties {
  return {
    height: rect.height,
    left: rect.left,
    top: rect.top,
    width: rect.width,
  };
}

function inspectorRect(rect: DOMRect): InspectorRect {
  return {
    height: rect.height,
    left: rect.left,
    top: rect.top,
    width: rect.width,
  };
}

function arrangeRenderedOverlayLabels(overlay: HTMLElement) {
  const labels = Array.from(
    overlay.querySelectorAll<HTMLElement>(".comma-layout-inspector__segment-label")
  );
  for (const label of labels) {
    setLabelShift(label, { x: 0, y: 0 });
  }

  const dimension = overlay.querySelector<HTMLElement>(
    ".comma-layout-inspector__dimension"
  );
  const viewport = {
    height: window.innerHeight,
    left: 0,
    top: 0,
    width: window.innerWidth,
  };

  for (let pass = 0; pass < 8; pass += 1) {
    const shifts = resolveOverlayLabelCollisions({
      items: labels.map((label) => ({
        axis: label.dataset.inspectorAxis === "vertical" ? "vertical" : "horizontal",
        rect: inspectorRect(label.getBoundingClientRect()),
      })),
      obstacles: dimension ? [inspectorRect(dimension.getBoundingClientRect())] : [],
      viewport,
    });
    if (shifts.every((shift) => shift.x === 0 && shift.y === 0)) break;

    for (const [index, label] of labels.entries()) {
      const shift = shifts[index];
      if (!shift) continue;
      setLabelShift(label, {
        x: Number(label.dataset.inspectorShiftX ?? 0) + shift.x,
        y: Number(label.dataset.inspectorShiftY ?? 0) + shift.y,
      });
    }
  }

  updateOverlayLeaderLines(overlay, labels);
}

function setLabelShift(label: HTMLElement, shift: { x: number; y: number }) {
  label.style.setProperty("--comma-layout-label-shift-x", `${shift.x}px`);
  label.style.setProperty("--comma-layout-label-shift-y", `${shift.y}px`);
  label.dataset.inspectorShiftX = String(shift.x);
  label.dataset.inspectorShiftY = String(shift.y);
}

function updateOverlayLeaderLines(
  overlay: HTMLElement,
  labels: readonly HTMLElement[]
) {
  const segments = Array.from(
    overlay.querySelectorAll<HTMLElement>(".comma-layout-inspector__segment")
  );
  const leaders = Array.from(
    overlay.querySelectorAll<SVGGElement>("[data-inspector-leader]")
  );

  for (const [index, leader] of leaders.entries()) {
    const label = labels[index];
    const segment = segments[index];
    const line = leader.querySelector<SVGLineElement>("line");
    const anchorDot = leader.querySelector<SVGCircleElement>("circle");
    if (!label || !segment || !line || !anchorDot) {
      leader.dataset.visible = "false";
      continue;
    }

    const segmentRect = segment.getBoundingClientRect();
    const labelRect = label.getBoundingClientRect();
    const anchor = {
      x: segmentRect.left + segmentRect.width / 2,
      y: segmentRect.top + segmentRect.height / 2,
    };
    const labelEdge = closestPointOnRect(anchor, labelRect);
    const moved =
      Number(label.dataset.inspectorShiftX ?? 0) !== 0 ||
      Number(label.dataset.inspectorShiftY ?? 0) !== 0;
    const detached =
      anchor.x < labelRect.left ||
      anchor.x > labelRect.right ||
      anchor.y < labelRect.top ||
      anchor.y > labelRect.bottom;

    leader.dataset.visible = moved && detached ? "true" : "false";
    line.setAttribute("x1", String(anchor.x));
    line.setAttribute("y1", String(anchor.y));
    line.setAttribute("x2", String(labelEdge.x));
    line.setAttribute("y2", String(labelEdge.y));
    anchorDot.setAttribute("cx", String(anchor.x));
    anchorDot.setAttribute("cy", String(anchor.y));
  }
}

function closestPointOnRect(point: { x: number; y: number }, rect: DOMRect) {
  return {
    x: Math.max(rect.left, Math.min(rect.right, point.x)),
    y: Math.max(rect.top, Math.min(rect.bottom, point.y)),
  };
}

function segmentLabelStyle(rect: InspectorRect): CSSProperties {
  return {
    left: rect.left + rect.width / 2,
    top: rect.top + rect.height / 2,
  };
}

function positionDimensionBadge(rect: InspectorRect) {
  const viewportPadding = 6;
  const badgeHeight = 22;
  const top =
    rect.top >= badgeHeight + viewportPadding
      ? rect.top - badgeHeight - 2
      : Math.min(
          window.innerHeight - badgeHeight - viewportPadding,
          rectBottom(rect) + 2
        );

  return {
    left: Math.max(viewportPadding, Math.min(window.innerWidth - 220, rect.left)),
    top,
  };
}

function rectBottom(rect: InspectorRect) {
  return rect.top + rect.height;
}

function segmentPrefix(kind: OverlaySegment["kind"]) {
  if (kind === "padding") return "p";
  if (kind === "margin") return "m";
  if (kind === "border") return "b";
  return "gap";
}

function formatPixel(value: number) {
  return `${formatNumber(value)}px`;
}

function formatOverlayValue(
  authoredValue: AuthoredLayoutValue | undefined,
  pixels: number,
  mode: LayoutValueDisplayMode
) {
  const pixelValue = formatPixel(pixels);
  const variable = authoredValue?.variables[0];
  if (mode === "pixels" || !variable) return pixelValue;
  return variable;
}

function formatNumber(value: number) {
  const rounded = Math.round(value * 100) / 100;
  return Object.is(rounded, -0) ? "0" : String(rounded);
}

export default LayoutInspector;
