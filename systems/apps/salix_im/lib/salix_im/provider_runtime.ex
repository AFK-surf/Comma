defmodule SalixIM.ProviderRuntime do
  @moduledoc """
  Polling runtime for provider-connect IM sources that do not deliver webhooks.

  Slack and Feishu enter through global webhooks. Telegram and WeChat are
  group-owned provider connects and are polled here, then normalized through
  `SalixIM.ProviderHTTP` into the group router session.

  ## A failed pass never stops the poller

  Connect enumeration is deliberately fail-closed and bounded: a corrupt or
  unreadable record, a transient store fault, or a corpus past the scan cap
  all surface as `{:error, reason}` from `poll_once/1`. The timer callback
  therefore treats a failed pass as an *observable outcome*, never a crash —
  a raising callback would take the process down, and since the pass repeats
  on a fixed interval the supervisor restart would immediately re-raise,
  ending in a restart-intensity shutdown that stops Telegram/WeChat polling
  for the whole node. Every pass emits `[:salix, :operation, :stop]` with
  `operation: "provider_poll"` so a persistently failing pass is visible
  (`outcome: "scan_error"` for the bounded-scan cap, `"unavailable"` for a
  store fault) instead of silent, and per-connect failures are logged with a
  count rather than discarded.
  """

  use GenServer
  require Logger

  alias SalixIM.{ProviderConnects, ProviderHTTP}

  @default_interval_ms 5_000
  @default_telegram_timeout_s 0
  @default_receive_timeout_ms 15_000
  @default_task_timeout_ms 20_000
  @default_max_concurrency 32

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def poll_once(providers \\ ["telegram", "wechat"]) do
    with {:ok, connects} <- ProviderConnects.list_runtime_provider_connects(providers) do
      results = poll_connects(connects)
      {:ok, results}
    end
  end

  def poll_connect(%{"provider" => "telegram"} = connect), do: poll_telegram(connect)

  def poll_connect(%{"provider" => "wechat"} = connect) do
    # Suppress redundant requests in the normal case. Correctness comes from
    # the connect's pending-head CAS and Router source-ID deduplication, not
    # lease timing: a stalled holder can overlap its successor.
    key = SalixStore.Keys.ctl_im_wechat_poll_lease(connect["connect_id"])

    case SalixStore.Lease.acquire(key, SalixStore.ULID.generate()) do
      {:ok, lease} ->
        try do
          with {:ok, current} <-
                 ProviderConnects.get_active_connect_by_id(
                   connect["group_id"],
                   connect["connect_id"],
                   "wechat"
                 ) do
            if is_map(current["pending_wechat_poll"]),
              do: drain_wechat_poll(current),
              else: poll_wechat(current)
          end
        after
          SalixStore.Lease.release(lease)
        end

      {:error, {:held_by, _, _}} ->
        {:ok, :busy}

      error ->
        error
    end
  end

  def poll_connect(_connect), do: {:ok, :ignored}

  defp poll_connects([]), do: []

  defp poll_connects(connects) do
    max_concurrency =
      :salix_im
      |> Application.get_env(:provider_runtime_max_concurrency, @default_max_concurrency)
      |> num()
      |> max(1)

    timeout_ms =
      :salix_im
      |> Application.get_env(:provider_runtime_task_timeout_ms, @default_task_timeout_ms)
      |> num()
      |> max(1)

    connects
    |> Task.async_stream(&poll_connect/1,
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    providers = Keyword.get(opts, :providers, ["telegram", "wechat"])
    schedule_poll(interval_ms)
    {:ok, %{interval_ms: interval_ms, providers: providers}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_pass(state.providers)
    schedule_poll(state.interval_ms)
    {:noreply, state}
  end

  # One observable pass. Returns :ok for every outcome — the caller must
  # always reschedule (see the moduledoc: a raising pass becomes a restart
  # loop that stops polling entirely).
  defp poll_pass(providers) do
    # `started` must be a parameter of the function that owns the catch —
    # an implicit-try body's bindings are not visible inside its own catch.
    do_poll_pass(providers, System.monotonic_time())
  end

  defp do_poll_pass(providers, started) do
    case poll_once(providers) do
      {:ok, results} ->
        log_connect_failures(results)
        emit_poll(started, "ok")

      {:error, reason} ->
        Logger.warning("provider poll pass failed: #{inspect(reason)}")
        emit_poll(started, poll_outcome(reason))
    end

    :ok
  catch
    # An unanticipated crash inside the pass (e.g. a store backend exception
    # re-raised by S3.observe) is still a pass outcome: the every-pass-emits
    # contract is exactly what makes a recurring unanticipated failure
    # visible, so this branch must not be the one silent path.
    kind, reason ->
      Logger.warning(
        "provider poll pass crashed: " <> Exception.format(kind, reason, __STACKTRACE__)
      )

      emit_poll(started, "error")
      :ok
  end

  # Only the bounded scan refusing an oversized corpus is the
  # operator-actionable scan_error (it needs an index or a smaller corpus,
  # not a retry). An unexpected scan contract ({:connect_scan_failed, _} —
  # the store returned a shape the scan does not recognize) is a generic
  # error, and plain store faults are unavailable: both retryable-ish, and
  # neither should tell an operator to shrink the corpus.
  defp poll_outcome(:connect_scan_limit_exceeded), do: "scan_error"
  defp poll_outcome({:connect_scan_failed, _}), do: "error"
  defp poll_outcome(_reason), do: "unavailable"

  defp log_connect_failures(results) do
    case Enum.count(results, &match?({:error, _}, &1)) do
      0 ->
        :ok

      failed ->
        Logger.warning("provider poll: #{failed}/#{length(results)} connects failed this pass")
    end
  end

  defp emit_poll(started, outcome) do
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.monotonic_time() - started},
      %{
        component: "salix_im",
        operation: "provider_poll",
        surface: "system",
        outcome: outcome
      }
    )
  end

  defp schedule_poll(interval_ms), do: Process.send_after(self(), :poll, interval_ms)

  defp poll_telegram(connect) do
    base = telegram_api_base()
    token = trim(connect["bot_token"])
    offset = num(connect["updates_offset"])

    params =
      %{"timeout" => @default_telegram_timeout_s}
      |> maybe_put("offset", if(offset > 0, do: offset, else: nil))

    case req_get("#{base}/bot#{token}/getUpdates",
           params: params,
           retry: false,
           connect_options: [protocols: [:http1]],
           receive_timeout: @default_receive_timeout_ms
         ) do
      {:ok, %{status: status, body: %{"ok" => true, "result" => updates}}}
      when status in 200..299 and is_list(updates) ->
        process_telegram_updates(connect, updates)

      {:ok, %{body: %{"ok" => false, "description" => desc}}} ->
        {:error, "Telegram getUpdates failed: #{desc}"}

      {:ok, %{status: status, body: body}} ->
        {:error, "Telegram getUpdates HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_telegram_updates(_connect, []), do: {:ok, :idle}

  defp process_telegram_updates(connect, updates) do
    last_processed =
      Enum.reduce_while(updates, nil, fn update, acc ->
        case ProviderHTTP.handle_telegram_update(connect, update) do
          {:ok, _status} -> {:cont, update["update_id"]}
          {:error, :ignored} -> {:cont, update["update_id"]}
          {:error, reason} -> {:halt, {:error, reason, acc}}
        end
      end)

    case last_processed do
      {:error, reason, nil} ->
        {:error, reason}

      {:error, reason, update_id} ->
        _ =
          ProviderConnects.update_telegram_im_offset(
            connect["group_id"],
            connect["connect_id"],
            num(update_id) + 1
          )

        {:error, reason}

      nil ->
        {:ok, :idle}

      update_id ->
        with :ok <-
               ProviderConnects.update_telegram_im_offset(
                 connect["group_id"],
                 connect["connect_id"],
                 num(update_id) + 1
               ) do
          {:ok, :polled}
        end
    end
  end

  defp poll_wechat(connect) do
    base = trim(connect["base_url"]) |> String.trim_trailing("/")
    token = trim(connect["token"])

    body =
      %{"base_info" => SalixIM.WeChatAPI.base_info()}
      |> maybe_put("get_updates_buf", presence(trim(connect["updates_buf"])))

    case req_post("#{base}/ilink/bot/getupdates",
           json: body,
           headers: SalixIM.WeChatAPI.headers(token),
           retry: false,
           redirect: false,
           connect_options: [protocols: [:http1]],
           receive_timeout: @default_receive_timeout_ms
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        with {:ok, body} <- SalixIM.WeChatAPI.decode_body(body) do
          if body["ret"] in [nil, 0] and body["errcode"] in [nil, 0] do
            process_wechat_updates(connect, body)
          else
            code = if body["errcode"] in [nil, 0], do: body["ret"], else: body["errcode"]
            maybe_mark_wechat_error(connect, code, body["errmsg"])
            {:error, :wechat_poll_failed}
          end
        end

      {:ok, %{body: %{"ret" => ret, "errmsg" => msg}}} ->
        maybe_mark_wechat_error(connect, ret, msg)
        {:error, "WeChat getupdates failed: ret=#{ret} errmsg=#{inspect(msg)}"}

      {:ok, %{body: %{"errcode" => code, "errmsg" => msg}}} ->
        maybe_mark_wechat_error(connect, code, msg)
        {:error, "WeChat getupdates failed: errcode=#{code} errmsg=#{inspect(msg)}"}

      {:ok, %{status: status, body: body}} ->
        {:error, "WeChat getupdates HTTP #{status}: #{inspect(body)}"}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:ok, :idle}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_wechat_updates(connect, body) do
    messages = List.wrap(body["msgs"] || body["messages"] || body["item_list"])
    next_buf = trim(body["get_updates_buf"] || body["updates_buf"] || connect["updates_buf"])

    with {:ok, current} <- ProviderConnects.admit_wechat_poll(connect, messages, next_buf) do
      drain_wechat_poll(current)
    end
  end

  defp drain_wechat_poll(%{"pending_wechat_poll" => %{"messages" => [message | _]}} = connect) do
    case ProviderHTTP.handle_wechat_update(connect, message,
           poll_revision: connect["wechat_poll_revision"]
         ) do
      {:ok, _status} ->
        advance_wechat_poll(connect, message["context_token"], wechat_event_id(message))

      {:error, :ignored} ->
        advance_wechat_poll(connect, "", "")

      error ->
        error
    end
  end

  defp drain_wechat_poll(%{"pending_wechat_poll" => %{"messages" => []}} = connect),
    do: advance_wechat_poll(connect, "", "")

  defp drain_wechat_poll(_connect), do: {:ok, :polled}

  defp advance_wechat_poll(connect, context, event_id) do
    case ProviderConnects.advance_wechat_poll(connect, context, event_id) do
      {:ok, current} -> drain_wechat_poll(current)
      # Another worker completed this head. Do not continue the stale batch.
      {:error, :stale_wechat_poll} -> {:ok, :superseded}
      error -> error
    end
  end

  defp maybe_mark_wechat_error(connect, code, msg) do
    if to_string(code) in ["-14", "401", "403"] do
      ProviderConnects.mark_im_connect_error(
        connect["group_id"],
        connect["connect_id"],
        trim(msg)
      )
    else
      :ok
    end
  end

  defp telegram_api_base do
    :salix_im
    |> Application.get_env(:telegram_api_base_url, "https://api.telegram.org")
    |> trim()
    |> case do
      "" -> "https://api.telegram.org"
      base -> String.trim_trailing(base, "/")
    end
  end

  defp wechat_event_id(message) do
    [message["client_id"], message["message_id"], message["id"], message["context_token"]]
    |> Enum.map(&trim/1)
    |> Enum.find(&(&1 != "")) || :erlang.phash2(message) |> Integer.to_string()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp presence(""), do: nil
  defp presence(value), do: value

  defp req_get(url, opts), do: req_get(url, opts, 2)

  defp req_get(url, opts, pool_retries_left) do
    case Req.get(url, opts) do
      {:error, %Req.HTTPError{reason: :pool_not_available}} when pool_retries_left > 0 ->
        Process.sleep(25)
        req_get(url, opts, pool_retries_left - 1)

      other ->
        other
    end
  end

  defp req_post(url, opts), do: req_post(url, opts, 2)

  defp req_post(url, opts, pool_retries_left) do
    case Req.post(url, opts) do
      {:error, %Req.HTTPError{reason: :pool_not_available}} when pool_retries_left > 0 ->
        Process.sleep(25)
        req_post(url, opts, pool_retries_left - 1)

      other ->
        other
    end
  end

  defp trim(value), do: value |> to_string() |> String.trim()

  defp num(value) when is_integer(value), do: value
  defp num(value) when is_float(value), do: trunc(value)

  defp num(value) do
    case Integer.parse(trim(value)) do
      {n, _} -> n
      :error -> 0
    end
  end
end
