import { useEffect, useId, useRef, useState } from "react";
import { Button, MenuTrigger } from "react-aria-components";
import { useCommaMessages } from "@comma/i18n/react";
import { ChevronDownSmallIcon, FileTextIcon } from "../icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  menuSurfaceClasses,
} from "../menu";
import { ScrollArea } from "../scroll-area";
import { secondaryActionFrame, secondaryActionTreatment } from "../toast/styles";
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

export const ChatPanelFileOpenInMenu = ({
  action,
  presentation = "menu",
}: {
  action: ChatPanelFileOpenInAction;
  /** Only the active preview preloads its first application; message cards stay lazy. */
  presentation?: "menu" | "split";
}) => {
  const messages = useCommaMessages();
  const feedbackId = useId();
  const applicationDescriptionId = useId();
  const [open, setOpen] = useState(false);
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
    setOpen(false);
    setOperation("idle");
    return () => {
      operationRef.current?.abort();
      operationRef.current = null;
    };
  }, [action]);

  const discover = presentation === "split" || open;
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
    setOpen(false);
    setOperation("pending");
    // Dismissal leaves the selected operation running; preview discovery stays
    // with its active owner.
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

  const pending = operation === "pending";
  const firstApplication = list.status === "ready" ? list.applications[0] : undefined;
  const split = presentation === "split";
  const primaryDescription = [
    firstApplication ? applicationDescriptionId : "",
    operation === "error" ? feedbackId : "",
  ]
    .filter(Boolean)
    .join(" ");
  return (
    <div className="chat-panel-file-open-in">
      <div
        className={
          split
            ? cx(secondaryActionFrame, "chat-panel-file-open-control gap-xxs text-xs")
            : undefined
        }
      >
        {split ? (
          <Button
            aria-label={messages.ui_file_open()}
            aria-busy={pending}
            {...(primaryDescription ? { "aria-describedby": primaryDescription } : {})}
            className="chat-panel-file-open-primary"
            isDisabled={pending || !firstApplication}
            onPress={() => {
              if (firstApplication)
                run((signal) => action.openApplication(firstApplication.id, signal));
            }}
          >
            {firstApplication ? (
              firstApplication.iconDataUrl ? (
                <img
                  alt=""
                  className="size-4 object-contain"
                  src={firstApplication.iconDataUrl}
                />
              ) : (
                <FileTextIcon aria-hidden className="size-4" />
              )
            ) : null}
            <span className="pl-xxs whitespace-nowrap">
              {pending ? messages.ui_file_open_in_opening() : messages.ui_file_open()}
            </span>
          </Button>
        ) : null}
        <MenuTrigger isOpen={open} onOpenChange={setOpen}>
          <Button
            {...(split ? { "aria-label": messages.ui_file_choose_application() } : {})}
            aria-busy={pending}
            {...(operation === "error" ? { "aria-describedby": feedbackId } : {})}
            className={
              split
                ? "chat-panel-file-open-chevron"
                : cx(secondaryActionTreatment, "px-lg")
            }
            isDisabled={pending}
          >
            {!split &&
              (pending
                ? messages.ui_file_open_in_opening()
                : messages.ui_file_open_in())}
            <ChevronDownSmallIcon aria-hidden className="size-xl" />
          </Button>
          {/* Long application lists scroll inside the popover's own
              viewport-derived max-height instead of running off the window. */}
          <MenuPopover
            placement="bottom end"
            className={cx(
              "chat-panel-file-applications w-60 overflow-hidden",
              menuSurfaceClasses
            )}
          >
            <ScrollArea className="max-h-[inherit]" viewportClassName="max-h-[inherit]">
              <Menu
                aria-label={messages.ui_file_open_in()}
                className="py-sm"
                variant="embedded"
              >
                {list.status === "loading" ? (
                  <MenuItem id="loading" key="loading" isDisabled>
                    {messages.ui_file_open_in_loading()}
                  </MenuItem>
                ) : list.status === "error" ? (
                  <>
                    <MenuItem id="error" key="error" isDisabled>
                      {messages.ui_file_open_in_failed()}
                    </MenuItem>
                    <MenuItem
                      id="retry"
                      key="retry"
                      onAction={() => setAttempt((value) => value + 1)}
                      shouldCloseOnSelect={false}
                    >
                      {messages.ui_file_download_retry()}
                    </MenuItem>
                  </>
                ) : list.applications.length === 0 ? (
                  <MenuItem id="empty" key="empty" isDisabled>
                    {messages.ui_file_open_in_unavailable()}
                  </MenuItem>
                ) : (
                  list.applications.map((application) => (
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
                      onAction={() =>
                        run((signal) => action.openApplication(application.id, signal))
                      }
                      textValue={application.name}
                    >
                      {application.name}
                    </MenuItem>
                  ))
                )}
                {action.reveal ? (
                  <>
                    <MenuSeparator />
                    <MenuItem
                      id="reveal"
                      key="reveal"
                      onAction={() => run(action.reveal!.run)}
                    >
                      {split ? messages.ui_file_open_in_folder() : action.reveal.label}
                    </MenuItem>
                  </>
                ) : null}
              </Menu>
            </ScrollArea>
          </MenuPopover>
        </MenuTrigger>
      </div>
      {split && firstApplication ? (
        <span className="sr-only" id={applicationDescriptionId}>
          {messages.ui_file_open_with({ application: firstApplication.name })}
        </span>
      ) : null}
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
