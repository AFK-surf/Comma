export type WorkbenchControlStatus =
  | "ready"
  | "needs-capability"
  | "planned"
  | "disabled";

export type WorkbenchControlKind = "button" | "monitor" | "json";

export interface WorkbenchControlBase {
  id: string;
  label: string;
  kind: WorkbenchControlKind;
  status: WorkbenchControlStatus;
  evidenceLabel: string;
}

export type WorkbenchControlDescriptor =
  | (WorkbenchControlBase & {
      kind: "button";
      action?: (() => Promise<unknown> | unknown) | undefined;
    })
  | (WorkbenchControlBase & {
      kind: "monitor" | "json";
      value: unknown;
    });

export function isControlInteractive({ status }: { status: WorkbenchControlStatus }) {
  return status === "ready";
}
