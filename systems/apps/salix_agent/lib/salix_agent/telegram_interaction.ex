defmodule SalixAgent.TelegramInteraction do
  @moduledoc """
  Source-bound native Telegram prompts. Delivery completes the tool, not the
  human decision. A later response enters the Router as a new provider input.
  """
  @callback request(map(), String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback capabilities(map()) :: map()

  def source?(ctx),
    do: get_in(ctx, [:trusted_origin, "provider"]) == "telegram"

  def request(type, args, ctx) do
    scope = ctx[:terminal_reply_context]
    mod = Application.get_env(:salix_agent, :telegram_interaction_mod)

    unless is_map(scope) and scope["eligible"] == true and ctx[:llm_tool_envelope] == true,
      do:
        raise("Telegram questions must be standalone current-source calls with no running work.")

    unless is_atom(mod) and not is_nil(mod),
      do: raise("Native Telegram interactions are not configured.")

    reservation = SalixAgent.EventArchive.Emit.reserve_egress(ctx, ctx[:session_id])
    result = mod.request(scope, type, args, to_string(ctx[:tool_call_id] || ""))

    SalixAgent.EventArchive.Emit.egress(
      ctx,
      ctx[:session_id],
      %{
        "method" => "telegram.native_question",
        "kind" => type,
        "params" => args,
        "result" => result
      },
      reservation
    )

    case result do
      {:ok, result} ->
        Jason.encode!(result)

      {:error, reason} ->
        raise("Telegram question was not confirmed delivered: #{inspect(reason)}")
    end
  end
end
