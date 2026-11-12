import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "../Button";
import { WindowAppIcon } from "../icons";

export type InWindowNoticeProps = {
  title: string;
  description: string;
  onShowWindow: () => void;
  onMoveBack: () => void;
  testId?: string | undefined;
};

/** What a panel shows in place of what it moved to a window of its own: an app, a computer's screen. */
export function InWindowNotice({
  title,
  description,
  onShowWindow,
  onMoveBack,
  testId,
}: InWindowNoticeProps) {
  const messages = useCommaMessages();
  return (
    <output
      className="flex flex-1 flex-col items-center justify-center gap-sm px-xl py-3xl text-center"
      data-testid={testId}
    >
      <WindowAppIcon className="size-5 text-fg-quaternary" />
      <p className="text-sm font-semibold text-primary">{title}</p>
      <p className="max-w-(--container-xs) text-sm text-tertiary">{description}</p>
      <div className="flex flex-wrap justify-center gap-sm">
        <Button hierarchy="secondary-gray" onPress={onShowWindow} size="sm">
          {messages.window_show()}
        </Button>
        <Button hierarchy="tertiary-gray" onPress={onMoveBack} size="sm">
          {messages.window_move_back()}
        </Button>
      </div>
    </output>
  );
}
