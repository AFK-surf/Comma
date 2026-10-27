import type { ChatMessage } from "@comma/core/chat";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dropdown } from "@comma/ui/components/dropdown";
import { CircleXIcon } from "@comma/ui/components/icons";
import { useContext } from "react";
import { useTaskRunChoice } from "./TaskRunDialog";
import { TaskRunSwitchContext, type TaskRunSwitch } from "./taskRunSwitch";

/**
 * A Task's model that cannot start, as one card in its chat: why (its computer's words), and, while it still stands,
 * the model to run the Task on instead, switched from the card. Once the Task runs on another model, or its Worker
 * speaks again, the card keeps only what happened.
 */
export function TaskRunBlockedCard({ message }: { message: ChatMessage }) {
  const messages = useCommaMessages();
  const taskRun = useContext(TaskRunSwitchContext);
  const standing =
    taskRun !== undefined && taskRun.blockedMessageId === message.messageId;
  // The computer's own words; a station from before says them only in its message.
  const why = (message.runBlockedError ?? message.text).trim();
  return (
    <div
      className="comma-chat-notice-card comma-task-run-blocked"
      data-message-id={message.messageId}
      data-standing={standing ? "true" : "false"}
      data-testid="task-run-blocked"
      role={standing ? "alert" : undefined}
    >
      <CircleXIcon aria-hidden className="comma-chat-notice-card-icon" />
      <div className="comma-chat-notice-card-content">
        <span className="comma-chat-notice-card-copy">
          {messages.task_run_blocked_title()}
        </span>
        <span className="comma-chat-notice-card-detail">{why}</span>
        {standing ? <TaskRunBlockedChoice taskRun={taskRun} /> : null}
      </div>
    </div>
  );
}

/** Where the Task runs now, and the model to run it on instead, switched in place. */
function TaskRunBlockedChoice({ taskRun }: { taskRun: TaskRunSwitch }) {
  const messages = useCommaMessages();
  const { busy, chosen, error, items, loading, picked, setChosen, switchRun } =
    useTaskRunChoice(taskRun.workspaceId, taskRun.switchRun);
  return (
    <div
      className="comma-task-run-blocked-choice"
      data-testid="task-run-blocked-choice"
    >
      <div className="comma-task-run-blocked-controls">
        <Dropdown
          ariaLabel={messages.task_run_model()}
          className="min-w-0 flex-1"
          disabled={busy}
          items={items}
          loading={loading}
          onChange={setChosen}
          placeholder={messages.task_run_pick()}
          size="sm"
          {...(chosen ? { value: chosen } : {})}
        />
        <Button
          hierarchy="primary"
          isDisabled={!picked || busy}
          onPress={() => switchRun()}
          size="sm"
        >
          {messages.task_run_confirm()}
        </Button>
      </div>
      {error ? (
        <p role="alert" className="text-pretty text-xs text-error-primary">
          {error}
        </p>
      ) : null}
    </div>
  );
}
