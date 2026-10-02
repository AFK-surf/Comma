defmodule Comma.Notifications.APNs.Transport do
  @moduledoc false

  @finch Comma.Notifications.APNs.Finch
  @timeout 5_000

  # Mint retains its normal CA store, hostname verification and SNI. This
  # dedicated instance must never negotiate or fall back to HTTP/1.
  def pool_options do
    [
      protocols: [:http2],
      count: 1,
      conn_opts: [transport_opts: [verify: :verify_peer, timeout: @timeout]]
    ]
  end

  def finch_child_spec do
    {Finch, name: @finch, pools: %{default: pool_options()}}
  end

  # Only APNs selects the production origin, from its fixed Apple allowlist.
  # Separate arguments allow loopback TLS tests without profile host/TLS knobs.
  def post(origin, options, finch \\ @finch, pool_options \\ pool_options()) do
    result =
      if options[:plug] do
        # Existing Req.Test seam bypasses only the real transport/readiness.
        Req.post(options)
      else
        pool = Finch.Pool.new(origin)
        deadline = System.monotonic_time(:millisecond) + @timeout

        # start_pool is idempotent but HTTP/2 registration is asynchronous.
        # It does NOT inherit the instance's default pool configuration.
        with :ok <- Finch.start_pool(finch, pool, pool_options),
             :ok <- await_pool(finch, pool, deadline) do
          Req.post(Keyword.put(options, :finch, finch))
        end
      end

    response_result(result)
  rescue
    _ -> {:error, :apns_unreachable}
  catch
    :exit, _ -> {:error, :apns_unreachable}
  end

  # Readiness is bounded by 5s, independently of the existing 5s connect and
  # receive phase limits. This is not an absolute 5s delivery deadline. Check
  # on every send (including after reconnect); never cache readiness forever.
  # At most 500 short waits per send, for only the two product-owned origins.
  # No warm-up HTTP request or application-level notification retry is sent.
  defp await_pool(finch, pool, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :pool_readiness_timeout}
    else
      case Finch.find_pool(finch, pool) do
        {:ok, _pid} ->
          :ok

        :error ->
          receive do
          after
            min(10, remaining) -> await_pool(finch, pool, deadline)
          end
      end
    end
  end

  defp response_result({:ok, %{status: 200}}), do: :ok
  defp response_result({:ok, %{status: 410}}), do: {:error, :invalid_token}

  defp response_result({:ok, %{body: %{"reason" => "BadDeviceToken"}}}) do
    # Environment mismatch is not proof of expiration; retain the address.
    {:error, :apns_token_environment_mismatch}
  end

  defp response_result({:ok, %{body: %{"reason" => reason}}})
       when reason in [
              "DeviceTokenNotForTopic",
              "TopicDisallowed",
              "BadTopic",
              "MissingTopic",
              "InvalidProviderToken",
              "ExpiredProviderToken",
              "MissingProviderToken",
              "Forbidden"
            ],
       do: {:error, :apns_configuration_error}

  defp response_result({:ok, %{status: status}}) when status in [429, 500, 503],
    do: {:error, :apns_retryable}

  defp response_result({:ok, _}), do: {:error, :apns_rejected}
  defp response_result({:error, _}), do: {:error, :apns_unreachable}
end
