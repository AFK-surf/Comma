defmodule Comma.Analytics.PostHog do
  @moduledoc false

  # Use the official SDK's public HTTP client without its unbounded cast mailbox.
  # Worker owns admission and retries; SDK auto-capture and logger hooks stay disabled.
  def send_batch(events) do
    config = Comma.Analytics.config()
    sdk = PostHog.API.Client.client(config[:api_key], config[:host])

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
      [:comma_product, :analytics, :batch],
      %{count: length(events)},
      %{
        outcome: if(result == :ok, do: "ok", else: "error")
      }
    )

    result
  rescue
    _ -> {:error, :retryable}
  catch
    _, _ -> {:error, :retryable}
  end
end
