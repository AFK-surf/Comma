import type { ChatTaskRun } from "@comma/core/chat";
import type { useCommaMessages } from "@comma/i18n/react";

type CommaMessages = ReturnType<typeof useCommaMessages>;

const RUNTIME_NAMES: Record<string, string> = { claude: "Claude Code", codex: "Codex" };

/**
 * A Task's place and model in reader words ("Mac Studio · Claude Sonnet"):
 * what names a Task's Worker instead of the Agent that runs the Task.
 */
export function taskRunLabel(messages: CommaMessages, run: ChatTaskRun): string {
  const place = taskRunPlace(messages, run.place);
  const model = taskRunModel(messages, run.model);
  return model ? messages.task_panel_run({ place, model }) : place;
}

/** Where a Task runs: Comma, a Cloud VM, a coding sandbox (with its repository), or the computer's own name. */
export function taskRunPlace(
  messages: CommaMessages,
  place: ChatTaskRun["place"]
): string {
  switch (place.kind) {
    case "salix":
      return messages.task_panel_run_place_comma();
    case "cloud_vm":
      return messages.task_panel_run_place_cloud_vm();
    case "sandbox":
      return messages.task_panel_run_place_sandbox({
        repo: `${place.repo.owner}/${place.repo.name}`,
      });
    default:
      return place.name || messages.task_panel_run_place_computer();
  }
}

/** The model a Task runs on; absent when the run names none. */
export function taskRunModel(
  messages: CommaMessages,
  model: ChatTaskRun["model"]
): string | undefined {
  switch (model?.kind) {
    case "platform":
      return messages.task_panel_run_model_platform();
    case "catalog":
      return model.name;
    case "runtime": {
      if (model.name) return model.name;
      if (!model.provider) return undefined;
      return messages.task_panel_run_model_runtime_default({
        runtime: RUNTIME_NAMES[model.provider] ?? model.provider,
      });
    }
    default:
      return undefined;
  }
}
