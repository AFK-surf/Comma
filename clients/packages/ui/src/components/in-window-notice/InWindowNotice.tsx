import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "../Button";
import { PictureInPictureIcon } from "../icons";

export type InWindowNoticeProps = {
  title: string;
  description: string;
  onShowWindow: () => void;
  onMoveBack: () => void;
  testId?: string | undefined;
};

const compactButton = "h-auto px-md py-xs text-xs";

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
      <PictureInPictureIcon className="size-5 text-fg-quaternary" />
      <p className="text-sm font-semibold text-primary">{title}</p>
      <p className="max-w-(--container-xs) text-sm text-tertiary">{description}</p>
      {/* The buttons are a toolbar's size (Drive's Transfer): the notice stands in a panel, not in a dialog. */}
      <div className="flex flex-wrap justify-center gap-sm pt-xs">
        <Button
          className={compactButton}
          hierarchy="secondary-gray"
          onPress={onShowWindow}
          size="xs"
        >
          {messages.window_show()}
        </Button>
        <Button
          className={compactButton}
          hierarchy="tertiary-gray"
          onPress={onMoveBack}
          size="xs"
        >
          {messages.window_move_back()}
        </Button>
      </div>
    </output>
  );
}
