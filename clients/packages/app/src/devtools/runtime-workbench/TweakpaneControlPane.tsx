import { useEffect, useMemo, useRef } from "react";
import { Pane } from "tweakpane";
import {
  isControlInteractive,
  type WorkbenchControlDescriptor,
} from "./control-descriptors";

interface PaneLike {
  addBinding(
    object: Record<string, unknown>,
    key: string,
    options?: Record<string, unknown>
  ): unknown;
  addButton(options: Record<string, unknown>): {
    on?: (event: string, cb: () => void) => void;
  };
  dispose?: () => void;
}

export function TweakpaneControlPane({
  controls,
}: {
  controls: readonly WorkbenchControlDescriptor[];
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const flatControls = useMemo(() => flattenControls(controls), [controls]);

  useEffect(() => {
    if (!containerRef.current) {
      return undefined;
    }

    const pane = new Pane({ container: containerRef.current }) as unknown as PaneLike;
    for (const control of controls) {
      mountControl(pane, control);
    }

    return () => {
      pane.dispose?.();
    };
  }, [controls]);

  return (
    <div
      className="comma-workbench-pane"
      data-testid="runtime-workbench-tweakpane"
      ref={containerRef}
    >
      <div className="sr-only" aria-label="Control statuses">
        {flatControls.map((control) => (
          <span data-control-status={control.status} key={control.id}>
            {control.label}
          </span>
        ))}
      </div>
    </div>
  );
}

function mountControl(pane: PaneLike, control: WorkbenchControlDescriptor) {
  if (control.kind === "button") {
    const button = pane.addButton({
      disabled: !isControlInteractive(control),
      title: control.label,
    });

    if (control.action) {
      button.on?.("click", () => {
        void control.action?.();
      });
    }
    return;
  }

  if (control.kind === "monitor" || control.kind === "json") {
    pane.addBinding({ value: JSON.stringify(control.value) }, "value", {
      disabled: true,
      label: control.label,
      readonly: true,
    });
  }
}

function flattenControls(
  controls: readonly WorkbenchControlDescriptor[]
): WorkbenchControlDescriptor[] {
  return [...controls];
}
