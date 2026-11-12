import type { ScreenQuality } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { usePointerPressFeedback } from "@comma/ui/components/chat-panel/usePointerPressFeedback";
import {
  ChevronDownSmallIcon,
  MacbookIcon,
  MediaExpandIcon,
  VolumeOffIcon,
  VolumeUpIcon,
} from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { Tooltip, type TooltipPlacement } from "@comma/ui/components/tooltip";
import type { ReactNode } from "react";
import { Focusable } from "react-aria-components";
import { SCREEN_QUALITY_CHOICES, type ScreenQualityChoice } from "./screenQuality";
import type { ScreenStreamTarget } from "./ScreenStreamStage";

/** The screen's name: on the picture, or over `line`, how it stands, in the panel's toolbar. */
export function ScreenStreamName({
  title,
  count,
  line,
  detail,
}: {
  title: string;
  /** What stands under the name; none while there is nothing to say. */
  line?: string | undefined;
  /** The line in full, as its tip: with how the screen is reached. */
  detail?: string | undefined;
  /** How many screens are in its deck, when it is in one. */
  count?: number | undefined;
}) {
  if (line !== undefined) {
    return (
      <div className="comma-remote-screen-title">
        <strong title={title}>{title}</strong>
        {line ? (
          <div className="comma-remote-screen-line" title={detail ?? line}>
            <span>{line}</span>
          </div>
        ) : null}
      </div>
    );
  }
  return (
    <div className="comma-remote-screen-name">
      <span aria-hidden className="comma-remote-screen-dot" />
      <strong>{title}</strong>
      {count !== undefined && count > 1 ? (
        <span className="comma-remote-screen-count">1/{count}</span>
      ) : null}
    </div>
  );
}

/**
 * One icon button: round glass on the picture, and in one of the panel's bars that bar's control (styles.css).
 * `pressed` makes it a toggle. Its name is its tooltip.
 */
export function ScreenStreamAction({
  icon,
  label,
  onClick,
  pressed,
  disabled,
  placement = "top",
  shortcut,
  attention,
}: {
  icon: ReactNode;
  label: string;
  onClick(): void;
  pressed?: boolean | undefined;
  disabled?: boolean | undefined;
  placement?: TooltipPlacement | undefined;
  /** The keys that do the same, for its tooltip. */
  shortcut?: readonly string[] | undefined;
  /** It is what the person was just pointed to. */
  attention?: boolean | undefined;
}) {
  // The press answers the pointer alone: a key press gets no motion.
  const press = usePointerPressFeedback<HTMLButtonElement>();
  const button = (
    <button
      aria-label={label}
      aria-pressed={pressed}
      className="comma-remote-screen-action"
      data-attention={attention || undefined}
      disabled={disabled}
      onClick={onClick}
      type="button"
      {...press}
    >
      {icon}
    </button>
  );
  return (
    <Tooltip content={label} placement={placement} {...(shortcut ? { shortcut } : {})}>
      <Focusable isDisabled={disabled ?? false}>{button}</Focusable>
    </Tooltip>
  );
}

/**
 * Watch or Control to choose from on the stage, beside a simulator: a capsule that comes when there is a choice to make
 * and goes when there is none (`shown`). It stays in the page meanwhile, so it goes the way it came; while it is away
 * nothing in it takes a press or the focus.
 */
export function ScreenControlChoice({
  shown,
  control,
  canControl,
  attention,
  onChoose,
}: {
  shown: boolean;
  /** The view drives the device now. */
  control: boolean;
  canControl: boolean;
  /** Control is what the person was just pointed to. */
  attention?: boolean | undefined;
  onChoose(control: boolean): void;
}) {
  const messages = useCommaMessages();
  return (
    <fieldset
      aria-label={messages.remote_screen_control()}
      className="comma-remote-screen-choice"
      data-shown={shown}
      data-testid="remote-screen-choice"
      inert={!shown}
    >
      {[
        [false, messages.remote_screen_watch()] as const,
        [true, messages.remote_screen_control()] as const,
      ].map(([value, label]) => (
        <Button
          aria-pressed={control === value}
          className={control === value ? "bg-sidebar-bg-item" : ""}
          data-attention={(value && attention) || undefined}
          disabled={value && !canControl}
          hierarchy="tertiary-gray"
          key={label}
          onPress={() => onChoose(value)}
          size="xs"
        >
          {label}
        </Button>
      ))}
    </fieldset>
  );
}

/** Shows the whole desktop instead of the app, and back. */
export function ScreenStreamTargetAction({
  target,
  onToggle,
  placement,
}: {
  target: ScreenStreamTarget;
  onToggle(): void;
  placement?: TooltipPlacement | undefined;
}) {
  const messages = useCommaMessages();
  return (
    <ScreenStreamAction
      icon={<MacbookIcon aria-hidden />}
      label={messages.remote_screen_desktop()}
      onClick={onToggle}
      placement={placement}
      pressed={target === "display"}
    />
  );
}

/** Fills the screen, and back. */
export function ScreenStreamFullscreenAction({
  full,
  onToggle,
  placement,
}: {
  full: boolean;
  onToggle(): void;
  placement?: TooltipPlacement | undefined;
}) {
  const messages = useCommaMessages();
  return (
    <ScreenStreamAction
      icon={<MediaExpandIcon aria-hidden />}
      label={
        full
          ? messages.remote_screen_exit_fullscreen()
          : messages.remote_screen_fullscreen()
      }
      onClick={onToggle}
      placement={placement}
      pressed={full}
    />
  );
}

/** The computer's sound muted here, and back (still.fail's 控制中心 声音; muted, the computer sends none). */
export function ScreenStreamMuteAction({
  muted,
  onToggle,
  placement,
}: {
  muted: boolean;
  onToggle(): void;
  placement?: TooltipPlacement | undefined;
}) {
  const messages = useCommaMessages();
  return (
    <ScreenStreamAction
      icon={muted ? <VolumeOffIcon aria-hidden /> : <VolumeUpIcon aria-hidden />}
      label={muted ? messages.remote_screen_unmute() : messages.remote_screen_mute()}
      onClick={onToggle}
      placement={placement}
      pressed={muted}
    />
  );
}

/**
 * 画质: 自动, 流畅, 高清 or 原画, the one chosen checked, each with what it asks beside it (still.fail's 控制中心 画质,
 * apps/mbui sfpages/screen_panel.mbt). A choice opens the view anew at it.
 */
export function ScreenQualityMenu({
  quality,
  onChoose,
}: {
  quality: ScreenQuality | undefined;
  onChoose(quality: ScreenQuality | undefined): void;
}) {
  const messages = useCommaMessages();
  const now: ScreenQualityChoice = quality ?? "auto";
  const name = (choice: ScreenQualityChoice) =>
    ({
      auto: messages.remote_screen_quality_auto(),
      smooth: messages.remote_screen_quality_smooth(),
      hd: messages.remote_screen_quality_hd(),
      original: messages.remote_screen_quality_original(),
    })[choice];
  const hint = (choice: ScreenQualityChoice) =>
    ({
      auto: messages.remote_screen_quality_hint_auto(),
      smooth: messages.remote_screen_quality_hint_smooth(),
      hd: messages.remote_screen_quality_hint_hd(),
      original: messages.remote_screen_quality_hint_original(),
    })[choice];
  return (
    <MenuTrigger>
      <Tooltip
        content={`${messages.remote_screen_quality()}: ${name(now)}`}
        placement="bottom"
      >
        <Button
          aria-label={`${messages.remote_screen_quality()}: ${name(now)}`}
          className="comma-remote-screen-bar-button"
          data-testid="remote-screen-quality"
          hierarchy="tertiary-gray"
          iconTrailing={<ChevronDownSmallIcon aria-hidden />}
          size="xs"
        >
          {name(now)}
        </Button>
      </Tooltip>
      <MenuPopover placement="bottom end">
        <Menu
          aria-label={messages.remote_screen_quality()}
          disallowEmptySelection
          onSelectionChange={(keys) => {
            if (keys === "all") return;
            const [key] = Array.from(keys);
            if (key === undefined || key === now) return;
            onChoose(key === "auto" ? undefined : (key as ScreenQuality));
          }}
          selectedKeys={[now]}
          selectionMode="single"
        >
          {SCREEN_QUALITY_CHOICES.map((choice) => (
            <MenuItem
              id={choice}
              key={choice}
              note={hint(choice)}
              selectionIndicator="check"
              textValue={name(choice)}
            >
              {name(choice)}
            </MenuItem>
          ))}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}
