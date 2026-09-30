import { LoadingIndicator } from "../LoadingIndicator";
import { useCommaMessages } from "@comma/i18n/react";
import { Button as AriaButton } from "react-aria-components";
import {
  ChevronDownSmallIcon,
  MicrophoneFilledIcon,
  MicrophoneOffFilledIcon,
  LoadingCircleIcon,
} from "../icons";
import { Menu, MenuItem, MenuPopover, MenuSeparator, MenuTrigger } from "../menu";
import { ScrollArea } from "../scroll-area";
import type { MeetingRecorderProps } from "./types";

export function RecorderMicrophone({
  menuPlacement = "bottom start",
  microphone = "off",
  microphoneDevices = [],
  microphoneDeviceId,
  microphonePending,
  microphoneLoading,
  microphoneError,
  onMicrophoneMenuOpen,
  onMicrophoneChange,
  onMenuOpenChange,
  compact,
}: MeetingRecorderProps & {
  compact?: boolean;
  onMenuOpenChange?: (open: boolean) => void;
}) {
  const m = useCommaMessages();
  const selected = microphone === "on" ? (microphoneDeviceId ?? "default") : "off";
  const defaultDevice = microphoneDevices.find((device) => device.isDefault);
  const options = [
    ...microphoneDevices,
    { id: "off", label: m.ui_meeting_recorder_microphone_off() },
  ];
  return (
    <div
      className="comma-recorder-microphone"
      data-recorder-motion="microphone"
      data-recorder-presence=""
      inert={compact}
      aria-hidden={compact || undefined}
    >
      <MenuTrigger
        onOpenChange={(open) => {
          onMenuOpenChange?.(open);
          if (open) onMicrophoneMenuOpen?.();
        }}
      >
        <AriaButton
          aria-label={m.ui_meeting_recorder_choose_microphone()}
          className="comma-recorder-control comma-recorder-mic-trigger"
          isDisabled={microphonePending || !onMicrophoneChange}
        >
          {microphonePending ? (
            <LoadingCircleIcon className="size-4 animate-spin" />
          ) : microphone === "on" ? (
            <MicrophoneFilledIcon className="size-4" />
          ) : (
            <MicrophoneOffFilledIcon className="size-4" />
          )}
          <ChevronDownSmallIcon className="size-3" />
        </AriaButton>
        <MenuPopover
          placement={menuPlacement}
          className="comma-recorder-menu rounded-xl shadow-xs"
        >
          <ScrollArea
            edgeEffect="none"
            className="max-h-[min(320px,70vh)] rounded-xl"
            viewportClassName="max-h-[inherit]"
          >
            <Menu
              aria-label={m.ui_meeting_recorder_choose_microphone()}
              className="w-max min-w-60 max-w-[min(420px,calc(100vw-32px))] shadow-none"
              selectionMode="single"
              selectedKeys={new Set([selected])}
              onAction={(id) => onMicrophoneChange?.(id === "off" ? null : String(id))}
            >
              <MenuItem id="default" selectionIndicator="check">
                {[m.ui_meeting_recorder_default_microphone(), defaultDevice?.label]
                  .filter(Boolean)
                  .join(" — ")}
              </MenuItem>
              <MenuSeparator />
              {options.map((device) => (
                <MenuItem id={device.id} key={device.id} selectionIndicator="check">
                  {device.label}
                </MenuItem>
              ))}
              {(microphoneLoading || microphoneError) && <MenuSeparator />}
              {microphoneLoading && (
                <MenuItem id="loading" isDisabled>
                  <LoadingIndicator
                    label={m.ui_meeting_recorder_microphones_loading()}
                  />
                </MenuItem>
              )}
              {microphoneError && (
                <MenuItem id="error" isDisabled>
                  {microphoneError}
                </MenuItem>
              )}
            </Menu>
          </ScrollArea>
        </MenuPopover>
      </MenuTrigger>
    </div>
  );
}

export function RecorderStopMenu({
  onDiscard,
  onMenuOpenChange,
  compact,
}: Pick<MeetingRecorderProps, "onDiscard"> & {
  compact?: boolean;
  onMenuOpenChange?: (open: boolean) => void;
}) {
  const m = useCommaMessages();
  return (
    <MenuTrigger onOpenChange={(open) => onMenuOpenChange?.(open)}>
      <AriaButton
        aria-label={m.ui_meeting_recorder_stop_options()}
        className="comma-recorder-control comma-recorder-stop-chevron"
        data-recorder-motion="stop-chevron"
        data-recorder-presence=""
        inert={compact}
        aria-hidden={compact || undefined}
        isDisabled={!onDiscard}
      >
        <ChevronDownSmallIcon className="size-4" />
      </AriaButton>
      <MenuPopover placement="bottom end" className="comma-recorder-menu">
        <Menu
          aria-label={m.ui_meeting_recorder_stop_options()}
          className="w-max min-w-44"
        >
          <MenuItem id="discard" tone="destructive" onAction={() => onDiscard?.()}>
            {m.ui_meeting_recorder_discard()}
          </MenuItem>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}
