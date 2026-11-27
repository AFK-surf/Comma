defmodule SalixIM.Provider.Slack.Permalink do
  @moduledoc """
  Canonical Slack message permalink builder and workspace-URL cache.

  Read paths (`slack.get_thread_replies`, `slack.get_channel_history`,
  `slack.search`) use `cached_workspace_url/1` and `build_for_connect/4` so
  they never issue extra Slack HTTP calls. Callers that already hold a bot
  token and want to resolve an uncached workspace host (`DailyBriefSource`)
  use `resolve_workspace_url/2`.
  """

  alias SalixIM.Provider.Slack.API, as: SlackAPI

  @cache_table :salix_im_slack_permalink_cache
  @workspace_url_ttl_ms 3_600_000
  @unavailable_ttl_ms 60_000
  @cache_max_entries 2_000

  @slack_ts_regex ~r/\A(\d{10})\.(\d{6})\z/
  @thread_ts_regex ~r/\A\d{1,12}\.\d{6}\z/

  @doc "Validates and normalizes a Slack workspace URL to `https://<host>.slack.com`."
  @spec normalize_workspace_url(term()) :: String.t() | nil
  def normalize_workspace_url("https://" <> _ = raw_url) do
    case URI.parse(raw_url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        host = String.downcase(host)

        if String.ends_with?(host, ".slack.com") and host != ".slack.com" do
          "https://" <> host
        else
          nil
        end

      _ ->
        nil
    end
  end

  def normalize_workspace_url(_raw_url), do: nil

  @doc "Caches a normalized workspace URL keyed by Slack workspace/team id."
  @spec cache_workspace_url(term(), term()) :: :ok
  def cache_workspace_url(workspace_id, raw_url)
      when is_binary(workspace_id) and workspace_id != "" do
    case normalize_workspace_url(raw_url) do
      base when is_binary(base) ->
        cache_put({:workspace_url, workspace_id}, base, @workspace_url_ttl_ms)

      nil ->
        :ok
    end
  end

  def cache_workspace_url(_workspace_id, _raw_url), do: :ok

  @doc "Caches a normalized workspace URL keyed by connect and workspace id."
  @spec cache_connect_url(term(), term()) :: :ok
  def cache_connect_url(connect, raw_url) when is_map(connect) do
    case normalize_workspace_url(raw_url) do
      base when is_binary(base) ->
        if key = connect_cache_key(connect) do
          cache_put(key, base, @workspace_url_ttl_ms)
        end

        cache_workspace_url(connect["workspace_id"], base)

      nil ->
        :ok
    end
  end

  def cache_connect_url(_connect, _raw_url), do: :ok

  @doc """
  Returns the cached normalized workspace URL for `connect`, or `nil`.
  Never performs an HTTP request.
  """
  @spec cached_workspace_url(term()) :: String.t() | nil
  def cached_workspace_url(connect) when is_map(connect) do
    normalize_workspace_url(connect["workspace_url"]) ||
      cached_connect_url(connect) ||
      cached_by_workspace_id(connect["workspace_id"])
  end

  def cached_workspace_url(_connect), do: nil

  @doc """
  Resolves the normalized workspace URL for `connect`, falling back to
  `auth.test` when uncached. Rate-limit errors are reraised; other Slack API
  failures are negatively cached for `@unavailable_ttl_ms`.
  """
  @spec resolve_workspace_url(map(), SlackAPI.credential()) :: String.t() | nil
  def resolve_workspace_url(connect, token) when is_map(connect) and is_binary(token) do
    case normalize_workspace_url(connect["workspace_url"]) do
      base when is_binary(base) ->
        base

      nil ->
        connect_key = connect_cache_key(connect)

        case connect_key && cache_get(connect_key) do
          {:ok, url} when is_binary(url) ->
            url

          {:ok, :unavailable} ->
            nil

          _miss ->
            case cached_by_workspace_id(connect["workspace_id"]) do
              url when is_binary(url) ->
                if connect_key, do: cache_put(connect_key, url, @workspace_url_ttl_ms)
                url

              nil ->
                fetch_workspace_url(connect, connect_key, token)
            end
        end
    end
  end

  @doc """
  Builds a canonical Slack message permalink.

  Requires a valid workspace URL (or `"https://slack.com"`), a non-empty
  `channel_id`, and a standard 10.6-digit Slack `ts`. When `thread_ts` is a
  valid Slack timestamp different from `ts`, appends `?thread_ts=...&cid=...`.
  """
  @spec build(term(), term(), term(), term()) :: String.t() | nil
  def build(base_url, channel_id, ts, thread_ts \\ nil)

  def build(base_url, channel_id, ts, thread_ts)
      when is_binary(base_url) and is_binary(channel_id) and channel_id != "" and is_binary(ts) do
    with base when is_binary(base) <- normalize_base_url(base_url),
         [_, seconds, micros] <- Regex.run(@slack_ts_regex, ts) do
      path = "#{base}/archives/#{channel_id}/p#{seconds}#{micros}"

      if is_binary(thread_ts) and thread_ts != "" and thread_ts != ts and
           Regex.match?(@thread_ts_regex, thread_ts) do
        "#{path}?thread_ts=#{thread_ts}&cid=#{channel_id}"
      else
        path
      end
    else
      _ -> nil
    end
  end

  def build(_base_url, _channel_id, _ts, _thread_ts), do: nil

  @doc """
  Builds a canonical Slack permalink for `connect` using cached workspace URL
  or `"https://slack.com"`. Never performs an HTTP request.
  """
  @spec build_for_connect(term(), term(), term(), term()) :: String.t() | nil
  def build_for_connect(connect, channel_id, ts, thread_ts \\ nil) do
    base_url = cached_workspace_url(connect) || "https://slack.com"
    build(base_url, channel_id, ts, thread_ts)
  end

  @doc false
  @spec clear_cache() :: :ok
  def clear_cache do
    if SystemsRuntime.ETS.whereis(@cache_table) != :undefined do
      _ = SystemsRuntime.ETS.delete_all_objects(@cache_table)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp normalize_base_url("https://slack.com"), do: "https://slack.com"
  defp normalize_base_url(base_url), do: normalize_workspace_url(base_url)

  defp fetch_workspace_url(connect, connect_key, token) do
    case SlackAPI.request_form(token, "auth.test", []) do
      %{"ok" => true, "url" => raw_url} = body ->
        case normalize_workspace_url(raw_url) do
          base when is_binary(base) ->
            if connect_key, do: cache_put(connect_key, base, @workspace_url_ttl_ms)
            cache_workspace_url(connect["workspace_id"], base)
            cache_workspace_url(body["team_id"], base)
            base

          nil ->
            if connect_key, do: cache_put(connect_key, :unavailable, @unavailable_ttl_ms)
            nil
        end

      _ ->
        if connect_key, do: cache_put(connect_key, :unavailable, @unavailable_ttl_ms)
        nil
    end
  rescue
    error in SlackAPI.Error ->
      if is_integer(error.retry_after) and error.retry_after > 0 do
        reraise error, __STACKTRACE__
      else
        if connect_key, do: cache_put(connect_key, :unavailable, @unavailable_ttl_ms)
        nil
      end
  end

  defp cached_connect_url(connect) do
    with key when not is_nil(key) <- connect_cache_key(connect),
         {:ok, url} when is_binary(url) <- cache_get(key) do
      url
    else
      _ -> nil
    end
  end

  defp cached_by_workspace_id(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    case cache_get({:workspace_url, workspace_id}) do
      {:ok, url} when is_binary(url) -> url
      _ -> nil
    end
  end

  defp cached_by_workspace_id(_workspace_id), do: nil

  defp connect_cache_key(connect) when is_map(connect) do
    case connect["connect_id"] do
      connect_id when is_binary(connect_id) and connect_id != "" ->
        {:connect_url, connect["tenant_id"], connect_id, connect["connect_generation"]}

      _ ->
        nil
    end
  end

  defp cache_table do
    case SystemsRuntime.ETS.whereis(@cache_table) do
      :undefined ->
        try do
          SystemsRuntime.ETS.new(@cache_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> @cache_table
        end

      _ ->
        @cache_table
    end
  end

  defp cache_get(key) do
    now = SystemsClock.monotonic_time(:millisecond)

    case SystemsRuntime.ETS.lookup(cache_table(), key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(key, value, ttl_ms) do
    tab = cache_table()
    now = SystemsClock.monotonic_time(:millisecond)
    _ = SystemsRuntime.ETS.select_delete(tab, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])

    if SystemsRuntime.ETS.info(tab, :size) >= @cache_max_entries do
      _ = SystemsRuntime.ETS.delete_all_objects(tab)
    end

    SystemsRuntime.ETS.insert(tab, {key, value, now + ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end
end
