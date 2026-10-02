import { useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  CloudCheckIcon,
  CloudOffIcon,
  cx,
  FolderOpenIcon,
  HistoryIcon,
  menuSurfaceClasses,
  Toggle,
} from "@comma/ui";
import { useState } from "react";
import {
  Button as AriaButton,
  Dialog as AriaDialog,
  DialogTrigger,
  Popover as AriaPopover,
} from "react-aria-components";
import { driveSecondaryButton } from "./driveButtonStyles";

/**
 * Local sync, from the toolbar: a pill that says whether this Mac mirrors
 * anything, opening a small panel with the one switch, where the mirror
 * lives (and a way to open it), and what sync has done so far. The panel is
 * a popover, not a dialog: it is glanced at and dismissed, never confirmed.
 * It is not `isNonModal`: that variant closes on blur, so pressing the pill
 * again closed the panel and the same press reopened it.
 */
export function DriveSyncPanel({
  enabled,
  localRoot,
  onEnabledChange,
  onOpenHistory,
  onOpenLocally,
}: {
  enabled: boolean;
  localRoot: string;
  /** Turning on hands off to the folder picker; turning off applies at once. */
  onEnabledChange: (enabled: boolean) => void;
  /** The history is a table in its own dialog, so the panel steps out of the way. */
  onOpenHistory: () => void;
  onOpenLocally: () => void;
}) {
  const messages = useCommaMessages();
  const [open, setOpen] = useState(false);

  return (
    <DialogTrigger isOpen={open} onOpenChange={setOpen}>
      {/* On is a settled state, not an activity: a checked cloud in the
          success tone, label included, so the pill reads as "this is fine"
          at a glance rather than as something in progress. */}
      <AriaButton
        className={cx(
          driveSecondaryButton,
          "text-xs",
          enabled && "text-fg-success-primary"
        )}
        data-sync-enabled={enabled ? "true" : "false"}
        data-testid="drive-sync-trigger"
      >
        {enabled ? (
          <CloudCheckIcon className="size-4 text-fg-success-primary" />
        ) : (
          <CloudOffIcon className="size-4 text-quaternary" />
        )}
        <span className="px-xxs whitespace-nowrap">
          {enabled ? messages.drive_sync_on() : messages.drive_sync_off()}
        </span>
      </AriaButton>
      <AriaPopover
        className="motion-reduce:animate-none"
        offset={4}
        placement="bottom start"
      >
        <AriaDialog
          aria-label={messages.drive_sync_panel_title()}
          className={cx(
            menuSurfaceClasses,
            "flex w-[420px] flex-col gap-lg bg-popup-secondary p-xl shadow-2xl outline-none"
          )}
          data-testid="drive-sync-panel"
        >
          {/* Title and its sentence read as one block: no gap between them,
              the line heights already separate the two lines. */}
          <div className="flex flex-col">
            <h3 className="m-0 text-md font-semibold text-primary">
              {messages.drive_sync_panel_title()}
            </h3>
            {/* `pretty` keeps the last line from being a single word. */}
            <p className="m-0 text-xs text-pretty text-quaternary">
              {messages.drive_sync_panel_description()}
            </p>
          </div>
          <div className="flex items-center gap-lg rounded-md bg-quaternary px-lg py-md">
            <span className="comma-icon-slot flex size-2xl shrink-0 items-center justify-center text-quaternary [&_svg]:size-full">
              {enabled ? <CloudCheckIcon /> : <CloudOffIcon />}
            </span>
            <span className="flex min-w-0 flex-1 flex-col">
              <span className="text-sm font-medium text-primary">
                {enabled
                  ? messages.drive_sync_switch_on_title()
                  : messages.drive_sync_switch_off_title()}
              </span>
              <span className="text-xs text-quaternary">
                {enabled
                  ? messages.drive_sync_switch_on_description()
                  : messages.drive_sync_switch_off_description()}
              </span>
            </span>
            <Toggle
              aria-label={messages.drive_sync_panel_title()}
              checked={enabled}
              onChange={(event) => {
                setOpen(false);
                onEnabledChange(event.target.checked);
              }}
              size="sm"
            />
          </div>
          <div className="flex items-center gap-lg px-lg">
            <span className="comma-icon-slot flex size-2xl shrink-0 items-center justify-center text-quaternary [&_svg]:size-full">
              <FolderOpenIcon />
            </span>
            <span className="flex min-w-0 flex-1 flex-col">
              <span className="text-sm font-medium text-primary">
                {messages.drive_sync_location_title()}
              </span>
              <span className="truncate font-mono text-xs text-quaternary">
                {localRoot}
              </span>
            </span>
            <Button
              data-testid="drive-sync-open-locally"
              hierarchy="secondary-gray"
              onPress={onOpenLocally}
              size="xs"
            >
              {messages.drive_sync_location_open()}
            </Button>
          </div>
          <div className="flex items-center gap-lg px-lg">
            <span className="comma-icon-slot flex size-2xl shrink-0 items-center justify-center text-quaternary [&_svg]:size-full">
              <HistoryIcon />
            </span>
            <span className="min-w-0 flex-1 text-sm font-medium text-primary">
              {messages.drive_sync_history_title()}
            </span>
            <Button
              data-testid="drive-sync-history-view"
              hierarchy="secondary-gray"
              onPress={() => {
                setOpen(false);
                onOpenHistory();
              }}
              size="xs"
            >
              {messages.drive_sync_history_view()}
            </Button>
          </div>
        </AriaDialog>
      </AriaPopover>
    </DialogTrigger>
  );
}
