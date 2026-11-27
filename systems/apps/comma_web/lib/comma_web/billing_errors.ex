defmodule CommaWeb.BillingErrors do
  @moduledoc """
  Shared HTTP status and JSON body mapping for billing denials and
  `{:task_model_selection_failed, message}` across Comma HTTP endpoints.
  """

  alias Salix.Bindings.AgentConversations

  @known_reasons ~w(insufficient_credits account_inactive missing_account sandbox_restricted)

  @doc "Allowlisted billing denial reason extracted from a FeeControl decision or reason string."
  @spec billing_reason(term()) :: String.t()
  def billing_reason(%{reason: reason}) when reason in @known_reasons, do: reason
  def billing_reason(%{"reason" => reason}) when reason in @known_reasons, do: reason
  def billing_reason(reason) when reason in @known_reasons, do: reason
  def billing_reason(_decision), do: "billing_unavailable"

  @doc "HTTP status and JSON body for `{:billing_unavailable, decision}`."
  @spec billing_response(term()) :: {402, map()}
  def billing_response(decision) do
    {402, %{error: "billing_unavailable", reason: billing_reason(decision)}}
  end

  @doc "HTTP status and JSON body for `{:task_model_selection_failed, message}`."
  @spec task_model_selection_response(term()) :: {400 | 402 | 429 | 503, map()}
  def task_model_selection_response(message) do
    case AgentConversations.classify_selection_error(message) do
      {:billing_unavailable, reason} ->
        {402, %{error: "billing_unavailable", reason: billing_reason(reason)}}

      :rate_limited ->
        {429, %{error: "rate_limited"}}

      {:bad_request, reason} ->
        {400, %{error: "task_model_selection_failed", reason: reason}}

      :unavailable ->
        {503, %{error: "task_model_selection_failed"}}
    end
  end
end
