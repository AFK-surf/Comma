import type { ChatTaskRun } from "@comma/core/chat";
import type { useCommaMessages } from "@comma/i18n/react";

type CommaMessages = ReturnType<typeof useCommaMessages>;

const RUNTIME_NAMES: Record<string, string> = { claude: "Claude Code", codex: "Codex" };

/**
 * A Task's place and model in reader words ("on Mac Studio · Claude Sonnet"):
 * what Task panels show instead of the Agent that runs the Task.
 */
export function taskRunLabel(messages: CommaMessages, run: ChatTaskRun): string {
  const place =
    run.place.kind === "salix"
      ? messages.task_panel_run_place_comma()
      : run.place.kind === "cloud_vm"
        ? messages.task_panel_run_place_cloud_vm()
        : run.place.name || messages.task_panel_run_place_computer();
  const model = taskRunModel(messages, run.model);
  return model
    ? messages.task_panel_run({ place, model })
    : messages.task_panel_run_place_only({ place });
}

function taskRunModel(
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
