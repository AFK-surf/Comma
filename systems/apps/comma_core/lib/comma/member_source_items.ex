defmodule Comma.MemberSourceItems do
  @moduledoc """
  The member's pool of normalized source items: mail, messages, pull requests,
  issues, documents and events that reach the member through their connected
  sources.

  Source collection is the only writer of item content. Consumers read the
  items that arrived or changed, and each consumer records its own outcome.
  The pool keeps bounded excerpts, never raw provider payloads. An item expires
  5 days after collection last saw it. Revoking, removing or turning off a
  source, or leaving member mode, deletes its items at once.
  """

  import Ecto.Query
  alias Comma.Repo
  alias Comma.Data.{MemberSourceItem, MemberSourceState, RecommendationProfile, Workspace}

  @retention_days 5
  @per_source_limit 400
  # A still-present item refreshes its last-seen time a few times a day, not on
  # every collection, so retention does not rewrite every row on every check.
  @touch_after_s 6 * 60 * 60
  @content ~w(toolkit url app title excerpt context prompt_context relationship recipient facts provider_ids fingerprint)a

  def retention_days, do: @retention_days

  @doc """
  Records one collection and deletes the items and states of sources the
  profile no longer enables.

  `collection.collected` maps a source ID to its `"toolkit"`, `"app"`,
  `"subject"`, `"bound"`, optional partial-read `"warning"` and normalized
  `"items"`. `collection.failed` maps a source ID to its failure; a failed
  source keeps its items and its last successful state. A source collected for
  the first time, or not collected for the retention period, is a baseline:
  its items are history, not arrivals. Returns the arrivals and changes
  consumers will see.
  """
  def record(profile_id, collection, enabled_source_ids, now \\ DateTime.utc_now())
      when is_binary(profile_id) and is_list(enabled_source_ids) do
    Repo.transaction(fn ->
      # The provider read may predate a settings change. Only the locked
      # profile's current member selection can admit or retain source items.
      profile =
        Repo.one!(
          from(p in RecommendationProfile, where: p.id == ^profile_id, lock: "FOR UPDATE")
        )

      current = if profile.relevance_mode == "generic", do: [], else: enabled_source_ids(profile)
      admitted = Enum.filter(enabled_source_ids, &(&1 in current))
      collected = Map.take(collection[:collected] || %{}, admitted)

      failed =
        (collection[:failed] || %{})
        |> Map.take(admitted)
        |> Map.drop(Map.keys(collected))

      :ok = retain_sources(profile_id, current)

      states =
        from(s in MemberSourceState, where: s.profile_id == ^profile_id)
        |> Repo.all()
        |> Map.new(&{&1.source_id, &1})

      counts =
        Enum.reduce(collected, %{new: 0, changed: 0}, fn {source_id, source}, counts ->
          state = states[source_id]
          baseline = baseline?(state, now)
          recorded = record_source(profile_id, source_id, source["items"] || [], baseline, now)
          keys = source["items"] |> List.wrap() |> Enum.map(& &1["item_key"]) |> Enum.uniq()

          put_state(state, profile_id, source_id, now, %{
            toolkit: source["toolkit"],
            app: source["app"] || "",
            subject: source["subject"],
            bound: source["bound"],
            failure: source["warning"],
            current_keys: keys,
            collected_at: now,
            baseline_at: if(baseline, do: now, else: state.baseline_at)
          })

          if baseline,
            do: counts,
            else: %{new: counts.new + recorded.new, changed: counts.changed + recorded.changed}
        end)

      for {source_id, failure} <- failed do
        state = states[source_id]

        put_state(state, profile_id, source_id, now, %{
          toolkit: (state && state.toolkit) || failure["toolkit"] || failure["appId"] || "",
          failure: failure
        })
      end

      counts
    end)
  end

  @doc "The IDs of the sources that the profile enables for collection."
  def enabled_source_ids(%RecommendationProfile{sources: sources}),
    do: for(%{"enabled" => true, "connectionId" => id} <- sources || [], is_binary(id), do: id)

  @doc """
  Deletes the items and states of every source outside `source_ids`, such as
  a source the member turned off. Recording checks the current profile under
  its lock, so a late read cannot restore a disabled source.
  """
  def retain_sources(profile_id, source_ids) when is_binary(profile_id) and is_list(source_ids) do
    for schema <- [MemberSourceItem, MemberSourceState] do
      from(r in schema, where: r.profile_id == ^profile_id and r.source_id not in ^source_ids)
      |> Repo.delete_all()
    end

    :ok
  end

  # A first collection, or one after the retention period, is a baseline: the
  # sweep may have deleted its history, which must not return as arrivals.
  defp baseline?(%MemberSourceState{collected_at: %DateTime{} = collected}, now),
    do: DateTime.diff(now, collected, :second) > @retention_days * 86_400

  defp baseline?(_state, _now), do: true

  defp put_state(nil, profile_id, source_id, now, attrs) do
    Repo.insert!(
      struct(
        MemberSourceState,
        Map.merge(attrs, %{profile_id: profile_id, source_id: source_id, attempted_at: now})
      )
    )
  end

  defp put_state(state, _profile_id, _source_id, now, attrs) do
    state
    |> Ecto.Changeset.change(Map.put(attrs, :attempted_at, now))
    |> Repo.update!()
  end

  @doc """
  The profile's sources and their items present in each source's latest
  successful collection, in the order the source returned them. A source
  whose latest attempt failed reports its failure and no items.
  """
  def current(profile_id) do
    states = Repo.all(from(s in MemberSourceState, where: s.profile_id == ^profile_id))
    keys = Enum.flat_map(states, & &1.current_keys)

    items =
      from(i in MemberSourceItem, where: i.profile_id == ^profile_id and i.item_key in ^keys)
      |> Repo.all()
      |> Map.new(&{{&1.source_id, &1.item_key}, &1})

    Enum.map(states, fn state ->
      collected = not is_nil(state.collected_at) and not failed_latest?(state)

      # Items keep the order in which the source returned them.
      items =
        if collected,
          do: Enum.flat_map(state.current_keys, &List.wrap(items[{state.source_id, &1}])),
          else: []

      %{state: state, items: items, collected: collected}
    end)
  end

  # A partial read keeps its warning with a successful collection time. Only an
  # attempt newer than the last success failed as a whole.
  defp failed_latest?(%MemberSourceState{failure: nil}), do: false

  defp failed_latest?(state),
    do:
      is_nil(state.collected_at) or
        DateTime.compare(state.attempted_at, state.collected_at) == :gt

  @doc "Whether every enabled source was attempted within `max_age_s` seconds."
  def fresh?(profile_id, enabled_source_ids, max_age_s, now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -max_age_s, :second)

    attempted =
      from(s in MemberSourceState,
        where:
          s.profile_id == ^profile_id and s.source_id in ^enabled_source_ids and
            s.attempted_at >= ^cutoff,
        select: count(s.id)
      )
      |> Repo.one()

    attempted == length(Enum.uniq(enabled_source_ids))
  end

  @doc "Collected sources of these toolkits that have no provider trigger yet."
  def untriggered(profile_id, toolkits) when is_list(toolkits) do
    from(s in MemberSourceState,
      where:
        s.profile_id == ^profile_id and s.toolkit in ^toolkits and is_nil(s.trigger_id) and
          not is_nil(s.collected_at)
    )
    |> Repo.all()
  end

  @doc "Records the provider trigger that signals changes of one source."
  def put_trigger(%MemberSourceState{id: id}, trigger_id) when is_binary(trigger_id) do
    from(s in MemberSourceState, where: s.id == ^id)
    |> Repo.update_all(set: [trigger_id: trigger_id])

    :ok
  end

  @doc """
  The pooled sources that a provider trigger event names: the trigger, its
  connected account as the source, and the Salix group of the workspace.
  """
  def triggered(trigger_id, source_id, group_id) do
    from(s in MemberSourceState,
      join: p in RecommendationProfile,
      on: p.id == s.profile_id,
      join: w in Workspace,
      on: w.id == p.workspace_id,
      where:
        s.trigger_id == ^trigger_id and s.source_id == ^source_id and
          w.salix_group_id == ^group_id,
      select: %{profile_id: s.profile_id, source_id: s.source_id, attempted_at: s.attempted_at}
    )
    |> Repo.all()
  end

  defp record_source(profile_id, source_id, items, baseline, now) do
    items = items |> Enum.map(&bounded/1) |> Enum.uniq_by(& &1.item_key)
    keys = Enum.map(items, & &1.item_key)

    existing =
      from(i in MemberSourceItem,
        where: i.profile_id == ^profile_id and i.source_id == ^source_id and i.item_key in ^keys,
        select: {i.item_key, {i.id, i.fingerprint}}
      )
      |> Repo.all()
      |> Map.new()

    {fresh, known} = Enum.split_with(items, &(not Map.has_key?(existing, &1.item_key)))

    {changed, unchanged} =
      Enum.split_with(known, &(elem(existing[&1.item_key], 1) != &1.fingerprint))

    Repo.insert_all(
      MemberSourceItem,
      Enum.map(fresh, fn item ->
        Map.merge(item, %{
          id: Ecto.UUID.generate(),
          profile_id: profile_id,
          source_id: source_id,
          baseline: baseline,
          first_seen_at: now,
          last_seen_at: now,
          changed_at: now
        })
      end)
    )

    # Changed source text is new evidence: the item returns to every consumer,
    # unless this recording is a baseline.
    for item <- changed do
      {id, _fingerprint} = existing[item.item_key]

      from(i in MemberSourceItem, where: i.id == ^id)
      |> Repo.update_all(
        set:
          Enum.to_list(Map.take(item, @content)) ++
            [baseline: baseline, attention: nil, changed_at: now, last_seen_at: now]
      )
    end

    stale = DateTime.add(now, -@touch_after_s, :second)
    unchanged_ids = Enum.map(unchanged, &elem(existing[&1.item_key], 0))

    from(i in MemberSourceItem, where: i.id in ^unchanged_ids and i.last_seen_at < ^stale)
    |> Repo.update_all(set: [last_seen_at: now])

    keep =
      from(i in MemberSourceItem,
        where: i.profile_id == ^profile_id and i.source_id == ^source_id,
        order_by: [desc: i.last_seen_at, desc: i.id],
        limit: @per_source_limit,
        select: i.id
      )

    from(i in MemberSourceItem,
      where:
        i.profile_id == ^profile_id and i.source_id == ^source_id and
          i.id not in subquery(keep)
    )
    |> Repo.delete_all()

    %{new: length(fresh), changed: length(changed)}
  end

  # The pool stores excerpts. Collection normalizes items; these limits keep
  # every stored item bounded even if a source returns more.
  defp bounded(item) do
    content = %{
      item_key: item["item_key"],
      toolkit: item["toolkit"],
      url: String.slice(item["url"] || "", 0, 2_048),
      app: String.slice(item["app"] || "", 0, 80),
      title: String.slice(item["title"] || "", 0, 200),
      excerpt: String.slice(item["excerpt"] || "", 0, 1_200),
      context: bounded_map(item["context"], 1_200),
      prompt_context: String.slice(item["prompt_context"] || "", 0, 600),
      relationship: item["relationship"],
      recipient: item["recipient"],
      facts: bounded_map(item["facts"], 1_000) || %{},
      provider_ids: bounded_map(item["provider_ids"], 300) || %{}
    }

    # Version the complete stored evidence, not the shortened prompt alone.
    # Dates, roles and surrounding context can change the required action.
    version = Enum.map(@content -- [:fingerprint], &[&1, content[&1]])
    fingerprint = :crypto.hash(:sha256, Jason.encode!(version)) |> Base.encode16(case: :lower)
    Map.put(content, :fingerprint, fingerprint)
  end

  defp bounded_map(value, limit) when is_map(value) do
    if byte_size(Jason.encode!(value)) <= limit,
      do: value,
      else: %{"text" => value |> Jason.encode!() |> String.slice(0, limit), "truncated" => true}
  end

  defp bounded_map(_value, _limit), do: nil

  # An arrived or changed item without an outcome waits for consumers while
  # its source's latest successful collection still returns it and no later
  # attempt failed as a whole. Mail the member answered, or a thread that no
  # longer needs them, leaves the result and stops waiting.
  defp pending_items(profile_id) do
    from(i in MemberSourceItem,
      join: s in MemberSourceState,
      on: s.profile_id == i.profile_id and s.source_id == i.source_id,
      where:
        i.profile_id == ^profile_id and is_nil(i.attention) and not i.baseline and
          fragment("? = ANY(?)", i.item_key, s.current_keys) and
          (is_nil(s.failure) or s.attempted_at <= s.collected_at)
    )
  end

  @doc "Whether the profile has items no consumer outcome covers yet."
  def pending?(profile_id), do: Repo.exists?(pending_items(profile_id))

  @doc "Up to `limit` arrived or changed items without an outcome, taken from the sources in turn."
  def pending(profile_id, limit) do
    from(i in pending_items(profile_id),
      order_by: [asc: i.changed_at, asc: i.id],
      limit: ^(limit * 3)
    )
    |> Repo.all()
    |> Enum.group_by(& &1.source_id)
    |> Map.values()
    |> Enum.flat_map(&Enum.with_index/1)
    |> Enum.sort_by(fn {item, index} ->
      {index, DateTime.to_unix(item.changed_at, :microsecond)}
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(limit)
  end

  @doc """
  Runs `fun` only while the item still waits, unchanged since the consumer
  read it, and returns its `{:ok, result}` or `{:error, reason}`. The item and
  its source state stay locked until `fun` returns. A revocation, a source
  turned off or a collection that withdraws the item therefore commits either
  before the check, and `fun` does not run (`{:error, :withdrawn}`), or after
  `fun`.
  """
  def while_pending(%MemberSourceItem{} = item, fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      waiting =
        from([i] in pending_items(item.profile_id),
          where: i.id == ^item.id and i.fingerprint == ^item.fingerprint,
          select: i.id,
          lock: "FOR SHARE"
        )
        |> Repo.one()

      with id when is_binary(id) <- waiting,
           {:ok, result} <- fun.() do
        result
      else
        nil -> Repo.rollback(:withdrawn)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Records one consumer outcome for items it judged. An item that collection
  changed in the meantime keeps no outcome and is judged again.
  """
  def settle(items, attention) when is_list(items) and is_map(attention) do
    Enum.each(items, fn %MemberSourceItem{id: id, fingerprint: fingerprint} ->
      from(i in MemberSourceItem, where: i.id == ^id and i.fingerprint == ^fingerprint)
      |> Repo.update_all(set: [attention: attention])
    end)
  end

  @doc """
  Deletes the items and state of one revoked account, for one member or the
  whole workspace. A reconnected account records a new baseline.
  """
  def purge_source(workspace_id, source_id, user_id \\ nil) do
    with_locked_profiles(workspace_id, user_id, fn ids ->
      for schema <- [MemberSourceItem, MemberSourceState] do
        from(r in schema, where: r.source_id == ^source_id and r.profile_id in ^ids)
        |> Repo.delete_all()
      end
    end)
  end

  @doc """
  Deletes the profile's items and source states, so the next collection
  records a new baseline.
  """
  def reset(profile_id) do
    for schema <- [MemberSourceItem, MemberSourceState] do
      from(r in schema, where: r.profile_id == ^profile_id) |> Repo.delete_all()
    end

    :ok
  end

  @doc "Deletes the workspace's items and states from removed apps."
  def purge_toolkits(workspace_id, toolkits) when is_list(toolkits) do
    with_locked_profiles(workspace_id, nil, fn ids ->
      for schema <- [MemberSourceItem, MemberSourceState] do
        from(r in schema, where: r.toolkit in ^toolkits and r.profile_id in ^ids)
        |> Repo.delete_all()
      end
    end)
  end

  # Collection validates consent while holding this same profile lock.
  # A purge must finish after any already-admitted recording, not before it.
  defp with_locked_profiles(workspace_id, user_id, fun) do
    {:ok, _} =
      Repo.transaction(fn ->
        ids =
          profiles(workspace_id, user_id)
          |> order_by([p], p.id)
          |> lock("FOR UPDATE")
          |> Repo.all()

        fun.(ids)
      end)

    :ok
  end

  defp profiles(workspace_id, nil),
    do: from(p in RecommendationProfile, where: p.workspace_id == ^workspace_id, select: p.id)

  defp profiles(workspace_id, user_id),
    do:
      from(p in RecommendationProfile,
        where: p.workspace_id == ^workspace_id and p.user_id == ^user_id,
        select: p.id
      )

  @doc "Deletes up to `batch` items that collection has not seen for the retention period."
  def expire(now \\ DateTime.utc_now(), batch \\ 1_000) do
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)

    ids =
      from(i in MemberSourceItem, where: i.last_seen_at < ^cutoff, limit: ^batch, select: i.id)

    {count, _} = from(i in MemberSourceItem, where: i.id in subquery(ids)) |> Repo.delete_all()
    count
  end
end
