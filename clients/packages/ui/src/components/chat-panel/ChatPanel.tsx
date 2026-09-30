import type { ReactNode } from "react";
import { AiInput, type AiInputProps } from "../ai-input";
import { Avatar } from "../avatar";
import { Button } from "../Button";
import {
  ChevronDownIcon,
  FileIcon,
  MoreHorizontalIcon,
  PanelLeftIcon,
  PanelRightIcon,
  SparklesIcon,
} from "../icons";
import { ScrollArea } from "../scroll-area";
import { cx } from "../utils";
import {
  ChatPanelImageGroup,
  type ChatPanelImageGroupImage,
} from "./ChatPanelImageGroup";

export interface ChatPanelAttachment {
  id: string;
  label: string;
  testId?: string;
}

export interface ChatPanelMessage {
  id: string;
  kind?: "user" | "assistant" | "tool" | "permission";
  content: ReactNode;
  author?: ReactNode;
  authorAvatar?: ReactNode;
  actionsTestId?: string;
  description?: ReactNode;
  attachments?: ChatPanelAttachment[];
  /** Uploaded images shown above the bubble; files stay in `attachments`. */
  images?: ChatPanelImageGroupImage[];
  footer?: ReactNode;
  imageSrc?: string;
  imageAlt?: string;
  copyLabel?: string;
  onCopy?: () => void;
  timestamp?: string;
  timestampIso?: string;
  timestampTestId?: string;
}

export interface ChatPanelMessageItemProps {
  message: ChatPanelMessage;
  variant?: "conversation" | "task";
  className?: string;
  testId?: string;
}

export interface ChatPanelProps {
  title?: string;
  subtitle?: string;
  messages?: ChatPanelMessage[];
  aiInputProps?: AiInputProps;
  className?: string;
}

const defaultMessages: ChatPanelMessage[] = [
  {
    id: "user",
    kind: "user",
    content:
      "Using the attached screenshot as a reference, please do a full pass on the Settings UI and fix the alignment inconsistencies.",
    attachments: [
      { id: "openai-1", label: "Openai.pdf" },
      { id: "openai-2", label: "Openai.pdf" },
    ],
  },
  {
    id: "thinking",
    kind: "tool",
    content: "Thinking",
  },
  {
    id: "assistant",
    kind: "assistant",
    content:
      "I'm doing another round of read-only inspection, first checking the current high-risk rebound points. Not deleting anything yet.",
    timestamp: "Jun 10 at 6:00 PM",
  },
  {
    id: "permission",
    kind: "permission",
    content: "Authorize Comma Computer Use",
    description: "Authorize Comma Computer Use",
  },
];

const Header = ({ title, subtitle }: { title: string; subtitle: string }) => (
  <header className="flex h-12 w-full shrink-0 items-center justify-between border-b-[0.5px] border-primary px-2xl py-md">
    <div className="flex min-w-0 flex-1 items-center gap-xs py-xxs">
      <p className="min-w-0 truncate text-sm font-medium leading-5 tracking-[-0.14px] text-ai-input-header-text-primary">
        {title}
      </p>
      <div className="flex min-w-16 items-center gap-md text-sm leading-5 tracking-[-0.14px]">
        <PanelLeftIcon className="size-5 shrink-0 text-ai-input-header-icon-primary" />
        <span className="min-w-0 truncate text-ai-input-header-text-secondary">
          {subtitle}
        </span>
        <button
          aria-label="More options"
          className="inline-flex size-7 shrink-0 items-center justify-center rounded-sm p-xs text-ai-input-header-icon-primary transition-colors hover:bg-sidebar-bg-item"
          type="button"
        >
          <MoreHorizontalIcon className="size-5" />
        </button>
      </div>
    </div>
    <button
      aria-label="Toggle chat panel"
      className="inline-flex size-7 shrink-0 items-center justify-center rounded-sm p-xs text-ai-input-header-icon-primary transition-colors hover:bg-sidebar-bg-item"
      type="button"
    >
      <PanelRightIcon className="size-5" />
    </button>
  </header>
);

export const ChatPanelAttachmentPill = ({
  attachment,
}: {
  attachment: ChatPanelAttachment;
}) => (
  <span
    className="inline-flex items-center gap-sm rounded-md border-[0.5px] border-primary bg-popup-secondary py-sm pl-sm pr-lg text-xs leading-[18px] text-ai-input-panel-text-attachment-primary"
    data-testid={attachment.testId}
  >
    <span
      aria-hidden
      className="inline-flex size-6 shrink-0 items-center justify-center rounded-xs bg-panel-bg-file"
      data-slot="file-icon-surface"
    >
      <FileIcon className="size-[18px]" />
    </span>
    <span className="max-w-40 truncate">{attachment.label}</span>
  </span>
);

const AttachmentRow = ({
  attachments,
}: {
  attachments: ChatPanelAttachment[] | undefined;
}) =>
  attachments && attachments.length > 0 ? (
    <div className="flex max-w-[540px] flex-wrap justify-end gap-md">
      {attachments.map((attachment) => (
        <ChatPanelAttachmentPill key={attachment.id} attachment={attachment} />
      ))}
    </div>
  ) : null;

const UserMessage = ({
  message,
  variant,
}: {
  message: ChatPanelMessage;
  variant: "conversation" | "task";
}) => (
  <div
    className={cx(
      "flex w-full flex-col gap-md",
      variant === "conversation" ? "items-end" : "items-stretch"
    )}
  >
    {variant === "conversation" && message.images && message.images.length > 0 ? (
      <ChatPanelImageGroup images={message.images} />
    ) : null}
    {variant === "conversation" ? (
      <AttachmentRow attachments={message.attachments} />
    ) : null}
    {message.imageSrc ? (
      <div
        className={cx(
          "size-[72px] overflow-hidden rounded-md border-[0.75px] border-primary",
          variant === "task" && "ml-lg"
        )}
      >
        <img
          alt={message.imageAlt ?? "Attachment preview"}
          className="size-full object-cover"
          src={message.imageSrc}
        />
      </div>
    ) : null}
    <div
      className={cx(
        "text-sm leading-5 text-markdown-text-primary",
        variant === "conversation"
          ? "max-w-[450px] rounded-xl bg-markdown-bg-message px-lg py-md"
          : "rounded-xl border-[0.5px] border-primary bg-popup-secondary p-lg shadow-xs"
      )}
      data-slot={
        variant === "conversation" ? "chat-panel-user-bubble" : "task-chat-user-message"
      }
    >
      {variant === "task" ? (
        <>
          <div className="flex h-6 min-w-0 items-center gap-xs">
            {message.authorAvatar ?? (
              <Avatar
                name={typeof message.author === "string" ? message.author : "You"}
                size="xs"
              />
            )}
            {message.author ? (
              <span className="min-w-0 truncate text-sm font-medium text-primary">
                {message.author}
              </span>
            ) : null}
          </div>
          <div className="mt-md whitespace-pre-wrap">{message.content}</div>
          {message.attachments?.length ? (
            <div className="mt-md flex flex-wrap gap-md">
              {message.attachments.map((attachment) => (
                <ChatPanelAttachmentPill attachment={attachment} key={attachment.id} />
              ))}
            </div>
          ) : null}
        </>
      ) : (
        message.content
      )}
    </div>
    {message.footer}
  </div>
);

const ToolMessage = ({ message }: { message: ChatPanelMessage }) => (
  <div className="flex w-full flex-col items-start text-sm leading-5 text-markdown-text-tool-primary">
    <div className="flex items-center gap-xs">
      <span>{message.content}</span>
      <ChevronDownIcon className="size-5" />
    </div>
  </div>
);

const AssistantMessage = ({
  message,
  variant,
}: {
  message: ChatPanelMessage;
  variant: "conversation" | "task";
}) => (
  <div className="flex w-full flex-col items-start gap-md">
    {variant === "task" && message.author ? (
      <div className="flex h-6 min-w-0 items-center gap-xs">
        {message.authorAvatar ?? (
          <SparklesIcon className="size-6 shrink-0 text-fg-brand-primary" />
        )}
        <span className="min-w-0 truncate text-sm font-medium text-primary">
          {message.author}
        </span>
      </div>
    ) : null}
    {variant === "task" && message.description ? (
      <div className="text-sm leading-5 text-quaternary">{message.description}</div>
    ) : null}
    <div
      className="w-full text-sm leading-5 text-markdown-text-primary"
      data-slot="chat-panel-assistant-content"
    >
      {message.content}
    </div>
    {message.footer}
    {(message.timestamp || message.onCopy) && (
      <div
        className="flex items-center gap-md text-markdown-icon-primary opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100"
        data-testid={message.actionsTestId}
      >
        <button
          aria-label={message.copyLabel ?? "Copy response"}
          className="inline-flex size-7 items-center justify-center rounded-sm bg-markdown-bg-icon-hover p-xs"
          onClick={message.onCopy}
          title={message.copyLabel ?? "Copy response"}
          type="button"
        >
          <FileIcon className="size-5" />
        </button>
        <time
          className="text-md leading-6 tracking-[-0.16px] text-markdown-text-primary"
          data-testid={message.timestampTestId}
          dateTime={message.timestampIso}
        >
          {message.timestamp}
        </time>
      </div>
    )}
  </div>
);

const PermissionMessage = ({ message }: { message: ChatPanelMessage }) => (
  <div className="flex w-full items-start gap-lg rounded-xl border-[0.5px] border-primary bg-popup-secondary p-lg shadow-xs">
    <SparklesIcon className="size-6 shrink-0 text-markdown-icon-primary" />
    <div className="flex min-w-0 flex-1 flex-col gap-md">
      <div className="flex flex-col gap-xxs text-sm leading-5">
        <p className="text-markdown-text-primary">{message.content}</p>
        {message.description ? (
          <p className="tracking-[-0.14px] text-ai-input-header-text-secondary">
            {message.description}
          </p>
        ) : null}
      </div>
      <div className="flex gap-2">
        <Button size="sm">Approve</Button>
        <Button hierarchy="secondary-gray" size="sm">
          Reject
        </Button>
      </div>
    </div>
  </div>
);

export const ChatPanelMessageItem = ({
  message,
  variant = "conversation",
  className,
  testId,
}: ChatPanelMessageItemProps) => {
  let content: ReactNode;
  if (message.kind === "user") {
    content = <UserMessage message={message} variant={variant} />;
  } else if (message.kind === "tool") {
    content = <ToolMessage message={message} />;
  } else if (message.kind === "permission") {
    content = <PermissionMessage message={message} />;
  } else {
    content = <AssistantMessage message={message} variant={variant} />;
  }

  return (
    <article
      className={cx("w-full", className)}
      data-kind={message.kind ?? "assistant"}
      data-slot="chat-panel-message"
      data-testid={testId}
      data-variant={variant}
    >
      {content}
    </article>
  );
};

export const ChatPanel = ({
  title = "Summarize recent updates of OpenAI",
  subtitle = "Mac mini",
  messages = defaultMessages,
  aiInputProps,
  className,
}: ChatPanelProps) => (
  <section
    className={cx(
      "flex size-full min-h-0 flex-col overflow-hidden rounded-2xl border-[0.5px] border-primary bg-main-panel-bg shadow-sm",
      className
    )}
  >
    <Header subtitle={subtitle} title={title} />
    <div className="flex min-h-0 flex-1 flex-col items-center pb-xl">
      <div
        className="min-h-0 w-full max-w-[calc(744px+var(--spacing-md))] flex-1"
        data-slot="chat-panel-message-scroll"
      >
        <ScrollArea
          className="size-full"
          contentClassName="flex min-h-full flex-col gap-2xl px-xs pb-xl pt-3xl"
          edgeEffect="none"
          orientation="vertical"
        >
          {messages.map((message) => (
            <ChatPanelMessageItem key={message.id} message={message} />
          ))}
        </ScrollArea>
      </div>
      <div className="w-full max-w-[744px] shrink-0 px-0">
        <AiInput {...aiInputProps} />
      </div>
    </div>
  </section>
);
