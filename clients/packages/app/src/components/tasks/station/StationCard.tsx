import { useCommaMessages } from "@comma/i18n/react";
import { Badge } from "@comma/ui/components/Badge";
import { Button } from "@comma/ui/components/Button";
import { cx } from "@comma/ui/components/utils";
import { useState, type FormEvent } from "react";
/** Where a card stands: waiting, or resolved (answered, closed, replaced or withdrawn) and how, in words. */
export interface StationCardDecision {
  resolved: boolean;
  dismissed?: boolean;
  text?: string;
}

/** What a card asks to be answered with: options to pick, or a field to write in. */
export interface StationCardAsk {
  type: string;
  options?: { label: string; detail?: string; recommended?: boolean }[];
  placeholder?: string;
}

export interface StationCardProps {
  card: StationCardAsk;
  /** Who decides it, in words. */
  assignee?: string | undefined;
  /** Where the card stands; absent before the core has said (treated as waiting). */
  decision?: StationCardDecision | undefined;
  /** Picks an option (`decision.answer`): a reply, or a close the agent offered. */
  onAnswer: (option: string) => Promise<unknown>;
  /** Answers a text card (`decision.reply`). */
  onReply: (text: string) => Promise<unknown>;
  className?: string;
}

/**
 * What an agent's post asks people to answer it with: options to pick (the
 * recommended one last, as the core orders them) or a field to write in.
 * Once answered, closed, replaced or withdrawn, it shows how it ended in the
 * core's words and takes no more answers. A card type the app does not know
 * is answered by writing in the chat.
 */
export function StationCard({
  assignee,
  card,
  className,
  decision,
  onAnswer,
  onReply,
}: StationCardProps) {
  const messages = useCommaMessages();
  const [pending, setPending] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [text, setText] = useState("");
  const waiting = !decision?.resolved;

  const run = async (key: string, action: () => Promise<unknown>) => {
    setPending(key);
    setFailure(null);
    try {
      await action();
      if (key === "reply") setText("");
    } catch (error) {
      setFailure(error instanceof Error ? error.message : String(error));
    } finally {
      setPending(null);
    }
  };

  const submitReply = (event: FormEvent) => {
    event.preventDefault();
    const value = text.trim();
    if (!value || pending) return;
    void run("reply", () => onReply(value));
  };

  const resolvedText = decision?.text
    ? decision.text
    : messages.stations_card_no_longer_waiting();

  return (
    <div
      className={cx(
        "flex w-full flex-col gap-md rounded-xl border-[0.5px] border-primary bg-popup-secondary p-lg shadow-xs",
        !waiting && "opacity-80",
        className
      )}
      data-card-state={waiting ? "waiting" : "resolved"}
      data-testid="station-card"
    >
      <div className="flex min-w-0 items-center gap-sm text-xs leading-[18px] text-tertiary">
        {assignee ? <span className="min-w-0 truncate">{assignee}</span> : null}
        {waiting && decision?.dismissed ? (
          <span className="shrink-0">· {messages.stations_card_dismissed()}</span>
        ) : null}
      </div>
      {waiting && card.type === "options" ? (
        <fieldset className="m-0 flex flex-col gap-sm border-0 p-0">
          <legend className="sr-only">{messages.stations_card_options()}</legend>
          {(card.options ?? []).map((option) => (
            <Button
              className="h-auto justify-start whitespace-normal py-sm text-left"
              hierarchy={option.recommended ? "primary" : "secondary-gray"}
              isDisabled={pending !== null}
              key={option.label}
              onPress={() => void run(option.label, () => onAnswer(option.label))}
              size="sm"
            >
              <span className="flex min-w-0 flex-col items-start gap-xxs">
                <span className="flex items-center gap-sm">
                  <span>{option.label}</span>
                  {option.recommended ? (
                    <Badge color="brand" size="sm">
                      {messages.stations_card_recommended()}
                    </Badge>
                  ) : null}
                </span>
                {option.detail ? (
                  <span className="text-xs font-normal opacity-80">
                    {option.detail}
                  </span>
                ) : null}
              </span>
            </Button>
          ))}
        </fieldset>
      ) : null}
      {waiting && card.type === "text" ? (
        <form className="flex items-end gap-sm" onSubmit={submitReply}>
          <textarea
            aria-label={messages.stations_card_reply_label()}
            className="min-h-9 min-w-0 flex-1 resize-y rounded-md border border-primary bg-main-panel-bg px-md py-sm text-sm text-primary outline-none focus-visible:shadow-focus-brand-shadow-xs"
            disabled={pending !== null}
            onChange={(event) => setText(event.target.value)}
            placeholder={card.placeholder ?? messages.stations_card_reply_placeholder()}
            rows={2}
            value={text}
          />
          <Button
            hierarchy="primary"
            isDisabled={pending !== null || text.trim() === ""}
            size="sm"
            type="submit"
          >
            {messages.stations_card_reply_send()}
          </Button>
        </form>
      ) : null}
      {waiting && card.type !== "options" && card.type !== "text" ? (
        <p className="m-0 text-sm text-secondary">
          {messages.stations_card_answer_in_chat()}
        </p>
      ) : null}
      {!waiting ? (
        <p className="m-0 text-sm text-secondary" data-testid="station-card-outcome">
          {resolvedText}
        </p>
      ) : null}
      {failure ? (
        <p className="m-0 text-xs text-error-primary" role="alert">
          {failure}
        </p>
      ) : null}
    </div>
  );
}
