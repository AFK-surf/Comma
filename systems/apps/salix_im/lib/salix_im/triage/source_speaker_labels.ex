defmodule SalixIM.Triage.SourceSpeakerLabels do
  @moduledoc """
  Resolves a bounded, presentation-only Slack speaker-name snapshot.

  Triage source identity remains the immutable provider actor id stored in the
  private product obligation.  This module follows the legacy Oneesama/Commaboard
  split: names come from a separate profile lookup, are cached only as a
  convenience, and are returned positionally so no provider id has to cross the
  public read-model boundary. The product target's `connect_generation` is the
  channel authority generation, not the installation credential generation;
  profile lookup therefore reuses the current credential only when the stable
  connect and workspace still agree. A missing, moved, rate-limited, or malformed
  profile never changes the product decision or effect settlement.
  """

  alias SalixIM.Provider.Slack.API
  alias SalixIM.ProviderConnects
  alias SalixIM.Triage.IdentityContract

  @cache_table :salix_im_triage_source_speaker_labels
  @cache_ttl_ms 6 * 60 * 60 * 1_000
  @negative_cache_ttl_ms 5 * 60 * 1_000
  @max_cache_entries 10_000
  @source_limit 3
  @label_graphemes 80
  @provider_user_id ~r/\A[UW][A-Z0-9]{2,31}\z/

  @doc false
  def create_table!, do: ensure_cache()

  @doc "Returns one safe optional label for each bounded source message."
  @spec resolve(map(), keyword()) :: [String.t() | nil]
  def resolve(payload, opts \\ [])

  def resolve(payload, opts) when is_map(payload) and is_list(opts) do
    messages =
      payload |> Map.get("source_messages", []) |> List.wrap() |> Enum.take(@source_limit)

    fallback = Enum.map(messages, fn _message -> nil end)

    with true <- messages != [],
         {:ok, target, group_id} <- authority(payload),
         actor_ids <- resolvable_actor_ids(messages),
         true <- actor_ids != [],
         {:ok, connect} <- fetch_connect(group_id, target, opts),
         {:ok, credential} <- credential(connect, opts) do
      labels =
        Map.new(actor_ids, fn actor_id ->
          {actor_id, resolve_actor(credential, connect, actor_id, opts)}
        end)

      Enum.map(messages, fn message -> labels[message["actor_id"]] end)
    else
      _unavailable -> fallback
    end
  rescue
    _exception -> fallback_labels(payload)
  catch
    _kind, _reason -> fallback_labels(payload)
  end

  def resolve(_payload, _opts), do: []

  defp fallback_labels(payload) do
    payload
    |> Map.get("source_messages", [])
    |> List.wrap()
    |> Enum.take(@source_limit)
    |> Enum.map(fn _message -> nil end)
  end

  defp authority(payload) do
    target = payload["target"] || %{}
    identity = payload["product_identity"] || %{}
    group_id = identity["project_salix_group_id"]

    if nonempty?(group_id) and nonempty?(target["connect_id"]) and
         nonempty?(target["connect_generation"]) and nonempty?(target["workspace_id"]) do
      {:ok, target, group_id}
    else
      {:error, :invalid}
    end
  end

  defp resolvable_actor_ids(messages) do
    messages
    |> Enum.flat_map(fn
      %{"actor_id" => actor_id, "actor_kind" => kind}
      when kind in ["human", "agent"] and is_binary(actor_id) ->
        if Regex.match?(@provider_user_id, actor_id), do: [actor_id], else: []

      _message ->
        []
    end)
    |> Enum.uniq()
  end

  defp fetch_connect(group_id, target, opts) do
    connect_fun =
      Keyword.get(
        opts,
        :connect_fun,
        &ProviderConnects.get_active_connect_by_id/3
      )

    case connect_fun.(group_id, target["connect_id"], "slack") do
      {:ok, connect} when is_map(connect) ->
        exact? =
          connect["connect_id"] == target["connect_id"] and
            connect["workspace_id"] == target["workspace_id"]

        if exact?, do: {:ok, connect}, else: {:error, :stale}

      _unavailable ->
        {:error, :unavailable}
    end
  end

  defp credential(connect, opts) do
    credential_fun = Keyword.get(opts, :credential_fun, &API.installation/1)

    case credential_fun.(connect) do
      nil -> {:error, :unavailable}
      credential -> {:ok, credential}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  defp resolve_actor(credential, connect, actor_id, opts) do
    cache? = Keyword.get(opts, :cache, true) == true
    now_ms = now_ms(opts)
    key = {connect["connect_id"], connect["connect_generation"], actor_id}

    case cache_lookup(key, now_ms, cache?) do
      {:hit, label} ->
        label

      :miss ->
        label = fetch_label(credential, actor_id, opts)
        cache_store(key, label, now_ms, cache?)
        label
    end
  end

  defp fetch_label(credential, actor_id, opts) do
    user_info_fun = Keyword.get(opts, :user_info_fun, &API.user_info/2)
    user = user_info_fun.(credential, actor_id)
    profile = if is_map(user["profile"]), do: user["profile"], else: %{}

    [
      profile["display_name_normalized"],
      profile["display_name"],
      profile["real_name_normalized"],
      profile["real_name"],
      user["real_name"],
      user["name"]
    ]
    |> Enum.find(&nonempty?/1)
    |> safe_label(actor_id)
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp safe_label(nil, _actor_id), do: nil

  defp safe_label(label, actor_id) when is_binary(label) do
    label = label |> String.trim() |> String.normalize(:nfc)

    if label == "" or label == actor_id do
      nil
    else
      label =
        label
        |> IdentityContract.redact_untrusted_text()
        |> String.split()
        |> Enum.join(" ")
        |> String.slice(0, @label_graphemes)

      if label == "", do: nil, else: label
    end
  end

  defp safe_label(_label, _actor_id), do: nil

  defp cache_lookup(_key, _now_ms, false), do: :miss

  defp cache_lookup(key, now_ms, true) do
    table = ensure_cache()

    case :ets.lookup(table, key) do
      [{^key, expires_at, :missing}] when expires_at > now_ms ->
        {:hit, nil}

      [{^key, expires_at, label}] when expires_at > now_ms ->
        {:hit, label}

      [{^key, _expired, _label}] ->
        :ets.delete(table, key)
        :miss

      [] ->
        :miss
    end
  end

  defp cache_store(_key, _label, _now_ms, false), do: :ok

  defp cache_store(key, label, now_ms, true) do
    table = ensure_cache()

    if :ets.member(table, key) or :ets.info(table, :size) < @max_cache_entries do
      ttl = if is_binary(label), do: @cache_ttl_ms, else: @negative_cache_ttl_ms
      :ets.insert(table, {key, now_ms + ttl, label || :missing})
    end

    :ok
  end

  defp ensure_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> @cache_table
        end

      table ->
        table
    end
  end

  defp now_ms(opts) do
    Keyword.get(opts, :now_ms_fun, fn -> System.monotonic_time(:millisecond) end).()
  end

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
