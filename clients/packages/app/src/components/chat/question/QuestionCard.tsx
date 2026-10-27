import type {
  ChatMessagePart,
  ChatQuestionChoice,
  ChatQuestionPart,
  ChatQuestionState,
} from "@comma/chat-contract";
import type { AttachmentUploadInput, DraftAttachment } from "@comma/core/chat";
import { useCommaMessages } from "@comma/i18n/react";
import { Badge } from "@comma/ui/components/Badge";
import { Button } from "@comma/ui/components/Button";
import {
  ChoiceList,
  ChoiceListIndicator,
  ChoiceListRow,
} from "@comma/ui/components/choice-list";
import {
  ChatBubbleIcon,
  CheckIcon,
  ChevronDoubleRightIcon,
  ImageIcon,
  LoadingCircleIcon,
  ReloadIcon,
  XIcon,
} from "@comma/ui/components/icons";
import { cx } from "@comma/ui/components/utils";
import {
  memo,
  useContext,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ClipboardEvent,
  type DragEvent,
  type FormEvent,
  type KeyboardEvent,
} from "react";
import { isGroupImagePreviewPath } from "@comma/core/chat";
import {
  isLocalFilePreviewRef,
  useLocalFilePreviews,
} from "../thread/attachments/useLocalFilePreviews";
import {
  QuestionCardActionsContext,
  QuestionCardAttachmentsContext,
  type QuestionCardActions,
} from "./QuestionCardContext";
import "../agent-card/agent-card.css";
import "./question-card.css";

const NO_ATTACHMENTS: readonly DraftAttachment[] = [];

/**
 * An Agent's question, drawn as a card under the message that asks it. While it is open the person picks, writes
 * their own answer (with images) or skips; whatever they send closes it into a one-line receipt, and so does a
 * message they write in the chat instead. Changes are instant: no transition on picking, sending or closing.
 */
export const QuestionCard = memo(function QuestionCard({
  part,
  live,
}: {
  part: ChatQuestionPart;
  live: boolean;
}) {
  const actions = useContext(QuestionCardActionsContext);
  const open = part.state.status === "open" || part.state.status === "failed";
  if (open && live && actions) return <QuestionForm actions={actions} part={part} />;
  return <QuestionReceipt part={part} />;
});

/**
 * The question cards a message asks, after its text. They sit outside the Markdown renderer, whose element resets
 * would otherwise restyle the card's buttons and fields.
 */
export const MessageQuestionCards = memo(function MessageQuestionCards({
  message,
}: {
  message: { parts?: readonly ChatMessagePart[] | undefined };
}) {
  const questions = (message.parts ?? []).filter(
    (part): part is ChatQuestionPart => part.kind === "question"
  );
  if (questions.length === 0) return null;
  return (
    <>
      {questions.map((part) => (
        <QuestionCard key={part.messageId} live part={part} />
      ))}
    </>
  );
});

function QuestionForm({
  actions,
  part,
}: {
  actions: QuestionCardActions;
  part: ChatQuestionPart;
}) {
  const messages = useCommaMessages();
  const id = useId();
  const promptId = `${id}-prompt`;
  const otherId = `${id}-other`;
  const formRef = useRef<HTMLFormElement>(null);
  const otherRef = useRef<HTMLTextAreaElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const attachments =
    useContext(QuestionCardAttachmentsContext)[part.messageId] ?? NO_ATTACHMENTS;
  const multiple = part.multiSelect;
  const failed = part.state.status === "failed";
  const recommended = part.choices.find((choice) => choice.recommended)?.id;

  const [picks, setPicks] = useState<string[]>(() =>
    failed
      ? (part.state.choiceIds ?? [])
      : multiple || !recommended
        ? []
        : [recommended]
  );
  const [other, setOther] = useState(() => (failed ? (part.state.other ?? "") : ""));
  const [otherOn, setOtherOn] = useState(
    () => failed && part.state.other !== undefined
  );
  const [keys, setKeys] = useState(false);
  const [note, setNote] = useState("");
  const [waitingForUploads, setWaitingForUploads] = useState(false);
  const lastPick = useRef<string | undefined>(recommended);

  const hasOther = other.trim() !== "" || attachments.length > 0;
  const uploading = attachments.some((attachment) => attachment.status === "uploading");
  const uploadFailed = attachments.some((attachment) => attachment.status === "failed");

  // Typing or adding an image picks the other answer; emptying it gives the pick back.
  const followOther = (has: boolean) => {
    if (has === otherOn) return;
    setOtherOn(has);
    if (multiple) return;
    if (has) setPicks([]);
    else if (lastPick.current) setPicks([lastPick.current]);
  };

  useEffect(() => {
    if (attachments.length > 0 && !otherOn) followOther(true);
    // Only a change in the images moves the pick.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [attachments.length]);

  const choose = (next: string[]) => {
    setNote("");
    if (!multiple) {
      lastPick.current = next[0];
      setOtherOn(false);
    }
    setPicks(next);
  };

  const submit = () => {
    if (!multiple && picks.length === 0 && !(otherOn && hasOther)) {
      setNote(
        otherOn
          ? messages.chat_question_other_empty()
          : messages.chat_question_pick_one()
      );
      (otherOn ? otherRef.current : firstInput(formRef.current))?.focus();
      return;
    }
    if (multiple && picks.length === 0 && !(otherOn && hasOther)) {
      setNote(messages.chat_question_pick_any());
      firstInput(formRef.current)?.focus();
      return;
    }
    if (otherOn && uploadFailed) {
      setNote(messages.chat_upload_failed());
      return;
    }
    if (otherOn && uploading) {
      setNote(messages.chat_question_wait_upload());
      setWaitingForUploads(true);
      return;
    }
    setNote("");
    void actions
      .answer({
        questionMessageId: part.messageId,
        choiceIds: picks,
        ...(otherOn ? { other } : {}),
      })
      .catch(() => undefined);
  };

  // An answer sent while its images upload goes once they have.
  useEffect(() => {
    if (!waitingForUploads || uploading) return;
    setWaitingForUploads(false);
    submit();
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [waitingForUploads, uploading]);

  // A card that opens while the person sits in an empty composer takes the keyboard.
  useEffect(() => {
    const active = document.activeElement;
    const composer = active?.closest(".comma-chat-composer");
    if (composer && !(active?.textContent ?? "").trim()) {
      (checkedInput(formRef.current) ?? firstInput(formRef.current))?.focus();
    }
  }, []);

  const addFiles = (files: File[]) => {
    const images = files.filter((file) => file.type.startsWith("image/"));
    if (images.length === 0) return;
    const inputs: AttachmentUploadInput[] = images.map((file) => ({
      data: file,
      name: file.name || "image.png",
      size: file.size,
    }));
    actions.attach(part.messageId, inputs);
    followOther(true);
  };

  const onPaste = (event: ClipboardEvent<HTMLFormElement>) => {
    const files = Array.from(event.clipboardData.files);
    if (!files.some((file) => file.type.startsWith("image/"))) return;
    const inField = event.target === otherRef.current;
    if (!inField || !event.clipboardData.types.includes("text/plain"))
      event.preventDefault();
    addFiles(files);
    if (!inField) otherRef.current?.focus();
  };

  const onDrop = (event: DragEvent<HTMLFormElement>) => {
    if (!event.dataTransfer.types.includes("Files")) return;
    event.preventDefault();
    // The card's answer takes these files, not the conversation's draft around it.
    event.stopPropagation();
    addFiles(Array.from(event.dataTransfer.files));
    otherRef.current?.focus();
  };

  const onKeyDownCapture = (event: KeyboardEvent<HTMLFormElement>) => {
    if (!keys && event.key !== "Tab" && event.key !== "Shift" && event.key !== "Meta") {
      setKeys(true);
    }
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault();
      submit();
    }
  };

  const onOptionKeyDown = (event: KeyboardEvent<HTMLInputElement>, index: number) => {
    const count = part.choices.length;
    if (
      /^[1-9]$/.test(event.key) &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey
    ) {
      const target = Number(event.key) - 1;
      if (target > count) return;
      event.preventDefault();
      if (target === count) {
        otherRef.current?.focus();
        return;
      }
      const choice = part.choices[target]!;
      inputAt(formRef.current, target)?.focus();
      choose(
        multiple
          ? picks.includes(choice.id)
            ? picks.filter((pick) => pick !== choice.id)
            : part.choices
                .filter((c) => c.id === choice.id || picks.includes(c.id))
                .map((c) => c.id)
          : [choice.id]
      );
      return;
    }
    if (multiple && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
      event.preventDefault();
      const next = index + (event.key === "ArrowDown" ? 1 : -1);
      if (next >= count) otherRef.current?.focus();
      else if (next >= 0) inputAt(formRef.current, next)?.focus();
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      if (!multiple) choose([part.choices[index]!.id]);
      submit();
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      focusComposer(formRef.current);
      return;
    }
    // Typing on a choice goes straight into the other answer, keeping the character.
    if (
      event.key.length === 1 &&
      event.key !== " " &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey
    ) {
      otherRef.current?.focus();
    }
  };

  const onOtherKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault();
      submit();
    } else if (event.key === "Escape") {
      event.preventDefault();
      focusComposer(formRef.current);
    } else if (
      event.key === "ArrowUp" &&
      event.currentTarget.selectionStart === 0 &&
      event.currentTarget.selectionEnd === 0
    ) {
      event.preventDefault();
      const last = part.choices.length - 1;
      inputAt(formRef.current, last)?.focus();
      if (!multiple) choose([part.choices[last]!.id]);
    }
  };

  const options = useMemo(
    () =>
      part.choices.map((choice) => ({
        id: choice.id,
        label: choice.label,
        ...(choice.description ? { description: choice.description } : {}),
        ...(choice.recommended
          ? {
              badge: (
                <Badge color="brand" size="sm">
                  {messages.chat_question_recommended()}
                </Badge>
              ),
            }
          : {}),
      })),
    [part.choices, messages]
  );

  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- the card's own shortcuts (⌘↵, number keys) and the images pasted or dropped on it
    <form
      aria-labelledby={promptId}
      className="comma-agent-card"
      noValidate
      // The card is a drop target of its own: the conversation around it does
      // not show its drop overlay while files are over the card.
      onDragEnter={(event) => {
        if (event.dataTransfer.types.includes("Files")) event.stopPropagation();
      }}
      onDragLeave={(event) => {
        if (event.dataTransfer.types.includes("Files")) event.stopPropagation();
      }}
      onDragOver={(event) => {
        if (!event.dataTransfer.types.includes("Files")) return;
        event.preventDefault();
        event.stopPropagation();
      }}
      onDrop={onDrop}
      onKeyDownCapture={onKeyDownCapture}
      onPaste={onPaste}
      onPointerDown={() => setKeys(false)}
      onSubmit={(event: FormEvent) => {
        event.preventDefault();
        submit();
      }}
      ref={formRef}
    >
      <div className="comma-agent-card-head">
        <p className="comma-agent-card-title" id={promptId}>
          {part.prompt}
        </p>
        {multiple ? (
          <p className="comma-agent-card-meta">{messages.chat_question_multi()}</p>
        ) : null}
      </div>
      <ChoiceList
        className="comma-question-card-list"
        labelledBy={promptId}
        multiple={multiple}
        name={`${id}-pick`}
        onChange={choose}
        onOptionKeyDown={onOptionKeyDown}
        options={options}
        showShortcuts={keys}
        value={picks}
      >
        {part.allowOther ? (
          <ChoiceListRow checked={otherOn}>
            <input
              aria-label={messages.chat_question_other()}
              aria-keyshortcuts={String(part.choices.length + 1)}
              checked={otherOn}
              className="comma-choice-list-input comma-question-card-other-pick"
              name={`${id}-pick`}
              onChange={(event) => {
                if (event.currentTarget.checked && !multiple) setPicks([]);
                setOtherOn(event.currentTarget.checked);
                if (event.currentTarget.checked) otherRef.current?.focus();
              }}
              type={multiple ? "checkbox" : "radio"}
              value="other"
            />
            <ChoiceListIndicator checked={otherOn} multiple={multiple} />
            <label className="comma-question-card-other-label" htmlFor={otherId}>
              {messages.chat_question_other()}
            </label>
            <textarea
              className="comma-question-card-other-field"
              id={otherId}
              onChange={(event) => {
                setNote("");
                setOther(event.currentTarget.value);
                followOther(
                  event.currentTarget.value.trim() !== "" || attachments.length > 0
                );
              }}
              onFocus={() => {
                if (hasOther) followOther(true);
              }}
              onKeyDown={onOtherKeyDown}
              placeholder={messages.chat_question_other_placeholder()}
              ref={otherRef}
              rows={1}
              value={other}
            />
            <Button
              aria-label={messages.chat_question_add_image()}
              className="comma-question-card-attach"
              hierarchy="tertiary-gray"
              iconOnly
              iconLeading={<ImageIcon />}
              onPress={() => fileRef.current?.click()}
              size="xs"
            />
            <input
              accept="image/*"
              className="hidden"
              multiple
              onChange={(event) => {
                addFiles(Array.from(event.currentTarget.files ?? []));
                event.currentTarget.value = "";
                otherRef.current?.focus();
              }}
              ref={fileRef}
              tabIndex={-1}
              type="file"
            />
            <QuestionImages
              actions={actions}
              attachments={attachments}
              questionMessageId={part.messageId}
            />
          </ChoiceListRow>
        ) : null}
      </ChoiceList>
      {failed ? (
        <div className="comma-question-card-error" role="alert">
          <span>{messages.chat_question_failed()}</span>
          <Button hierarchy="secondary-gray" onPress={submit} size="xs">
            {messages.chat_question_retry()}
          </Button>
        </div>
      ) : null}
      <output className="comma-agent-card-note">{note}</output>
      <div className="comma-agent-card-foot">
        <span className="comma-agent-card-hint">
          <kbd>↑</kbd>
          <kbd>↓</kbd> {messages.chat_question_hint_select()}
          <span aria-hidden="true" className="comma-agent-card-hint-sep">
            ·
          </span>
          <kbd>↵</kbd> {messages.chat_question_send()}
        </span>
        <span className="comma-agent-card-actions">
          <Button
            hierarchy="secondary-gray"
            onPress={() => {
              void actions
                .answer({
                  questionMessageId: part.messageId,
                  choiceIds: [],
                  skipped: true,
                })
                .catch(() => undefined);
            }}
            size="xs"
          >
            {messages.chat_question_skip()}
          </Button>
          <Button
            adornmentTrailing={
              <kbd aria-hidden="true" className="comma-question-card-send-key">
                ⌘↵
              </kbd>
            }
            hierarchy="primary"
            size="xs"
            type="submit"
          >
            {messages.chat_question_send()}
          </Button>
        </span>
      </div>
    </form>
  );
}

function QuestionImages({
  actions,
  attachments,
  questionMessageId,
}: {
  actions: QuestionCardActions;
  attachments: readonly DraftAttachment[];
  questionMessageId: string;
}) {
  const messages = useCommaMessages();
  const requests = useMemo(
    () =>
      attachments.flatMap((attachment) => {
        const previewRef = isLocalFilePreviewRef(attachment.id)
          ? attachment.id
          : attachment.path && isGroupImagePreviewPath(attachment.path)
            ? attachment.path
            : undefined;
        return attachment.status === "uploaded" && previewRef
          ? [{ key: attachment.id, previewRef }]
          : [];
      }),
    [attachments]
  );
  const previews = useLocalFilePreviews(requests, actions.previewLocalFile);
  if (attachments.length === 0) return null;
  return (
    <ul className="comma-question-card-images">
      {attachments.map((attachment) => {
        const preview = previews.get(attachment.id);
        return (
          <li
            className="comma-question-card-image"
            data-status={attachment.status}
            key={attachment.id}
          >
            {preview?.status === "ready" ? (
              <img alt={attachment.name} src={preview.url} />
            ) : null}
            {attachment.status === "uploading" ? (
              <output
                aria-busy="true"
                aria-label={messages.chat_question_uploading()}
                className="comma-question-card-image-spinner"
              >
                <LoadingCircleIcon
                  aria-hidden="true"
                  className="motion-safe:animate-spin"
                />
              </output>
            ) : null}
            {attachment.status === "failed" ? (
              <button
                aria-label={messages.chat_question_retry()}
                className="comma-question-card-image-retry"
                onClick={() =>
                  actions.retryAttachment(questionMessageId, attachment.id)
                }
                type="button"
              >
                {messages.chat_question_retry()}
              </button>
            ) : null}
            <button
              aria-label={messages.chat_question_remove_image({
                name: attachment.name,
              })}
              className="comma-question-card-image-remove"
              onClick={() => actions.removeAttachment(questionMessageId, attachment.id)}
              type="button"
            >
              <XIcon aria-hidden="true" />
            </button>
          </li>
        );
      })}
    </ul>
  );
}

function QuestionReceipt({ part }: { part: ChatQuestionPart }) {
  const messages = useCommaMessages();
  const { status } = part.state;
  const given = status === "answered" || status === "sending";
  return (
    <section
      aria-label={part.prompt}
      className="comma-agent-receipt"
      data-status={status}
    >
      <span
        className={cx("comma-agent-receipt-icon", status !== "answered" && "is-muted")}
      >
        {status === "sending" ? (
          <LoadingCircleIcon aria-hidden="true" className="motion-safe:animate-spin" />
        ) : status === "skipped" ? (
          <ChevronDoubleRightIcon aria-hidden="true" />
        ) : status === "replied" ? (
          <ChatBubbleIcon aria-hidden="true" />
        ) : status === "replaced" ? (
          <ReloadIcon aria-hidden="true" />
        ) : (
          <CheckIcon aria-hidden="true" />
        )}
      </span>
      <span className="comma-agent-receipt-text">
        <span className="comma-agent-receipt-prompt">{part.prompt}</span>
        <span className={cx("comma-agent-receipt-answer", !given && "is-muted")}>
          {given
            ? answerLabel(part.choices, part.state)
            : receiptLabel(status, messages)}
          {status === "sending" ? (
            <span className="comma-agent-receipt-note">
              {" "}
              · {messages.chat_question_sending()}
            </span>
          ) : null}
        </span>
      </span>
    </section>
  );
}

function answerLabel(choices: readonly ChatQuestionChoice[], state: ChatQuestionState) {
  const labels = choices
    .filter((choice) => state.choiceIds?.includes(choice.id))
    .map((choice) => choice.label);
  const other = state.other?.trim();
  return [...labels, ...(other ? [other] : [])].join("、");
}

function receiptLabel(
  status: ChatQuestionState["status"],
  messages: ReturnType<typeof useCommaMessages>
) {
  if (status === "skipped") return messages.chat_question_skipped();
  if (status === "replaced") return messages.chat_question_replaced();
  if (status === "replied") return messages.chat_question_replied();
  return "";
}

function inputAt(form: HTMLFormElement | null, index: number) {
  return form?.querySelectorAll<HTMLInputElement>(
    ".comma-choice-list-option > .comma-choice-list-input"
  )[index];
}

function firstInput(form: HTMLFormElement | null) {
  return inputAt(form, 0);
}

function checkedInput(form: HTMLFormElement | null) {
  return (
    form?.querySelector<HTMLInputElement>(".comma-choice-list-input:checked") ??
    undefined
  );
}

/** Back to the composer of the conversation the card is in. */
function focusComposer(from: HTMLElement | null) {
  for (let node = from?.parentElement; node; node = node.parentElement) {
    const composer = node.querySelector<HTMLElement>(
      '.comma-chat-composer [role="textbox"]'
    );
    if (composer) {
      composer.focus();
      return;
    }
  }
}
