defmodule SalixIM.Ports.LarkSuiteTriageEvaluator do
  @moduledoc """
  The model call of Feishu and Lark group triage (`SalixIM.LarkSuiteTriage`).

  `request` holds the batch: `provider`, `chat_name`, `in_thread`,
  `target_message_id`, `messages` (`sender_name`, `text`, `sent_at_ms`),
  `allowed_emoji` and `silence_reasons`. `identity` is the batch's archive
  identity (`tenant_id`, `agent_id`, `session_id`, `round_id`), which the
  implementation passes to `SalixAgent.LLM.complete/4`.

  The answer is one decision: `%{"kind" => "silence", "reason_code" => _}`,
  `%{"kind" => "reaction", "emoji_type" => _}`, `%{"kind" => "reply",
  "text" => _}` or `%{"kind" => "delegate", "task_title" => _,
  "task_prompt" => _}`. The caller validates it.
  """

  @callback evaluate(request :: map(), identity :: map()) :: {:ok, map()} | {:error, term()}
end
