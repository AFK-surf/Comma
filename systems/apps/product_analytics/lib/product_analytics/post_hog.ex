defmodule ProductAnalytics.PostHog do
  @moduledoc """
  Sends one batch to a PostHog project through the official SDK's HTTP client,
  without its unbounded cast mailbox. The queue owns admission and retries;
  SDK auto-capture and logger hooks stay disabled.
  """

  @doc "Answers `:ok`, `{:error, :retryable}` or `{:error, :rejected}`; `telemetry` names the batch event."
  def send_batch(events, api_key, host, telemetry) do
    sdk = PostHog.API.Client.client(api_key, host)

    opts =
      [
        json: %{batch: events},
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 5_000]
      ]

    result =
      case sdk.module.request(sdk.client, :post, "/batch/", opts) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} when status == 429 or status >= 500 -> {:error, :retryable}
        {:ok, _} -> {:error, :rejected}
        {:error, _} -> {:error, :retryable}
      end

    SystemsRuntime.Telemetry.execute(
      telemetry,
      %{count: length(events)},
      %{outcome: if(result == :ok, do: "ok", else: "error")}
    )

    result
  rescue
    _ -> {:error, :retryable}
  catch
    _, _ -> {:error, :retryable}
  end
end
