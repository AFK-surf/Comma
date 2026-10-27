import { useId, useState, type ReactNode } from "react";
import { Button } from "../Button";
import { Collapse, CollapseContent } from "../collapse";
import { LoadingIndicator } from "../LoadingIndicator";
import {
  ChevronDownSmallIcon,
  CircleCheckIcon,
  CircleInfoIcon,
  DevicesIcon,
  HelpCircleIcon,
} from "../icons";

/** Setup uses the same compact type, surfaces and controls as device settings. */
export function DeviceSetupStatus({
  title,
  description,
  pending = false,
  tone = "neutral",
}: {
  title: string;
  description?: string;
  pending?: boolean;
  tone?: "neutral" | "success" | "warning";
}) {
  const Icon =
    tone === "success"
      ? CircleCheckIcon
      : tone === "warning"
        ? CircleInfoIcon
        : DevicesIcon;
  return (
    <div className="comma-device-setup-status" data-tone={tone}>
      <span className="comma-device-setup-status__icon" aria-hidden>
        <Icon className="size-6" />
      </span>
      <div className="comma-device-setup-status__copy">
        <p className="comma-device-setup-status__title">{title}</p>
        {description && (
          <p className="comma-device-setup-status__description">{description}</p>
        )}
      </div>
      {pending && <LoadingIndicator label={title} />}
    </div>
  );
}

export function DeviceSetupHelp({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const id = useId();
  return (
    <Collapse open={open} onOpenChange={setOpen}>
      <Button
        hierarchy="tertiary-gray"
        size="sm"
        className="comma-device-setup-help__trigger"
        iconLeading={<HelpCircleIcon />}
        iconTrailing={<ChevronDownSmallIcon />}
        aria-expanded={open}
        aria-controls={id}
        onPress={() => setOpen(!open)}
      >
        {title}
      </Button>
      <CollapseContent id={id} className="comma-device-setup-help__content">
        {children}
      </CollapseContent>
    </Collapse>
  );
}
