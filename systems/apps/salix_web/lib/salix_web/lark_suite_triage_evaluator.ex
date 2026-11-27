defmodule SalixWeb.LarkSuiteTriageEvaluator do
  @moduledoc """
  The release's `SalixIM.Ports.LarkSuiteTriageEvaluator`: one call to the
  Router's analyze model (`SalixAgent.AnalyzeLLM`, the main model when none is
  set) through `SalixAgent.LLM.complete/4`, with the batch's archive identity,
  billed as system work of the Router.
  """

  @behaviour SalixIM.Ports.LarkSuiteTriageEvaluator

  alias SalixAgent.LLM

  @max_tokens 800

  @system_prompt """
  You watch a Feishu or Lark group chat for your team. People there did not
  address you. Read the newest messages in "messages" and choose exactly one action:

  - "silence": add nothing. Use it unless you are sure you help. Give
    "reason_code": one of the silence reasons in the input.
  - "reaction": acknowledge the newest message with one emoji. Give
    "emoji_type": one of the allowed emoji in the input.
  - "reply": answer in the newest message's thread, briefly, in the
    language of the chat. Give "text". Reply only with a useful, correct
    addition that nobody has already given.
  - "delegate": the request needs investigation that takes more than one
    message. Give "task_title" (short) and "task_prompt" (what to find out
    and for whom).

  If "recent_context" is present, it contains earlier messages from the same
  chat or thread for background reference only: do not respond to messages in
  "recent_context" directly, and decide strictly for the newest messages in
  "messages". If "team_context" is present, use it to judge whether the topic
  fits your team's responsibilities.

  Never repeat what someone already answered. Answer with one JSON object and
  nothing else, for example {"kind":"silence","reason_code":"ambient_chatter"}.
  """

  @impl true
  def evaluate(request, identity, opts \\ []) when is_map(request) and is_map(identity) do
    identity = Map.take(identity, [:tenant_id, :agent_id, :session_id, :round_id])
    resolver = Keyword.get(opts, :analyze_llm, SalixAgent.AnalyzeLLM)

    with {:ok, llm_opts} <- resolver.resolve(identity.agent_id) do
      messages = [
        %{role: "system", content: @system_prompt},
        %{role: "user", content: Jason.encode!(request)}
      ]

      case LLM.complete(messages, [], opts(llm_opts, identity), identity) do
        {:final, text} -> decision(text)
        {:final, text, _trace} -> decision(text)
        {:final, text, _provider, _trace} -> decision(text)
        {:assistant, text, _calls} -> decision(text)
        {:assistant, text, _calls, _meta} -> decision(text)
        {:assistant, text, _calls, _meta, _trace} -> decision(text)
        {:error, _meta} -> {:error, :model_failed}
        _other -> {:error, :unexpected_model_result}
      end
    else
      _error -> {:error, :model_unavailable}
    end
  end

  # System work of the Router, metered under its own entrypoint.
  defp opts(llm_opts, identity) when is_map(llm_opts) do
    llm_opts
    |> Map.put_new("max_tokens", @max_tokens)
    |> Map.put("billing_context", billing(identity))
    |> Map.put("entrypoint", "lark_suite_triage")
    |> Map.put("actor_type", "system")
  end

  defp opts(llm_opts, identity) when is_list(llm_opts) do
    llm_opts
    |> Keyword.put_new(:max_tokens, @max_tokens)
    |> Keyword.put(:billing_context, billing(identity))
    |> Keyword.put(:entrypoint, "lark_suite_triage")
    |> Keyword.put(:actor_type, "system")
  end

  defp billing(identity),
    do: %{"salix_tenant_id" => identity.tenant_id, "salix_agent_id" => identity.agent_id}

  @doc false
  # The first JSON object of the model's text.
  def decision(text) when is_binary(text) do
    with [json] <- Regex.run(~r/\{.*\}/s, text),
         {:ok, %{} = decision} <- Jason.decode(json) do
      {:ok, decision}
    else
      _invalid -> {:error, :invalid_model_answer}
    end
  end

  def decision(_text), do: {:error, :invalid_model_answer}
end
