defmodule SalixAgent.LLM.Error do
  @moduledoc """
  Structured provider failures returned through the `SalixAgent.LLM` seam.

  Providers must not turn transport or API failures into normal `{:final, text}`
  assistant output. Round drivers record request failures outside the transcript,
  while compaction and recovery code can inspect the actual failure category.
  """

  @preview_bytes 4096

  alias SalixVerifiedKernel.Provider, as: Kernel

  def http(provider, status, body),
    do: Kernel.call(:error, {:http, provider, {status, error_data(body)}})

  def transport(provider, reason),
    do: Kernel.call(:error, {:transport, provider, preview(reason)})

  def context_overflow(provider, details),
    do: Kernel.call(:error, {:context_overflow, provider, preview(details)})

  def refusal(provider, details),
    do: Kernel.call(:error, {:refusal, provider, preview(details)})

  def output_token_limit(provider),
    do: Kernel.call(:error, {:output_token_limit, provider, nil})

  def invalid_tool_arguments(provider),
    do: Kernel.call(:error, {:invalid_tool_arguments, provider, nil})

  def provider_state(provider, state, details),
    do: Kernel.call(:error, {:provider_state, provider, {state, error_data(details)}})

  # Preserve structured codes until classification. The kernel bounds returned diagnostics.
  defp error_data(value) when is_binary(value), do: value
  defp error_data(value) when is_map(value) and not is_struct(value), do: value
  defp error_data(value), do: preview(value)

  @spec user_message(map()) :: String.t()
  def user_message(%{} = meta) do
    case meta["category"] || meta[:category] do
      "transport_error" ->
        "[LLM transport error]"

      "context_overflow" ->
        "[LLM context overflow]"

      _ ->
        case meta["status"] || meta[:status] do
          status when is_integer(status) -> "[LLM error #{status}]"
          _ -> "[LLM provider error]"
        end
    end
  end

  @spec category(term()) :: String.t()
  def category(%{} = meta), do: to_string(meta["category"] || meta[:category] || "unknown")
  def category(_), do: "unknown"

  @spec retryable?(term()) :: boolean()
  def retryable?(%{} = meta), do: (meta["retryable"] || meta[:retryable]) == true
  def retryable?(_), do: false

  # Provider wording for an account that has no balance or quota left. Generic
  # "quota exceeded" and "exceeded your current quota" text is excluded:
  # providers also use it for per-minute rate limits, which recover on retry.
  @provider_quota_markers [
    "insufficient_quota",
    "billing_error",
    "credit balance is too low",
    "insufficient credits",
    "insufficient_credits",
    "insufficient balance",
    "insufficient_balance"
  ]

  @doc """
  Whether a structured HTTP failure says the provider account itself has run
  out of balance or quota, rather than being briefly rate limited.
  """
  @spec provider_quota_exhausted?(term()) :: boolean()
  def provider_quota_exhausted?(%{} = meta) do
    status = meta["status"] || meta[:status]
    body = (meta["body"] || meta[:body] || "") |> to_string() |> String.downcase()

    status == 402 or
      (is_integer(status) and Enum.any?(@provider_quota_markers, &String.contains?(body, &1)))
  end

  def provider_quota_exhausted?(_), do: false

  @doc """
  The failure of a model call paid by the member's own key or subscription
  whose provider account has run out. It stops the input like a Comma credit
  refusal, without retries, and names the provider account as the cause.
  """
  @spec provider_quota(term()) :: term()
  def provider_quota(result), do: exhausted_account_stop(result, "provider_quota_exhausted")

  @doc """
  The failure of a platform-funded model call whose provider account has run
  out. Retries repeat the refusal, and the member can neither top up the
  platform's account nor cover it with Comma credits. The input stops the same
  way, and the cause is reported as `model_unavailable`: the member can choose
  another model or try again later.
  """
  @spec platform_provider_quota(term()) :: term()
  def platform_provider_quota(result), do: exhausted_account_stop(result, "model_unavailable")

  defp exhausted_account_stop({:error, %{} = meta} = error, reason) do
    if provider_quota_exhausted?(meta) do
      {:error,
       Map.merge(meta, %{
         "error_class" => "billing_unavailable",
         "reason" => reason,
         "retryable" => false
       })}
    else
      error
    end
  end

  defp exhausted_account_stop(result, _reason), do: result

  @spec preview(term()) :: String.t()
  def preview(value) when is_binary(value), do: truncate_utf8(value, @preview_bytes)

  def preview(value) do
    value
    |> inspect(limit: 50, printable_limit: @preview_bytes)
    |> truncate_utf8(@preview_bytes)
  end

  defp truncate_utf8(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate_utf8(value, max_bytes) do
    value
    |> binary_part(0, min(byte_size(value), max_bytes))
    |> trim_invalid_utf8()
  end

  defp trim_invalid_utf8(value) do
    cond do
      String.valid?(value) -> value
      byte_size(value) == 0 -> ""
      true -> value |> binary_part(0, byte_size(value) - 1) |> trim_invalid_utf8()
    end
  end
end
