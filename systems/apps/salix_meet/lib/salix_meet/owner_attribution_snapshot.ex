defmodule SalixMeet.OwnerAttributionSnapshot do
  @moduledoc """
  Product-owned, immutable provenance for meeting owner attribution.

  Meeting summaries are runtime-owned input. They may contain arbitrary fields,
  so provider ids and attribution markers from a summary are always stripped.
  A resolved identity becomes usable only after it is copied into a completed
  snapshot together with fingerprints of the sanitized summary and action item.
  """

  @version 2
  @legacy_version 1
  @snapshot_key "owner_attribution_v2"
  @legacy_snapshot_key "owner_attribution"

  @reserved_keys MapSet.new([
                   "owner_attribution_done",
                   "owner_slack_id",
                   "owner_provider_identity"
                 ])

  @slack_id_pattern ~r/\A[UW][A-Z0-9]+\z/
  @feishu_open_id_pattern ~r/\Aou_[A-Za-z0-9_-]{1,128}\z/
  @max_display_name_graphemes 100

  @type snapshot :: %{required(String.t()) => term()}

  @doc "Read the newest supported snapshot from a meeting delivery envelope."
  @spec fetch_from_delivery(term()) :: {:ok, snapshot()} | :missing | {:error, term()}
  def fetch_from_delivery(delivery) when is_map(delivery) do
    delivery = normalize(delivery, false)
    v2 = delivery[@snapshot_key]
    legacy = delivery[@legacy_snapshot_key]

    cond do
      not is_nil(v2) ->
        fetch_v2(v2)

      snapshot_version(legacy) == @version ->
        fetch_v2(legacy)

      snapshot_version(legacy) == @legacy_version ->
        fetch_legacy(legacy)

      is_map(legacy) and not is_nil(snapshot_version(legacy)) ->
        {:error, {:unsupported_owner_attribution_version, snapshot_version(legacy)}}

      true ->
        :missing
    end
  end

  def fetch_from_delivery(_delivery), do: :missing

  @doc "Return the current supported snapshot from meeting state, or an empty map."
  @spec current(term()) :: snapshot() | %{}
  def current(%{"delivery" => delivery}) do
    case fetch_from_delivery(delivery) do
      {:ok, snapshot} -> snapshot
      _ -> %{}
    end
  end

  def current(_state), do: %{}

  @doc "Persist v2 beside a v1 Slack-compatible mirror for rolling deploy safety."
  @spec put_in_delivery(map(), snapshot()) :: map()
  def put_in_delivery(delivery, snapshot) when is_map(delivery) and is_map(snapshot) do
    snapshot = normalize(snapshot, false)

    if complete_normalized?(snapshot) and snapshot["version"] == @version do
      delivery
      |> normalize(false)
      |> Map.put(@snapshot_key, snapshot)
      |> Map.put(@legacy_snapshot_key, legacy_mirror(snapshot))
    else
      raise ArgumentError, "owner attribution snapshot must be a complete v2 snapshot"
    end
  end

  @doc false
  def rolling_storage_complete?(delivery) when is_map(delivery) do
    case {fetch_v2(delivery[@snapshot_key]), fetch_legacy(delivery[@legacy_snapshot_key])} do
      {{:ok, _v2}, {:ok, _legacy}} -> true
      _ -> false
    end
  end

  def rolling_storage_complete?(_delivery), do: false

  @doc "Strip runtime-owned attribution fields and normalize a value recursively."
  @spec sanitize_summary(term()) :: term()
  def sanitize_summary(value), do: normalize(value, true)

  @doc "Return a deterministic SHA-256 fingerprint for normalized, sanitized data."
  @spec fingerprint(term()) :: String.t()
  def fingerprint(value) do
    digest =
      value
      |> sanitize_summary()
      |> canonical()
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  @doc """
  Build a completed attribution snapshot from a clean source summary and an
  enriched result.

  Only ids attached to the same sanitized action item at the same zero-based
  index are copied. Invalid, moved, or mutated results are left unresolved.
  """
  @spec build(term(), term(), keyword()) :: snapshot()
  def build(summary, enriched, opts \\ []) do
    source = normalize(summary, false)
    clean_summary = sanitize_summary(summary)
    enriched = normalize(enriched, false)
    source_items = source |> action_items() |> List.to_tuple()
    enriched_items = enriched |> action_items() |> List.to_tuple()

    items =
      clean_summary
      |> action_items()
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {source_item, index}, acc ->
        case snapshot_item(
               source_item,
               tuple_at(source_items, index),
               tuple_at(enriched_items, index)
             ) do
          nil -> acc
          entry -> Map.put(acc, Integer.to_string(index), entry)
        end
      end)

    %{
      "version" => @version,
      "status" => "complete",
      "summary" => clean_summary,
      "summary_fingerprint" => fingerprint(clean_summary),
      "items" => items,
      "outcome" => if(map_size(items) > 0, do: "resolved", else: "unresolved"),
      "completed_at" => Keyword.get(opts, :completed_at, System.system_time(:millisecond))
    }
  end

  @doc "Return whether a value has the supported completed-snapshot envelope."
  @spec complete?(term()) :: boolean()
  def complete?(snapshot) when is_map(snapshot) do
    snapshot = normalize(snapshot, false)
    complete_normalized?(snapshot)
  end

  def complete?(_snapshot), do: false

  defp fetch_v2(snapshot) when is_map(snapshot) do
    snapshot = normalize(snapshot, false)

    cond do
      snapshot["version"] != @version ->
        {:error, {:unsupported_owner_attribution_version, snapshot["version"]}}

      complete_normalized?(snapshot) ->
        {:ok, snapshot}

      true ->
        {:error, :invalid_owner_attribution_v2}
    end
  end

  defp fetch_v2(_snapshot), do: {:error, :invalid_owner_attribution_v2}

  defp fetch_legacy(snapshot) when is_map(snapshot) do
    snapshot = normalize(snapshot, false)

    if snapshot["version"] == @legacy_version and complete_normalized?(snapshot),
      do: {:ok, upgrade_legacy(snapshot)},
      else: :missing
  end

  defp fetch_legacy(_snapshot), do: :missing

  defp snapshot_version(%{} = snapshot), do: snapshot["version"] || snapshot[:version]
  defp snapshot_version(_snapshot), do: nil

  defp upgrade_legacy(snapshot) do
    items =
      Map.new(snapshot["items"], fn {index, entry} ->
        {index,
         %{
           "provider" => "slack",
           "user_id" => entry["slack_id"],
           "display_name" => "",
           "item_fingerprint" => entry["item_fingerprint"]
         }}
      end)

    snapshot
    |> Map.put("version", @version)
    |> Map.put("items", items)
  end

  defp legacy_mirror(snapshot) do
    items =
      snapshot["items"]
      |> Enum.flat_map(fn {index, entry} ->
        case provider_identity(entry, @version) do
          %{"provider" => "slack", "user_id" => id} ->
            [
              {index,
               %{
                 "slack_id" => id,
                 "item_fingerprint" => entry["item_fingerprint"]
               }}
            ]

          _ ->
            []
        end
      end)
      |> Map.new()

    snapshot
    |> Map.take(~w(status summary summary_fingerprint completed_at))
    |> Map.put("version", @legacy_version)
    |> Map.put("items", items)
    |> Map.put("outcome", if(map_size(items) > 0, do: "resolved", else: "unresolved"))
  end

  defp complete_normalized?(snapshot) do
    items = snapshot["items"]
    summary = snapshot["summary"]

    snapshot["version"] in [@legacy_version, @version] and
      snapshot["status"] == "complete" and
      is_map(summary) and snapshot["summary_fingerprint"] == fingerprint(summary) and
      valid_items?(items, summary, snapshot["version"]) and
      snapshot["outcome"] == if(map_size(items) > 0, do: "resolved", else: "unresolved") and
      is_integer(snapshot["completed_at"]) and snapshot["completed_at"] >= 0
  end

  @doc "Return the immutable snapshot-bound summary, or a sanitized fallback."
  @spec bound_summary(term(), term()) :: term()
  def bound_summary(snapshot, fallback) when is_map(snapshot) do
    snapshot = normalize(snapshot, false)

    if complete_normalized?(snapshot) do
      snapshot["summary"]
    else
      sanitize_summary(fallback)
    end
  end

  def bound_summary(_snapshot, fallback), do: sanitize_summary(fallback)

  @doc "Return all trusted zero-based action-item Slack ids after one snapshot validation pass."
  @spec slack_ids_for(term(), term()) :: %{optional(non_neg_integer()) => String.t()}
  def slack_ids_for(snapshot, summary) when is_map(snapshot) do
    snapshot = normalize(snapshot, false)
    clean_summary = sanitize_summary(summary)

    if complete_normalized?(snapshot) and
         snapshot["summary_fingerprint"] == fingerprint(clean_summary) do
      Enum.reduce(snapshot["items"], %{}, fn {index, entry}, acc ->
        case parse_index(index) do
          {:ok, position} ->
            case provider_identity(entry, snapshot["version"]) do
              %{"provider" => "slack", "user_id" => id} -> Map.put(acc, position, id)
              _ -> acc
            end

          :error ->
            acc
        end
      end)
    else
      %{}
    end
  end

  def slack_ids_for(_snapshot, _summary), do: %{}

  @doc """
  Return the trusted Slack id for one current action item, or `nil`.

  Both the full sanitized summary and the item at the supplied index must match
  the completed snapshot. This prevents a late runtime summary update from
  applying an older attribution to changed or reordered meeting data.
  """
  @spec slack_id_for(term(), term(), non_neg_integer(), term()) :: String.t() | nil
  def slack_id_for(snapshot, summary, index, item)
      when is_integer(index) and index >= 0 and is_map(snapshot) do
    clean_summary = sanitize_summary(summary)
    item_fingerprint = fingerprint(item)
    summary_item = Enum.at(action_items(clean_summary), index, :missing)

    with true <- summary_item != :missing,
         true <- fingerprint(summary_item) == item_fingerprint,
         id when is_binary(id) <- Map.get(slack_ids_for(snapshot, clean_summary), index) do
      id
    else
      _ -> nil
    end
  end

  def slack_id_for(_snapshot, _summary, _index, _item), do: nil

  @doc "Return trusted provider identities keyed by zero-based action-item position."
  @spec provider_identities_for(term(), term(), String.t()) ::
          %{optional(non_neg_integer()) => map()}
  def provider_identities_for(snapshot, summary, provider)
      when is_map(snapshot) and is_binary(provider) do
    snapshot = normalize(snapshot, false)
    clean_summary = sanitize_summary(summary)

    if complete_normalized?(snapshot) and
         snapshot["summary_fingerprint"] == fingerprint(clean_summary) do
      Enum.reduce(snapshot["items"], %{}, fn {index, entry}, acc ->
        with {:ok, position} <- parse_index(index),
             %{"provider" => ^provider} = identity <-
               provider_identity(entry, snapshot["version"]) do
          Map.put(acc, position, identity)
        else
          _ -> acc
        end
      end)
    else
      %{}
    end
  end

  def provider_identities_for(_snapshot, _summary, _provider), do: %{}

  defp snapshot_item(source_item, raw_source_item, enriched_item)
       when is_map(source_item) and is_map(raw_source_item) and is_map(enriched_item) do
    source_fingerprint = fingerprint(source_item)
    enriched_fingerprint = fingerprint(enriched_item)
    identity = resolved_identity(enriched_item)

    if not Map.has_key?(raw_source_item, "owner_slack_id") and
         not Map.has_key?(raw_source_item, "owner_provider_identity") and
         source_fingerprint == enriched_fingerprint and is_map(identity) do
      Map.put(identity, "item_fingerprint", source_fingerprint)
    end
  end

  defp snapshot_item(_source_item, _raw_source_item, _enriched_item), do: nil

  defp action_items(%{"action_items" => items}) when is_list(items), do: items
  defp action_items(_summary), do: []

  defp tuple_at(tuple, index) when index < tuple_size(tuple), do: elem(tuple, index)
  defp tuple_at(_tuple, _index), do: nil

  defp normalize_slack_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_slack_id(_value), do: nil

  defp valid_slack_id?(id) when is_binary(id), do: Regex.match?(@slack_id_pattern, id)
  defp valid_slack_id?(_id), do: false

  defp valid_items?(items, summary, version) when is_map(items) and is_map(summary) do
    summary_items = summary |> action_items() |> List.to_tuple()

    Enum.all?(items, fn {index, entry} ->
      with true <- is_binary(index) and is_map(entry),
           %{"item_fingerprint" => item_fingerprint} <- entry,
           identity when is_map(identity) <- provider_identity(entry, version) do
        with {:ok, position} <- parse_index(index),
             item when is_map(item) <- tuple_at(summary_items, position),
             true <- item_fingerprint == fingerprint(item),
             true <- valid_provider_identity?(identity) do
          true
        else
          _ -> false
        end
      else
        _ -> false
      end
    end)
  end

  defp valid_items?(_items, _summary, _version), do: false

  defp resolved_identity(%{"owner_provider_identity" => identity}) when is_map(identity) do
    identity = normalize(identity, false)
    if valid_provider_identity?(identity), do: identity
  end

  defp resolved_identity(enriched_item) do
    case enriched_item |> Map.get("owner_slack_id") |> normalize_slack_id() do
      id when is_binary(id) ->
        identity = %{"provider" => "slack", "user_id" => id, "display_name" => ""}
        if valid_provider_identity?(identity), do: identity

      _ ->
        nil
    end
  end

  defp provider_identity(%{"slack_id" => id}, @legacy_version) do
    %{"provider" => "slack", "user_id" => id, "display_name" => ""}
  end

  defp provider_identity(entry, @version) when is_map(entry) do
    Map.take(entry, ~w(provider user_id display_name))
  end

  defp provider_identity(_entry, _version), do: nil

  defp valid_provider_identity?(%{
         "provider" => "slack",
         "user_id" => id,
         "display_name" => display_name
       }),
       do: valid_slack_id?(id) and valid_display_name?(display_name, true)

  defp valid_provider_identity?(%{
         "provider" => "feishu",
         "user_id" => id,
         "display_name" => display_name
       }),
       do:
         is_binary(id) and Regex.match?(@feishu_open_id_pattern, id) and
           valid_display_name?(display_name, false)

  defp valid_provider_identity?(_identity), do: false

  defp valid_display_name?(value, allow_blank?) when is_binary(value) do
    value = String.trim(value)
    (allow_blank? or value != "") and String.length(value) <= @max_display_name_graphemes
  end

  defp valid_display_name?(_value, _allow_blank?), do: false

  defp parse_index(index) do
    case Integer.parse(index) do
      {value, ""} when value >= 0 ->
        if Integer.to_string(value) == index, do: {:ok, value}, else: :error

      _other ->
        :error
    end
  end

  # Prefer an existing binary key over an atom/other key when normalization
  # produces a collision. Runtime JSON uses binary keys, while accepting atoms
  # here makes focused tests and internal callers safe and deterministic.
  defp normalize(value, strip_reserved?) when is_map(value) do
    value
    |> Enum.map(fn {key, child} ->
      {normalize_key(key), key_priority(key), normalize(child, strip_reserved?)}
    end)
    |> Enum.reject(fn {key, _priority, _child} ->
      strip_reserved? and MapSet.member?(@reserved_keys, key)
    end)
    |> Enum.sort_by(fn {key, priority, _child} -> {key, priority} end)
    |> Enum.reduce(%{}, fn {key, _priority, child}, acc -> Map.put_new(acc, key, child) end)
  end

  defp normalize(value, strip_reserved?) when is_list(value),
    do: Enum.map(value, &normalize(&1, strip_reserved?))

  defp normalize(value, _strip_reserved?)
       when is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value),
       do: value

  defp normalize(value, _strip_reserved?) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value, _strip_reserved?), do: inspect(value, limit: :infinity)

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key) or is_number(key), do: to_string(key)
  defp normalize_key(key), do: inspect(key, limit: :infinity)

  defp key_priority(key) when is_binary(key), do: 0
  defp key_priority(key) when is_atom(key), do: 1
  defp key_priority(_key), do: 2

  # Tagged arrays keep map-key order explicit before JSON encoding, so the hash
  # is stable across map construction order and Erlang map implementations.
  defp canonical(value) when is_map(value) do
    [
      "map",
      value
      |> Enum.sort_by(fn {key, _child} -> key end)
      |> Enum.map(fn {key, child} -> [key, canonical(child)] end)
    ]
  end

  defp canonical(value) when is_list(value), do: ["list", Enum.map(value, &canonical/1)]
  defp canonical(value) when is_binary(value), do: ["string", value]
  defp canonical(value) when is_integer(value), do: ["integer", Integer.to_string(value)]

  defp canonical(value) when is_float(value),
    do: ["float", :erlang.float_to_binary(value, [:short])]

  defp canonical(true), do: ["boolean", true]
  defp canonical(false), do: ["boolean", false]
  defp canonical(nil), do: ["null"]
end
