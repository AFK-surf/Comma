defmodule CommaWeb.SlackLocalMirror do
  @moduledoc """
  Local ClickHouse read-through for Slack public channels already mirrored by
  Salix (`SalixIM.SlackMessageMirror` + `SalixStore.SlackMirrorBackfillLedger`),
  plus a bounded ETS cache for Slack display names (`users.info`).

  Only eligible public `C...` channels whose backfill ledger covers the
  requested timestamp are served locally. Direct messages (`D...`), private
  channels (`G...`), uncovered ranges, and mirror errors return `:miss` so the
  caller falls back to the member's Slack Web API grant.
  """

  alias SalixIM.SlackMessageMirror
  alias SalixIM.Triage.ClickHouseReader
  alias SalixStore.SlackMirrorBackfillLedger

  @cache_table :comma_slack_local_mirror_cache
  @user_name_ttl_ms 3_600_000
  @auth_test_ttl_ms 300_000
  @channel_map_ttl_ms 86_400_000
  @cache_max_entries 2_048

  @doc """
  Attempts to answer a Slack Web API `conversations.replies` or
  `conversations.history` URL from the local ClickHouse Slack mirror.

  Returns `{:ok, %{"ok" => true, "messages" => [...]}}` on a covered local hit,
  or `:miss` when the caller should fall back to live Slack HTTP.
  """
  @spec fetch_url(String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, map()} | :miss
  def fetch_url(tenant_id, workspace_id, url)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(workspace_id) and
             workspace_id != "" and is_binary(url) do
    if SlackMessageMirror.enabled?() do
      uri = URI.parse(url)
      method = uri.path |> to_string() |> Path.basename()
      params = URI.decode_query(uri.query || "")

      case method do
        "conversations.replies" ->
          fetch_replies(tenant_id, workspace_id, params)

        "conversations.history" ->
          fetch_history(tenant_id, workspace_id, params)

        _ ->
          :miss
      end
    else
      :miss
    end
  rescue
    _ -> :miss
  end

  def fetch_url(_tenant_id, _workspace_id, _url), do: :miss

  @doc """
  Reads a Slack user's display name from a bounded ETS cache keyed by
  `{workspace_id, user_id}`, invoking `fetcher` on a miss. Never caches `nil`.
  """
  @spec user_name(String.t() | nil, String.t(), (-> String.t() | nil)) :: String.t() | nil
  def user_name(workspace_id, user_id, fetcher)
      when is_binary(workspace_id) and workspace_id != "" and is_binary(user_id) and
             is_function(fetcher, 0) do
    key = {:user_name, workspace_id, user_id}

    case cache_get(key) do
      {:ok, name} ->
        name

      :miss ->
        case fetcher.() do
          name when is_binary(name) and name != "" ->
            cache_put(key, name, @user_name_ttl_ms)
            name

          other ->
            other
        end
    end
  end

  def user_name(_workspace_id, _user_id, fetcher) when is_function(fetcher, 0), do: fetcher.()

  @doc """
  Caches a verified non-bot Slack `auth.test` payload in ETS for 5 minutes when
  the local mirror is enabled and `tenant_id`, `expected_subject`
  (`provider_user_id` and `provider_workspace_id`), and `token_fingerprint` are
  present.
  """
  @spec auth_test(
          String.t() | nil,
          map() | nil,
          String.t() | nil,
          (-> {:ok, map()} | {:error, term()})
        ) ::
          {:ok, map()} | {:error, term()}
  def auth_test(
        tenant_id,
        %{"provider_user_id" => user_id, "provider_workspace_id" => workspace_id},
        token_fingerprint,
        fetcher
      )
      when is_binary(tenant_id) and tenant_id != "" and is_binary(user_id) and user_id != "" and
             is_binary(workspace_id) and workspace_id != "" and
             is_binary(token_fingerprint) and token_fingerprint != "" and
             is_function(fetcher, 0) do
    if SlackMessageMirror.enabled?() do
      key = {:auth_test, tenant_id, workspace_id, user_id, token_fingerprint}

      case cache_get(key) do
        {:ok, auth} ->
          {:ok, auth}

        :miss ->
          case fetcher.() do
            {:ok, %{"ok" => true, "user_id" => ^user_id, "team_id" => ^workspace_id} = auth} ->
              if is_nil(auth["bot_id"]) do
                cache_put(key, auth, @auth_test_ttl_ms)
              end

              {:ok, auth}

            other ->
              other
          end
      end
    else
      fetcher.()
    end
  end

  def auth_test(_tenant_id, _expected_subject, _token_fingerprint, fetcher)
      when is_function(fetcher, 0),
      do: fetcher.()

  @doc """
  Registers verified public channel `{name -> {channel_id, base_url}}` mappings
  observed in Slack search matches, scoped per `(workspace_id, user_id)`, so
  subsequent `in:#channel` portrait target reads can resolve the channel ID in
  the local ClickHouse mirror.
  """
  @spec register_channels(String.t() | nil, String.t() | nil, [map()]) :: :ok
  def register_channels(workspace_id, user_id, matches)
      when is_binary(workspace_id) and workspace_id != "" and
             is_binary(user_id) and user_id != "" and is_list(matches) do
    if SlackMessageMirror.enabled?() do
      Enum.each(matches, fn match ->
        channel = match["channel"]

        if verified_public_channel?(channel) do
          channel_id = channel["id"]
          channel_name = channel["name"]
          base_url = extract_base_url(match["permalink"])

          cache_put(
            {:channel_name, workspace_id, user_id, channel_name},
            {channel_id, base_url},
            @channel_map_ttl_ms
          )
        end
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  def register_channels(_workspace_id, _user_id, _matches), do: :ok

  @doc """
  Attempts to serve an `in:#channel after:YYYY-MM-DD` target search from the
  local ClickHouse mirror when the public channel is verified for the user and
  covered by the backfill ledger.
  """
  @spec fetch_target_search(
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t(),
          Date.t() | String.t(),
          keyword()
        ) :: {:ok, [map()]} | :miss
  def fetch_target_search(tenant_id, workspace_id, user_id, channel_name, since, opts \\ [])

  def fetch_target_search(tenant_id, workspace_id, user_id, channel_name, since, opts)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(workspace_id) and
             workspace_id != "" and is_binary(user_id) and user_id != "" and
             is_binary(channel_name) and channel_name != "" do
    reader = ClickHouseReader.impl()

    with true <- SlackMessageMirror.enabled?(),
         true <- reader_ready?(reader, :search, 2),
         {:ok, {channel_id, base_url}} <-
           resolve_target_channel(workspace_id, user_id, channel_name),
         {:ok, after_date_iso, needed_us} <- since_date_to_ts(since),
         ledger_scope = %{
           "tenant_id" => tenant_id,
           "workspace_id" => workspace_id,
           "channel_id" => channel_id
         },
         true <- covered?(ledger_scope, needed_us),
         search_scope = %{
           "tenant_id" => tenant_id,
           "workspace_id" => workspace_id
         },
         limit = Keyword.get(opts, :limit, 20),
         {:ok, %{messages: messages}} when is_list(messages) <-
           reader.search(search_scope,
             channel_id: channel_id,
             after_us: needed_us,
             after_date: after_date_iso,
             sort_dir: :desc,
             limit: limit
           ) do
      {:ok,
       Enum.map(messages, fn row ->
         format_target_match(
           row,
           workspace_id,
           channel_id,
           channel_name,
           base_url || "https://slack.com"
         )
       end)}
    else
      _ -> :miss
    end
  rescue
    _ -> :miss
  end

  def fetch_target_search(_tenant_id, _workspace_id, _user_id, _channel_name, _since, _opts),
    do: :miss

  @doc false
  def clear_cache do
    if SystemsRuntime.ETS.whereis(@cache_table) != :undefined do
      SystemsRuntime.ETS.delete_all_objects(@cache_table)
    end

    :ok
  end

  defp fetch_replies(tenant_id, workspace_id, params) do
    channel = params["channel"]
    root_ts = params["ts"]
    reader = ClickHouseReader.impl()

    with true <- public_channel?(channel) and is_binary(root_ts) and root_ts != "",
         true <- reader_ready?(reader, :replies, 3),
         {:ok, needed_us} <- ts_to_us(params["oldest"] || root_ts),
         scope = %{
           "tenant_id" => tenant_id,
           "workspace_id" => workspace_id,
           "channel_id" => channel
         },
         true <- covered?(scope, needed_us),
         opts =
           [
             limit: parse_limit(params["limit"], 50),
             oldest: blank_nil(params["oldest"]),
             latest: blank_nil(params["latest"]),
             inclusive: parse_bool(params["inclusive"])
           ]
           |> Enum.reject(fn {_k, v} -> is_nil(v) end),
         {:ok, %{messages: [_ | _] = messages}} <- reader.replies(scope, root_ts, opts) do
      {:ok, %{"ok" => true, "messages" => Enum.map(messages, &normalize_message/1)}}
    else
      _ -> :miss
    end
  end

  defp fetch_history(tenant_id, workspace_id, params) do
    channel = params["channel"]
    oldest = params["oldest"]
    reader = ClickHouseReader.impl()

    with true <- public_channel?(channel) and is_binary(oldest) and oldest != "",
         true <- reader_ready?(reader, :history, 2),
         {:ok, needed_us} <- ts_to_us(oldest),
         scope = %{
           "tenant_id" => tenant_id,
           "workspace_id" => workspace_id,
           "channel_id" => channel
         },
         true <- covered?(scope, needed_us),
         opts =
           [
             limit: parse_limit(params["limit"], 100),
             oldest: oldest,
             latest: blank_nil(params["latest"]),
             inclusive: parse_bool(params["inclusive"])
           ]
           |> Enum.reject(fn {_k, v} -> is_nil(v) end),
         {:ok, %{messages: messages}} when is_list(messages) <- reader.history(scope, opts) do
      {:ok, %{"ok" => true, "messages" => Enum.map(messages, &normalize_message/1)}}
    else
      _ -> :miss
    end
  end

  defp public_channel?(channel) when is_binary(channel), do: String.starts_with?(channel, "C")
  defp public_channel?(_other), do: false

  defp reader_ready?(reader, fun, arity) when is_atom(reader) do
    _ = Code.ensure_loaded(reader)
    function_exported?(reader, fun, arity)
  end

  defp reader_ready?(_reader, _fun, _arity), do: false

  defp covered?(scope, needed_us) do
    case SlackMirrorBackfillLedger.watermark(scope) do
      {:ok, %{"exhausted" => true}} ->
        true

      {:ok, %{"indexed_from_ts_us" => from_us}}
      when is_integer(from_us) and from_us <= needed_us ->
        true

      {:ok, %{exhausted: true}} ->
        true

      {:ok, %{indexed_from_ts_us: from_us}} when is_integer(from_us) and from_us <= needed_us ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp normalize_message(row) when is_map(row) do
    ts = row["ts"] || row["message_ts"]
    thread_ts = row["thread_ts"]
    actor_kind = row["actor_kind"]
    actor_id = row["actor_id"]

    user =
      cond do
        is_binary(row["user"]) and row["user"] != "" -> row["user"]
        actor_kind == "user" and is_binary(actor_id) and actor_id != "" -> actor_id
        true -> nil
      end

    bot_id =
      cond do
        is_binary(row["bot_id"]) and row["bot_id"] != "" -> row["bot_id"]
        actor_kind == "bot" and is_binary(actor_id) and actor_id != "" -> actor_id
        true -> nil
      end

    %{
      "ts" => ts,
      "thread_ts" => if(thread_ts in [nil, ""], do: nil, else: thread_ts),
      "user" => user,
      "bot_id" => bot_id,
      "subtype" => row["subtype"],
      "text" => row["text"] || ""
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp ts_to_us(ts) when is_binary(ts) do
    case String.split(ts, ".", parts: 2) do
      [sec_s] ->
        case Integer.parse(sec_s) do
          {sec, ""} when sec >= 0 -> {:ok, sec * 1_000_000}
          _ -> :error
        end

      [sec_s, frac_s] ->
        with {sec, ""} when sec >= 0 <- Integer.parse(sec_s),
             padded = String.pad_trailing(String.slice(frac_s, 0, 6), 6, "0"),
             {frac, ""} when frac >= 0 <- Integer.parse(padded) do
          {:ok, sec * 1_000_000 + frac}
        else
          _ -> :error
        end
    end
  end

  defp ts_to_us(_other), do: :error

  defp parse_limit(nil, default), do: default

  defp parse_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..200 -> n
      _ -> default
    end
  end

  defp parse_limit(_value, default), do: default

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_other), do: nil

  defp blank_nil(nil), do: nil
  defp blank_nil(""), do: nil
  defp blank_nil(value) when is_binary(value), do: value

  defp verified_public_channel?(channel) when is_map(channel) do
    public_channel?(channel["id"]) and
      is_binary(channel["name"]) and channel["name"] != "" and
      channel["is_channel"] == true and
      channel["is_private"] == false and
      channel["is_group"] != true and
      channel["is_im"] != true and
      channel["is_mpim"] != true
  end

  defp verified_public_channel?(_other), do: false

  defp resolve_target_channel(workspace_id, user_id, channel_name) do
    case cache_get({:channel_name, workspace_id, user_id, channel_name}) do
      {:ok, {channel_id, base_url}} -> {:ok, {channel_id, base_url}}
      :miss -> :error
    end
  end

  defp since_date_to_ts(%Date{} = date) do
    next_date = Date.add(date, 1)
    {:ok, dt} = DateTime.new(next_date, ~T[00:00:00], "Etc/UTC")
    sec = DateTime.to_unix(dt, :second)
    {:ok, Date.to_iso8601(next_date), sec * 1_000_000}
  end

  defp since_date_to_ts(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> since_date_to_ts(date)
      _ -> :error
    end
  end

  defp since_date_to_ts(_other), do: :error

  defp extract_base_url(permalink) when is_binary(permalink) do
    case URI.parse(permalink) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}"

      _ ->
        nil
    end
  end

  defp extract_base_url(_other), do: nil

  defp format_target_match(row, workspace_id, channel_id, channel_name, base_url) do
    norm = normalize_message(row)
    ts = norm["ts"] || "0.000000"
    thread_ts = norm["thread_ts"]
    digits = String.replace(ts, ".", "")

    permalink =
      if is_binary(thread_ts) and thread_ts != "" and thread_ts != ts do
        "#{base_url}/archives/#{channel_id}/p#{digits}?thread_ts=#{thread_ts}&cid=#{channel_id}"
      else
        "#{base_url}/archives/#{channel_id}/p#{digits}"
      end

    username =
      case row["actor_label"] || row["username"] do
        label when is_binary(label) and label != "" ->
          label

        _ ->
          if is_binary(norm["user"]) and norm["user"] != "" do
            case cache_get({:user_name, workspace_id, norm["user"]}) do
              {:ok, cached_name} when is_binary(cached_name) and cached_name != "" -> cached_name
              _ -> nil
            end
          else
            nil
          end
      end

    norm
    |> Map.put("channel", %{"id" => channel_id, "name" => channel_name})
    |> Map.put("permalink", permalink)
    |> then(fn m ->
      if is_binary(username) and username != "", do: Map.put(m, "username", username), else: m
    end)
  end

  defp ensure_cache_table do
    case SystemsRuntime.ETS.whereis(@cache_table) do
      :undefined ->
        try do
          SystemsRuntime.ETS.new(@cache_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true
          ])
        rescue
          ArgumentError -> @cache_table
        end

      _ref ->
        @cache_table
    end
  end

  defp cache_get(key) do
    ensure_cache_table()
    now = SystemsClock.monotonic_time(:millisecond)

    case SystemsRuntime.ETS.lookup(@cache_table, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  end

  defp cache_put(key, value, ttl_ms) do
    ensure_cache_table()

    if SystemsRuntime.ETS.info(@cache_table, :size) >= @cache_max_entries do
      SystemsRuntime.ETS.delete_all_objects(@cache_table)
    end

    expires_at = SystemsClock.monotonic_time(:millisecond) + ttl_ms
    SystemsRuntime.ETS.insert(@cache_table, {key, value, expires_at})
    :ok
  end
end
