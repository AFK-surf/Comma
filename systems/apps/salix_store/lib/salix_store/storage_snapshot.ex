defmodule SalixStore.StorageSnapshot do
  @moduledoc """
  Bounded S3 prefix storage metering snapshots.

  The job samples object count and bytes for a prefix and emits one byte-second
  fact through a mockable metering hook. It never runs from PUT/DELETE hot paths.
  """

  require Logger

  alias SalixStore.S3

  @default_max_objects 1_000
  @default_window_seconds 3_600
  @default_tier_cache_ttl_ms 300_000
  @default_tier_lookup_timeout_ms 1_000
  @tier_cache __MODULE__.TierCache

  @spec sample_prefix(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def sample_prefix(attrs) when is_list(attrs), do: attrs |> Map.new() |> sample_prefix()

  def sample_prefix(attrs) when is_map(attrs) do
    prefix = Map.fetch!(attrs, :prefix)
    max_objects = Map.get(attrs, :max_objects, @default_max_objects)
    sample_window_seconds = Map.get(attrs, :sample_window_seconds, @default_window_seconds)

    with {:ok, objects} <- S3.list_all(prefix, max_keys: max_objects + 1) do
      sampled = Enum.take(objects, max_objects)
      truncated? = length(objects) > max_objects
      bytes = Enum.reduce(sampled, 0, &(&1.size + &2))
      now_ms = Map.get(attrs, :now, System.system_time(:millisecond))
      source_key = Map.get(attrs, :source_key) || source_key(prefix, now_ms)

      tier = resolve_tier(attrs, prefix, sampled, now_ms)

      fact =
        attrs
        |> Map.merge(%{
          source: Map.get(attrs, :source, "salix_store.storage_snapshot"),
          source_key: source_key,
          entrypoint: Map.get(attrs, :entrypoint, "storage_snapshot"),
          actor_type: Map.get(attrs, :actor_type, "system"),
          provider: Map.get(attrs, :provider, "s3"),
          sku: Map.get(attrs, :sku, tier.storage_tier),
          storage_tier: tier.storage_tier,
          tier_source: tier.tier_source,
          tier_cache_hit: tier.cache_hit,
          sample_window_seconds: sample_window_seconds,
          bytes: bytes,
          object_count: length(sampled),
          byte_seconds: bytes * sample_window_seconds,
          quantity: bytes * sample_window_seconds,
          metered_at: DateTime.from_unix!(now_ms, :millisecond),
          quality: quality(attrs, truncated?, tier.quality)
        })

      _ = call_metering(:meter_storage_sample, [fact])
      {:ok, fact}
    end
  end

  defp resolve_tier(attrs, prefix, sampled, now_ms) do
    cond do
      present?(Map.get(attrs, :storage_tier)) ->
        %{
          storage_tier: Map.fetch!(attrs, :storage_tier),
          tier_source: Map.get(attrs, :tier_source, "provided"),
          cache_hit: Map.get(attrs, :tier_cache_hit, false),
          quality: []
        }

      cached = tier_cache_get(cache_key(attrs, prefix), now_ms) ->
        %{
          storage_tier: cached.storage_tier,
          tier_source: cached.tier_source,
          cache_hit: true,
          quality: []
        }

      lookup_fun =
          Map.get(attrs, :tier_lookup_fun) ||
            Application.get_env(:salix_store, :storage_tier_lookup_fun) ->
        lookup_tier(attrs, prefix, sampled, now_ms, lookup_fun)

      true ->
        %{
          storage_tier: "unknown",
          tier_source: "unknown",
          cache_hit: false,
          quality: ["storage_tier_unavailable"]
        }
    end
  end

  defp lookup_tier(attrs, prefix, sampled, now_ms, lookup_fun) do
    timeout = Map.get(attrs, :tier_lookup_timeout_ms, @default_tier_lookup_timeout_ms)

    task =
      Task.async(fn ->
        case Function.info(lookup_fun, :arity) do
          {:arity, 2} -> lookup_fun.(prefix, sampled)
          {:arity, 1} -> lookup_fun.(prefix)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        tier_result = normalize_tier_result(result)
        tier_cache_put(cache_key(attrs, prefix), tier_result, now_ms, attrs)
        tier_result

      {:ok, result} ->
        tier_result = normalize_tier_result(result)
        tier_cache_put(cache_key(attrs, prefix), tier_result, now_ms, attrs)
        tier_result

      nil ->
        %{
          storage_tier: "unknown",
          tier_source: "unknown",
          cache_hit: false,
          quality: ["storage_tier_lookup_timeout"]
        }

      _ ->
        %{
          storage_tier: "unknown",
          tier_source: "unknown",
          cache_hit: false,
          quality: ["storage_tier_lookup_failed"]
        }
    end
  end

  defp normalize_tier_result(%{storage_tier: tier} = result)
       when is_binary(tier) and tier != "" do
    %{
      storage_tier: tier,
      tier_source: Map.get(result, :tier_source, "provider"),
      cache_hit: false,
      quality: []
    }
  end

  defp normalize_tier_result(%{"storage_tier" => tier} = result)
       when is_binary(tier) and tier != "" do
    %{
      storage_tier: tier,
      tier_source: Map.get(result, "tier_source", "provider"),
      cache_hit: false,
      quality: []
    }
  end

  defp normalize_tier_result(tier) when is_binary(tier) and tier != "" do
    %{storage_tier: tier, tier_source: "provider", cache_hit: false, quality: []}
  end

  defp normalize_tier_result(_result) do
    %{
      storage_tier: "unknown",
      tier_source: "unknown",
      cache_hit: false,
      quality: ["storage_tier_lookup_failed"]
    }
  end

  defp tier_cache_get(key, now_ms) do
    ensure_tier_cache!()

    case :ets.lookup(@tier_cache, key) do
      [{^key, value, expires_at}] when expires_at > now_ms -> value
      _ -> nil
    end
  end

  defp tier_cache_put(_key, %{storage_tier: "unknown"}, _now_ms, _attrs), do: :ok

  defp tier_cache_put(key, value, now_ms, attrs) do
    ensure_tier_cache!()
    ttl = Map.get(attrs, :tier_cache_ttl_ms, @default_tier_cache_ttl_ms)
    true = :ets.insert(@tier_cache, {key, value, now_ms + ttl})
    :ok
  end

  defp ensure_tier_cache! do
    case :ets.info(@tier_cache) do
      :undefined -> :ets.new(@tier_cache, [:named_table, :public, read_concurrency: true])
      _ -> @tier_cache
    end
  end

  defp cache_key(attrs, prefix), do: {Map.get(attrs, :provider, "s3"), prefix}

  defp quality(attrs, truncated?, tier_quality) do
    attrs
    |> Map.get(:quality, [])
    |> List.wrap()
    |> Kernel.++(tier_quality)
    |> then(fn flags ->
      if truncated?, do: ["truncated_object_list" | flags], else: flags
    end)
    |> Enum.uniq()
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp source_key(prefix, now_ms) do
    digest = :crypto.hash(:sha256, prefix) |> Base.encode16(case: :lower)
    "storage:#{binary_part(digest, 0, 16)}:#{now_ms}"
  end

  defp call_metering(fun, args) do
    case Application.get_env(:salix_store, :storage_metering_mod) do
      nil ->
        :ok

      mod ->
        apply(mod, fun, args)
    end
  catch
    kind, reason ->
      Logger.warning("storage snapshot metering failed: #{inspect({kind, reason})}")
      :ok
  end
end
