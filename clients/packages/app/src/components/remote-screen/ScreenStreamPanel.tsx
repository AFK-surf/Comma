import { useCommaMessages } from "@comma/i18n/react";
import { Cursor1Icon, MacbookIcon, MediaExpandIcon } from "@comma/ui/components/icons";
import { useRef, useState } from "react";
import {
  ScreenStreamStage,
  useFullscreen,
  type ScreenStreamSource,
  type ScreenStreamTarget,
} from "./ScreenStreamStage";
import { ScreenStreamAction } from "./ScreenStreamWindow";
import type { ScreenStreamState } from "./screenStreamPeer";

/**
 * A computer's screen as a side panel page: the big screen. Here the person
 * may take control, and the page may fill the screen. While the page is not
 * shown (`active` false) it holds no stream.
 */
export function ScreenStreamPanel({
  appName,
  source,
  active,
}: {
  appName: string | undefined;
  source: ScreenStreamSource;
  active: boolean;
}) {
  const messages = useCommaMessages();
  const [target, setTarget] = useState<ScreenStreamTarget>("app");
  const [control, setControl] = useState(false);
  const [state, setState] = useState<ScreenStreamState>("connecting");
  const panel = useRef<HTMLDivElement>(null);
  const [full, toggleFull] = useFullscreen(panel, control);
  const title =
    target === "display"
      ? messages.remote_screen_desktop()
      : (appName ?? messages.remote_screen_app());

  return (
    <div
      className="comma-remote-screen-panel"
      data-control={control}
      data-full={full}
      data-state={state}
      data-testid="remote-screen-panel"
      ref={panel}
    >
      {active ? (
        <ScreenStreamStage
          control={control}
          onState={setState}
          source={source}
          state={state}
          target={target}
        />
      ) : null}
      <div className="comma-remote-screen-name">
        <span aria-hidden className="comma-remote-screen-dot" />
        <strong>{title}</strong>
      </div>
      <div className="comma-remote-screen-actions">
        <ScreenStreamAction
          icon={<MacbookIcon aria-hidden />}
          label={messages.remote_screen_desktop()}
          onClick={() => setTarget(target === "app" ? "display" : "app")}
          pressed={target === "display"}
        />
        <ScreenStreamAction
          icon={<Cursor1Icon aria-hidden />}
          label={messages.remote_screen_control()}
          onClick={() => setControl(!control)}
          pressed={control}
        />
        <ScreenStreamAction
          icon={<MediaExpandIcon aria-hidden />}
          label={
            full
              ? messages.remote_screen_exit_fullscreen()
              : messages.remote_screen_fullscreen()
          }
          onClick={toggleFull}
          pressed={full}
        />
      </div>
    </div>
  );
}
