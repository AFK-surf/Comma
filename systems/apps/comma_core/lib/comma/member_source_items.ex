defmodule Comma.MemberSourceItems do
  @moduledoc """
  The member's pool of normalized source items: mail, messages, pull requests,
  issues, documents and events that reach the member through their connected
  sources.

  Source collection is the only writer of item content. Consumers read the
  items that arrived or changed, and each consumer records its own outcome.
  The pool keeps bounded excerpts, never raw provider payloads. An item expires
  5 days after collection last saw it. Revoking, removing or turning off a
  source, or leaving member mode, deletes its items and open threads at once.
  """

  import Ecto.Query
  alias Comma.Repo

  alias Comma.Data.{
    MemberSourceItem,
    MemberSourceState,
    OpenThread,
    OpenThreadCursor,
    RecommendationProfile,
    Workspace
  }

  @retention_days 5
  # An unusable judgment keeps an item waiting for at most this many attempts.
  @judge_attempts 3
  # A retryable item from a rolling-window or truncated source keeps a bounded
  # recovery window even when a later collection's top-N page or 24-hour slice
  # no longer includes its key. Non-truncated mailbox reads reflect the live
  # inbox, so mail the member archived or answered still withdraws at once.
  @off_window_retry_failures 3
  @off_window_retry_s 48 * 60 * 60
  # A matter that waits for a closed budget is judged again at its `next_at`,
  # at most this many times. Its own due time (`due_at`) wakes it apart from
  # that bound: each judgment sets the next one, at most twice per due time.
  @rechecks 4
  @per_source_limit 400
  # A still-present item refreshes its last-seen time a few times a day, not on
  # every collection, so retention does not rewrite every row on every check.
  @touch_after_s 6 * 60 * 60
  # A source's open threads (`Comma.OpenThreads`) leave with its items.
  @source_schemas [MemberSourceItem, MemberSourceState, OpenThread, OpenThreadCursor]
  @content ~w(toolkit url app title excerpt context prompt_context relationship recipient facts provider_ids fingerprint)a
  # Version prefix for the per-item independent fingerprint format. Existing
  # pre-v2 rows rebase silently once on first collection without triggering
  # `changed` or clearing `baseline`/`attention`.
  @fingerprint_version "v2:"

  def retention_days, do: @retention_days
  def judge_attempts, do: @judge_attempts
  def rechecks, do: @rechecks

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
  def record(profile_id, collection, enabled_source_ids, now \\ SystemsClock.utc_now())
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
          truncated? = get_in(source, ["bound", "truncated"]) == true
          items = source["items"] || []
          recorded = record_source(profile_id, source_id, items, baseline, truncated?, now)
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
  Deletes the items, states and open threads of every source outside
  `source_ids`, such as a source the member turned off. Recording checks the
  current profile under its lock, so a late read cannot restore a disabled
  source.
  """
  def retain_sources(profile_id, source_ids) when is_binary(profile_id) and is_list(source_ids) do
    for schema <- @source_schemas do
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

  @doc """
  At most `limit` newest items belonging to currently collected, non-failed
  sources of `profile_id`, bounded directly in SQL.
  """
  def current_recent(profile_id, limit)
      when is_binary(profile_id) and is_integer(limit) and limit > 0 do
    from(i in MemberSourceItem,
      join: s in MemberSourceState,
      on: s.profile_id == i.profile_id and s.source_id == i.source_id,
      where:
        i.profile_id == ^profile_id and
          not is_nil(s.collected_at) and
          (is_nil(s.failure) or s.attempted_at <= s.collected_at) and
          fragment("? = ANY(?)", i.item_key, s.current_keys),
      order_by: [desc: i.changed_at, asc: i.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  # A partial read keeps its warning with a successful collection time. Only an
  # attempt newer than the last success failed as a whole.
  defp failed_latest?(%MemberSourceState{failure: nil}), do: false

  defp failed_latest?(state),
    do:
      is_nil(state.collected_at) or
        DateTime.compare(state.attempted_at, state.collected_at) == :gt

  @doc """
  The owner's pool item for one source URL in a Workspace, or nil. The Router
  reads it for a matter the check handed over before a Routine snapshot names it.
  """
  def find(workspace_id, user_id, source_id, url) do
    from(i in MemberSourceItem,
      join: p in RecommendationProfile,
      on: p.id == i.profile_id,
      where:
        p.workspace_id == ^workspace_id and p.user_id == ^user_id and
          i.source_id == ^source_id and i.url == ^url,
      order_by: [desc: i.changed_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Whether every enabled source was attempted within `max_age_s` seconds."
  def fresh?(profile_id, enabled_source_ids, max_age_s, now \\ SystemsClock.utc_now()) do
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

  @doc "The profile's source states, in a stable display order."
  def states(profile_id) do
    from(s in MemberSourceState,
      where: s.profile_id == ^profile_id,
      order_by: [asc: s.app, asc: s.source_id]
    )
    |> Repo.all()
  end

  @doc """
  Up to `limit` items that a consumer judged, latest judgment first. The pool
  holds at most #{@per_source_limit} items per source for #{@retention_days}
  days, so the read is bounded by the owner's enabled sources.
  """
  def judged(profile_id, limit) when is_integer(limit) and limit > 0 do
    from(i in MemberSourceItem,
      where: i.profile_id == ^profile_id and not is_nil(i.attention),
      order_by: [desc: fragment("(?->>'at')::bigint", i.attention), desc: i.id],
      limit: ^limit
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

  defp record_source(profile_id, source_id, items, baseline, truncated?, now) do
    items = items |> Enum.map(&bounded/1) |> Enum.uniq_by(& &1.item_key)
    keys = Enum.map(items, & &1.item_key)

    existing =
      from(i in MemberSourceItem,
        where: i.profile_id == ^profile_id and i.source_id == ^source_id and i.item_key in ^keys,
        select: {i.item_key, {i.id, i.fingerprint, i.quote, i.facts}}
      )
      |> Repo.all()
      |> Map.new()

    {fresh, known} = Enum.split_with(items, &(not Map.has_key?(existing, &1.item_key)))

    {rebased, current_version} =
      Enum.split_with(known, fn item ->
        not String.starts_with?(elem(existing[item.item_key], 1), @fingerprint_version)
      end)

    {changed, unchanged} =
      Enum.split_with(current_version, &(elem(existing[&1.item_key], 1) != &1.fingerprint))

    Repo.insert_all(
      MemberSourceItem,
      Enum.map(fresh, fn item ->
        Map.merge(item, %{
          id: SystemsRuntime.Proc.uuid(),
          profile_id: profile_id,
          source_id: source_id,
          baseline: baseline,
          first_seen_at: now,
          last_seen_at: now,
          changed_at: now
        })
      end)
    )

    # One-time version rebase: refresh stored content and fingerprint without
    # disturbing `baseline`, `attention` or `changed_at`, so deploy does not
    # re-queue previously baselined or settled items in bulk.
    for item <- rebased do
      {id, _fingerprint, _quoted, _facts} = existing[item.item_key]

      from(i in MemberSourceItem, where: i.id == ^id)
      |> Repo.update_all(
        set: Enum.to_list(Map.take(item, [:quote | @content])) ++ [last_seen_at: now]
      )
    end

    # Changed source text is new evidence: the item returns to every consumer,
    # unless this recording is a baseline.
    for item <- changed do
      {id, _fingerprint, _quoted, _facts} = existing[item.item_key]

      from(i in MemberSourceItem, where: i.id == ^id)
      |> Repo.update_all(
        set:
          Enum.to_list(Map.take(item, [:quote | @content])) ++
            [baseline: baseline, attention: nil, changed_at: now, last_seen_at: now]
      )
    end

    # The quote is display text, not evidence, and calendar prep facts
    # (`attendeeCount` / `attendeesSummary`) are excluded from the fingerprint
    # so rollout or attendee refreshes do not re-screen settled rows. Refresh
    # changed quote/facts in place while keeping version, outcomes, and queue order.
    for item <- unchanged,
        {id, _fingerprint, quote, facts} = existing[item.item_key],
        updates =
          if(quote != item.quote, do: [quote: item.quote], else: []) ++
            if(facts != item.facts, do: [facts: item.facts], else: []),
        updates != [] do
      from(i in MemberSourceItem, where: i.id == ^id)
      |> Repo.update_all(set: updates)
    end

    stale = DateTime.add(now, -@touch_after_s, :second)
    unchanged_ids = Enum.map(unchanged, &elem(existing[&1.item_key], 0))

    from(i in MemberSourceItem, where: i.id in ^unchanged_ids and i.last_seen_at < ^stale)
    |> Repo.update_all(set: [last_seen_at: now])

    retry_cutoff = DateTime.add(now, -@off_window_retry_s, :second)

    # The cap keeps first what can still wait for a consumer (`pending_items/1`):
    # a retry still in this page or in its recovery window, a deferred or
    # waiting matter that a recheck or its due time can wake, and a quiet
    # matter with a due time. Unjudged arrivals come next, then settled history.
    keep =
      from(i in MemberSourceItem,
        where: i.profile_id == ^profile_id and i.source_id == ^source_id,
        order_by: [
          desc:
            fragment(
              """
              CASE
                WHEN NOT ? AND (
                  (coalesce(?->>'outcome', '') = 'retry'
                    AND coalesce((?->>'attempts')::int, 0) < ?
                    AND (? = ANY(?)
                      OR (coalesce((?->>'failures')::int, 0) < ?
                        AND ? >= ?
                        AND (? NOT IN ('gmail', 'outlook') OR ?))))
                  OR (coalesce(?->>'outcome', '') IN ('deferred', 'waiting')
                    AND (coalesce((?->>'rechecks')::int, 0) < ? OR ?->>'due_at' IS NOT NULL))
                  OR (coalesce(?->>'outcome', '') = 'quiet' AND ?->>'due_at' IS NOT NULL)
                ) THEN 2
                WHEN NOT ? AND ? IS NULL THEN 1
                ELSE 0
              END
              """,
              i.baseline,
              i.attention,
              i.attention,
              ^@judge_attempts,
              i.item_key,
              type(^keys, {:array, :string}),
              i.attention,
              ^@off_window_retry_failures,
              i.changed_at,
              ^retry_cutoff,
              i.toolkit,
              ^truncated?,
              i.attention,
              i.attention,
              ^@rechecks,
              i.attention,
              i.attention,
              i.attention,
              i.baseline,
              i.attention
            ),
          desc: i.last_seen_at,
          desc: i.id
        ],
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
      context: bounded_map(item["context"], 1_600),
      prompt_context: String.slice(item["prompt_context"] || "", 0, 600),
      quote: bounded_quote(item["quote"]),
      relationship: item["relationship"],
      recipient: item["recipient"],
      facts: bounded_map(item["facts"], 1_000) || %{},
      provider_ids: bounded_map(item["provider_ids"], 1_200) || %{}
    }

    # Version the complete stored evidence, not the shortened prompt alone.
    # Dates, roles and surrounding context can change the required action.
    # The quote is display text outside the version; prep-only attendee facts
    # are excluded from the version so adding them does not force one-time
    # re-screening of already-settled calendar rows on rollout.
    fp_content = fingerprint_content(content)
    version = Enum.map(@content -- [:fingerprint], &[&1, fp_content[&1]])
    digest = :crypto.hash(:sha256, Jason.encode!(version)) |> Base.encode16(case: :lower)
    # Keep within RecommendationContract's 64-character `sourceVersion` cap.
    fingerprint = @fingerprint_version <> binary_part(digest, 0, 61)
    Map.put(content, :fingerprint, fingerprint)
  end

  defp fingerprint_content(%{toolkit: toolkit} = content)
       when toolkit in ~w(googlecalendar outlook) do
    content
    |> Map.update(:facts, %{}, fn
      %{} = facts -> Map.drop(facts, ~w(attendeeCount attendeesSummary))
      other -> other
    end)
    |> Map.update(:context, nil, fn
      %{} = ctx -> Map.drop(ctx, ~w(attendeeCount))
      other -> other
    end)
  end

  defp fingerprint_content(content), do: content

  defp bounded_map(value, limit) when is_map(value) do
    if byte_size(Jason.encode!(value)) <= limit,
      do: value,
      else: %{"text" => value |> Jason.encode!() |> String.slice(0, limit), "truncated" => true}
  end

  defp bounded_map(_value, _limit), do: nil

  # Collection bounds a quote's lines. A larger quote is not stored.
  defp bounded_quote(quote) when is_map(quote) and map_size(quote) > 0,
    do: if(byte_size(Jason.encode!(quote)) <= 4_000, do: quote)

  defp bounded_quote(_quote), do: nil

  # An arrived or changed item without an outcome waits for consumers while
  # its source's latest successful collection still returns it and no later
  # attempt failed as a whole. A retryable item from a rolling-window source or
  # a truncated read keeps a bounded recovery window after its key leaves the
  # latest page; mail the member answered in a non-truncated mailbox read
  # stops waiting at once. A judged item waits again from its budget `next_at`
  # or its `due_at`.
  defp pending_items(profile_id) do
    now = SystemsClock.system_time(:millisecond)

    from(i in MemberSourceItem,
      join: s in MemberSourceState,
      on: s.profile_id == i.profile_id and s.source_id == i.source_id,
      where:
        i.profile_id == ^profile_id and
          not i.baseline and
          not is_nil(s.collected_at) and
          (is_nil(s.failure) or s.attempted_at <= s.collected_at) and
          (((is_nil(i.attention) or
               fragment("?->>'outcome' IS NULL", i.attention) or
               (fragment("?->>'outcome'", i.attention) == "retry" and
                  fragment("coalesce((?->>'attempts')::int, 0)", i.attention) < ^@judge_attempts) or
               (fragment("?->>'outcome'", i.attention) in ["deferred", "waiting"] and
                  fragment("(?->>'next_at')::bigint", i.attention) <= ^now and
                  fragment("coalesce((?->>'rechecks')::int, 0)", i.attention) < ^@rechecks) or
               (fragment("?->>'outcome'", i.attention) in ["deferred", "waiting", "quiet"] and
                  fragment("(?->>'due_at')::bigint", i.attention) <= ^now)) and
              fragment("? = ANY(?)", i.item_key, s.current_keys)) or
             (fragment("?->>'outcome'", i.attention) == "retry" and
                fragment("coalesce((?->>'attempts')::int, 0)", i.attention) < ^@judge_attempts and
                fragment("coalesce((?->>'failures')::int, 0)", i.attention) <
                  ^@off_window_retry_failures and
                fragment(
                  "? >= ? - make_interval(secs => ?)",
                  i.changed_at,
                  s.collected_at,
                  ^@off_window_retry_s
                ) and
                (i.toolkit not in ["gmail", "outlook"] or
                   fragment("coalesce(?->>'truncated', '') = 'true'", s.bound))))
    )
  end

  @doc "Whether the profile has items no consumer outcome covers yet."
  def pending?(profile_id), do: Repo.exists?(pending_items(profile_id))

  @doc "Up to `limit` arrived or changed items without an outcome, taken from the sources in turn."
  def pending(profile_id, limit) do
    # Items retried after an unusable judgment come after new arrivals.
    from(i in pending_items(profile_id),
      order_by: [
        asc: not is_nil(fragment("?->>'outcome'", i.attention)),
        asc: i.changed_at,
        asc: i.id
      ],
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
  Runs `fun` only while `item` still exists unchanged in a collected,
  non-failed source (`FOR SHARE` lock on item and source state). Used by
  time-driven triggers (such as pre-meeting prep) that fire on already
  settled or baseline calendar rows.
  """
  def while_current(%MemberSourceItem{} = item, fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      current =
        from(i in MemberSourceItem,
          join: s in MemberSourceState,
          on: s.profile_id == i.profile_id and s.source_id == i.source_id,
          where:
            i.id == ^item.id and
              i.profile_id == ^item.profile_id and
              i.fingerprint == ^item.fingerprint and
              not is_nil(s.collected_at) and
              (is_nil(s.failure) or s.attempted_at <= s.collected_at) and
              fragment("? = ANY(?)", i.item_key, s.current_keys),
          select: i.id,
          lock: "FOR SHARE"
        )
        |> Repo.one()

      with id when is_binary(id) <- current,
           {:ok, result} <- fun.() do
        result
      else
        nil -> Repo.rollback(:withdrawn)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Records one consumer outcome for items it judged, atomically preserving any
  existing `prep_*` meeting-prep fields in SQL so primary settlement and
  meeting-prep updates cannot overwrite each other. An item that collection
  changed in the meantime keeps no outcome and is judged again.
  """
  def settle(items, attention) when is_list(items) and is_map(attention) do
    Enum.each(items, fn %MemberSourceItem{id: id, fingerprint: fingerprint} ->
      from(i in MemberSourceItem,
        where: i.id == ^id and i.fingerprint == ^fingerprint,
        update: [
          set: [
            attention:
              fragment(
                "jsonb_strip_nulls(jsonb_build_object('prep_start_ms', ?->'prep_start_ms', 'prep_checked_at', ?->'prep_checked_at', 'prep_deferred_start_ms', ?->'prep_deferred_start_ms', 'prep_deferred_until', ?->'prep_deferred_until')) || ?::jsonb",
                i.attention,
                i.attention,
                i.attention,
                i.attention,
                ^attention
              )
          ]
        ]
      )
      |> Repo.update_all([])
    end)
  end

  @doc """
  Atomically merges `patch` into the item's JSONB `attention` map without
  overwriting unrelated keys (such as `outcome`, `assessment`, or `due_at`),
  only while `fingerprint` matches.
  """
  def merge_attention(%MemberSourceItem{id: id, fingerprint: fingerprint}, patch)
      when is_map(patch) do
    from(i in MemberSourceItem,
      where: i.id == ^id and i.fingerprint == ^fingerprint,
      update: [
        set: [
          attention: fragment("coalesce(?, '{}'::jsonb) || ?::jsonb", i.attention, ^patch)
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  @doc """
  Deletes the items and state of one revoked account, for one member or the
  whole workspace. A reconnected account records a new baseline.
  """
  def purge_source(workspace_id, source_id, user_id \\ nil) do
    with_locked_profiles(workspace_id, user_id, fn ids ->
      for schema <- @source_schemas do
        from(r in schema, where: r.source_id == ^source_id and r.profile_id in ^ids)
        |> Repo.delete_all()
      end
    end)
  end

  @doc """
  Deletes the profile's items, source states and open threads, so the next
  collection records a new baseline.
  """
  def reset(profile_id) do
    for schema <- @source_schemas do
      from(r in schema, where: r.profile_id == ^profile_id) |> Repo.delete_all()
    end

    :ok
  end

  @doc "Deletes the workspace's items, states and open threads from removed apps."
  def purge_toolkits(workspace_id, toolkits) when is_list(toolkits) do
    with_locked_profiles(workspace_id, nil, fn ids ->
      for schema <- @source_schemas do
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
  def expire(now \\ SystemsClock.utc_now(), batch \\ 1_000) do
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)

    ids =
      from(i in MemberSourceItem, where: i.last_seen_at < ^cutoff, limit: ^batch, select: i.id)

    {count, _} = from(i in MemberSourceItem, where: i.id in subquery(ids)) |> Repo.delete_all()
    count
  end
end
