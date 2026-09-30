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
