import { useEffect, useId, useRef, useState } from "react";
import { Button, MenuTrigger } from "react-aria-components";
import { useCommaMessages } from "@comma/i18n/react";
import { ChevronDownSmallIcon, FileTextIcon } from "../icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  menuSelectionRowHeight,
  menuSurfaceClasses,
} from "../menu";
import { secondaryActionTreatment } from "../toast/styles";
import { Tooltip } from "../tooltip";
import { spacing } from "../../tokens";
import { cx } from "../utils";

export interface ChatPanelFileApplication {
  id: string;
  name: string;
  iconDataUrl?: string;
  isDefault?: boolean;
}

/** Application-owned actions for one immutable file source. */
export interface ChatPanelFileOpenInAction {
  listApplications: (
    signal?: AbortSignal
  ) => Promise<readonly ChatPanelFileApplication[]>;
  openApplication: (applicationId: string, signal?: AbortSignal) => Promise<void>;
  reveal?: {
    label: string;
    run: (signal?: AbortSignal) => Promise<void>;
  };
}

type ApplicationList =
  | { status: "loading" }
  | { status: "error" }
  | { status: "ready"; applications: readonly ChatPanelFileApplication[] };

/**
 * The applications that open a file, found while `discover` holds, and the one
 * operation run on them. A new source drops the old one's list and cancels its
 * operation; dismissing a menu leaves a chosen operation running.
 */
export function useChatPanelFileOpenIn(
  action: ChatPanelFileOpenInAction,
  discover: boolean
) {
  const [attempt, setAttempt] = useState(0);
  const [loaded, setLoaded] = useState<{
    owner: ChatPanelFileOpenInAction;
    list: ApplicationList;
  }>();
  const list: ApplicationList =
    loaded?.owner === action ? loaded.list : { status: "loading" };
  const [operation, setOperation] = useState<"idle" | "pending" | "error">("idle");
  const operationRef = useRef<AbortController | null>(null);

  useEffect(() => {
    setOperation("idle");
    return () => {
      operationRef.current?.abort();
      operationRef.current = null;
    };
  }, [action]);

  useEffect(() => {
    if (!discover) return;
    const controller = new AbortController();
    setLoaded({ owner: action, list: { status: "loading" } });
    void Promise.resolve()
      .then(() => action.listApplications(controller.signal))
      .then(
        (applications) => {
          if (!controller.signal.aborted)
            setLoaded({ owner: action, list: { status: "ready", applications } });
        },
        () => {
          if (!controller.signal.aborted)
            setLoaded({ owner: action, list: { status: "error" } });
        }
      );
    return () => controller.abort();
  }, [action, attempt, discover]);

  const run = (execute: (signal?: AbortSignal) => Promise<void>) => {
    if (operationRef.current) return;
    const controller = new AbortController();
    operationRef.current = controller;
    setOperation("pending");
    void Promise.resolve()
      .then(() => {
        if (!controller.signal.aborted) return execute(controller.signal);
      })
      .then(
        () => {
          if (!controller.signal.aborted) setOperation("idle");
        },
        () => {
          if (!controller.signal.aborted) setOperation("error");
        }
      )
      .finally(() => {
        if (operationRef.current === controller) operationRef.current = null;
      });
  };

  return {
    list,
    operation,
    run,
    retry: () => setAttempt((value) => value + 1),
  };
}

/** The application choices of an Open in list, with its loading, failure and empty states. */
export function ChatPanelFileApplicationItems({
  action,
  openIn,
}: {
  action: ChatPanelFileOpenInAction;
  openIn: ReturnType<typeof useChatPanelFileOpenIn>;
}) {
  const messages = useCommaMessages();
  const { list, run, retry } = openIn;
  if (list.status === "loading")
    return (
      <MenuItem id="loading" key="loading" isDisabled>
        {messages.ui_file_open_in_loading()}
      </MenuItem>
    );
  if (list.status === "error")
    return (
      <>
        <MenuItem id="error" key="error" isDisabled>
          {messages.ui_file_open_in_failed()}
        </MenuItem>
        <MenuItem id="retry" key="retry" onAction={retry} shouldCloseOnSelect={false}>
          {messages.ui_file_download_retry()}
        </MenuItem>
      </>
    );
  if (list.applications.length === 0)
    return (
      <MenuItem id="empty" key="empty" isDisabled>
        {messages.ui_file_open_in_unavailable()}
      </MenuItem>
    );
  return list.applications.map((application) => (
    <MenuItem
      id={application.id}
      key={application.id}
      icon={
        application.iconDataUrl ? (
          <img
            alt=""
            className="chat-panel-file-app-icon"
            src={application.iconDataUrl}
          />
        ) : (
          <FileTextIcon />
        )
      }
      onAction={() => run((signal) => action.openApplication(application.id, signal))}
      textValue={application.name}
    >
      {application.name}
    </MenuItem>
  ));
}

/**
 * How tall a list of applications is before it scrolls: nine rows and half of the next, which shows that the list
 * goes on. A desktop can have dozens of applications that open one kind of file; the list is not as tall as the
 * window for them.
 */
export const fileApplicationsMaxHeight = spacing.sm + menuSelectionRowHeight * 9.5;

// One control in two zones. It has the frame of the Open in button (`secondaryActionFrame`); each zone answers the
// pointer by itself, and the frame shows the keyboard's focus for the zone that has it. The focus class is the one
// the app already has for a frame of buttons: a second `:has()` utility of the same shadow is joined with it into
// one rule that every element of the page is checked against (`transcript-style-budget.spec.ts`).
const splitFrame =
  "inline-flex shrink-0 items-stretch overflow-hidden rounded-md border border-button-secondary-border " +
  "bg-button-secondary-bg text-sm font-medium text-button-secondary-fg shadow-xs " +
  "has-[>button:focus-visible]:shadow-focus-gray-shadow-xs";
const splitZone =
  "inline-flex items-center justify-center py-xs transition-colors hover:bg-secondary " +
  "focus:outline-none focus-visible:bg-secondary";

export const ChatPanelFileOpenInMenu = ({
  action,
  primary,
}: {
  action: ChatPanelFileOpenInAction;
  /**
   * What the control does by itself, where Open in is the other ways to do it. With it the control is one button
   * in two zones: its words do this, and its chevron opens the menu.
   */
  primary?: { label: string; name: string; onPress: () => void } | undefined;
}) => {
  const messages = useCommaMessages();
  const feedbackId = useId();
  const [open, setOpen] = useState(false);
  useEffect(() => setOpen(false), [action]);
  const openIn = useChatPanelFileOpenIn(action, open);
  const { operation } = openIn;
  const pending = operation === "pending";
  return (
    <div className="chat-panel-file-open-in">
      <div className={primary ? splitFrame : "contents"}>
        {primary ? (
          <Button
            aria-label={primary.name}
            className={cx(splitZone, "px-lg")}
            // A zone is part of the frame: the press scale would shrink it inside the frame.
            data-no-press-feedback
            onPress={primary.onPress}
          >
            {primary.label}
          </Button>
        ) : null}
        <MenuTrigger isOpen={open} onOpenChange={setOpen}>
          {primary ? (
            <Tooltip content={messages.ui_file_open_in()} placement="top">
              <Button
                aria-busy={pending}
                aria-label={messages.ui_file_open_in()}
                {...(operation === "error" ? { "aria-describedby": feedbackId } : {})}
                className={cx(
                  splitZone,
                  "border-l border-button-secondary-border px-sm disabled:text-disabled"
                )}
                data-no-press-feedback
                isDisabled={pending}
              >
                <ChevronDownSmallIcon aria-hidden className="size-xl" />
              </Button>
            </Tooltip>
          ) : (
            <Button
              aria-busy={pending}
              {...(operation === "error" ? { "aria-describedby": feedbackId } : {})}
              className={cx(secondaryActionTreatment, "px-lg")}
              isDisabled={pending}
            >
              {pending
                ? messages.ui_file_open_in_opening()
                : messages.ui_file_open_in()}
              <ChevronDownSmallIcon aria-hidden className="size-xl" />
            </Button>
          )}
          <MenuPopover
            placement="bottom end"
            className={cx(
              "chat-panel-file-applications w-60 overflow-hidden",
              menuSurfaceClasses
            )}
            maxHeight={fileApplicationsMaxHeight}
          >
            <Menu
              aria-label={messages.ui_file_open_in()}
              className="py-sm"
              variant="embedded"
            >
              <ChatPanelFileApplicationItems action={action} openIn={openIn} />
              {action.reveal ? (
                <>
                  <MenuSeparator />
                  <MenuItem
                    id="reveal"
                    key="reveal"
                    onAction={() => openIn.run(action.reveal!.run)}
                  >
                    {action.reveal.label}
                  </MenuItem>
                </>
              ) : null}
            </Menu>
          </MenuPopover>
        </MenuTrigger>
      </div>
      <output
        aria-live="polite"
        className={operation === "error" ? "chat-panel-file-action-error" : "sr-only"}
        id={feedbackId}
      >
        {operation === "error"
          ? messages.ui_file_open_failed()
          : pending
            ? messages.ui_file_open_in_opening()
            : ""}
      </output>
    </div>
  );
};
