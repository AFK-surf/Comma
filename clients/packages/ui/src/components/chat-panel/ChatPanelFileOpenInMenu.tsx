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
import { secondaryActionTreatment } from "../toast/styles";
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

export const ChatPanelFileOpenInMenu = ({
  action,
}: {
  action: ChatPanelFileOpenInAction;
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
      <MenuTrigger isOpen={open} onOpenChange={setOpen}>
        <Button
          aria-busy={pending}
          {...(operation === "error" ? { "aria-describedby": feedbackId } : {})}
          className={cx(secondaryActionTreatment, "px-lg")}
          isDisabled={pending}
        >
          {pending ? messages.ui_file_open_in_opening() : messages.ui_file_open_in()}
          <ChevronDownSmallIcon aria-hidden className="size-xl" />
        </Button>
        <MenuPopover
          placement="bottom end"
          className={cx(
            "chat-panel-file-applications w-60 overflow-hidden",
            menuSurfaceClasses
          )}
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
