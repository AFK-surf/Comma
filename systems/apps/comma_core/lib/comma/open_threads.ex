defmodule Comma.OpenThreads do
  @moduledoc """
  What the owner left open in their own messages: something they promised
  (`promised`), a question nobody answered yet (`asked`) or a problem they
  raised (`blocked`). One row is one such thread, identified by the profile,
  the source, the provider thread and the kind, so a later message in the same
  thread updates it instead of adding another.

  `CommaWeb.OpenThreads` is the only writer of content. The owner, through the
  Router, may mark a thread `resolved`, `dismissed` or `open` again. A thread
  the owner resolved or dismissed (`corrected_at`) keeps that status and its
  text until it expires: no extraction changes it, and the profile's bound
  never drops it, so a message still in the 30-day read window cannot bring
  it back. Marking it `open` returns it to the extraction. Silence never
  closes a thread; the notebook only stops listing one without news for a
  week (`CommaWeb.ProactiveNotebook`). A thread expires 45 days after its latest evidence: readers no longer see it,
  and the hourly retention sweep deletes it
  (`Comma.Workers.MemberSourceItemRetention`).

  Rows share the member source item pool's lifecycle: revoking, removing or
  turning off the source, or leaving member mode, deletes them at once
  (`Comma.MemberSourceItems`).
  """

  import Ecto.Query
  alias Comma.Repo
  alias Comma.Data.{OpenThread, OpenThreadCursor, RecommendationProfile}

  @kinds ~w(promised asked blocked)
  @statuses ~w(open resolved dismissed)
  @retention_days 45
  # A summary for the owner, not an archive.
  @per_profile_limit 40
  # Open threads whose own thread one refresh reads for news.
  @tracked_limit 10

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc "The profile's threads within retention, newest evidence first."
  def list(profile_id, now \\ SystemsClock.utc_now()) when is_binary(profile_id) do
    cutoff = cutoff(now)

    from(t in OpenThread,
      where: t.profile_id == ^profile_id and t.evidence_at >= ^cutoff,
      order_by: [desc: t.evidence_at, asc: t.id]
    )
    |> Repo.all()
  end

  defp cutoff(now), do: DateTime.add(now, -@retention_days * 86_400, :second)

  @doc """
  The Slack ts of the newest own message an extraction for the source has
  judged, or `nil` before the first one.
  """
  def cursor(profile_id, source_id) do
    from(c in OpenThreadCursor,
      where: c.profile_id == ^profile_id and c.source_id == ^source_id,
      select: c.read_until
    )
    |> Repo.one()
  end

  @doc """
  The source's open threads the owner has not corrected that a refresh reads
  for news, at most #{@tracked_limit}: those read longest ago first
  (`tracked_at`), so every open thread takes its turn.
  """
  def tracked(profile_id, source_id) do
    from(t in OpenThread,
      where:
        t.profile_id == ^profile_id and t.source_id == ^source_id and t.status == "open" and
          is_nil(t.corrected_at),
      order_by: [asc_nulls_first: t.tracked_at, asc: t.id],
      limit: @tracked_limit
    )
    |> Repo.all()
  end

  @doc """
  Records one extraction for a source. Each entry carries `"thread_key"`,
  `"kind"`, `"status"` (`open` or `resolved`), `"summary"`, `"quote"`,
  `"counterpart"`, `"url"`, `"due_on"` and `"evidence_at"`. A new entry is
  recorded only while open. A dismissed thread stays as it is. Threads the
  extraction did not return keep their state; expired ones are deleted.

  Recording rechecks the locked profile, the lock that source purges and
  settings changes take: a source the member no longer collects, or one the
  `:current?` option (a function of the locked profile, such as a check of
  the account the read used) rejects, records nothing
  (`{:error, :member_source_changed}`).

  Options: `:now`, `:current?`, `:read_until` (the newest own message ts the
  extraction sent to the model, kept as the source's cursor), `:tracked`
  (thread IDs whose thread the tracking read, which then wait their turn
  again), `:checked` (thread ID to the newest message ts the model judged)
  and `:closed` (thread IDs the tracking found done, resolved unless the
  owner corrected them since).
  """
  def record(profile_id, source_id, toolkit, entries, opts \\ [])
      when is_binary(profile_id) and is_binary(source_id) and is_list(entries) do
    now = Keyword.get_lazy(opts, :now, &SystemsClock.utc_now/0)
    current? = Keyword.get(opts, :current?, fn _profile -> true end)

    Repo.transaction(fn ->
      profile =
        Repo.one!(
          from(p in RecommendationProfile, where: p.id == ^profile_id, lock: "FOR UPDATE")
        )

      if profile.relevance_mode == "generic" or
           source_id not in Comma.MemberSourceItems.enabled_source_ids(profile) or
           not current?.(profile),
         do: Repo.rollback(:member_source_changed)

      existing =
        from(t in OpenThread, where: t.profile_id == ^profile_id and t.source_id == ^source_id)
        |> Repo.all()
        |> Map.new(&{{&1.thread_key, &1.kind}, &1})

      entries
      |> Enum.filter(&valid?/1)
      |> Enum.uniq_by(&{&1["thread_key"], &1["kind"]})
      |> Enum.each(
        &put(existing[{&1["thread_key"], &1["kind"]}], profile_id, source_id, toolkit, &1, now)
      )

      track(
        profile_id,
        source_id,
        opts[:tracked] || [],
        opts[:checked] || %{},
        opts[:closed] || [],
        now
      )

      if is_binary(opts[:read_until]),
        do: move_cursor(profile_id, source_id, toolkit, opts[:read_until], now)

      expire(profile_id, now)
      %{open: Repo.aggregate(open_query(profile_id), :count)}
    end)
  end

  # Tracking results, applied only to threads still open and uncorrected.
  defp track(profile_id, source_id, tracked, checked, closed, now) do
    from(t in OpenThread,
      where:
        t.id in ^Enum.filter(tracked, &is_binary/1) and t.profile_id == ^profile_id and
          t.source_id == ^source_id
    )
    |> Repo.update_all(set: [tracked_at: now])

    for {id, ts} <- checked, is_binary(id) and is_binary(ts) do
      from(t in OpenThread,
        where: t.id == ^id and t.profile_id == ^profile_id and t.source_id == ^source_id
      )
      |> Repo.update_all(set: [checked_ts: ts])
    end

    from(t in OpenThread,
      where:
        t.id in ^Enum.filter(closed, &is_binary/1) and t.profile_id == ^profile_id and
          t.source_id == ^source_id and t.status == "open" and is_nil(t.corrected_at)
    )
    |> Repo.update_all(set: [status: "resolved", changed_at: now])
  end

  defp move_cursor(profile_id, source_id, toolkit, read_until, now) do
    Repo.insert!(
      %OpenThreadCursor{
        profile_id: profile_id,
        source_id: source_id,
        toolkit: toolkit,
        read_until: read_until,
        updated_at: now
      },
      conflict_target: [:profile_id, :source_id],
      on_conflict: {:replace, [:read_until, :updated_at]}
    )
  end

  defp valid?(entry) do
    entry["kind"] in @kinds and entry["status"] in ~w(open resolved) and
      Enum.all?(~w(thread_key summary url), &(is_binary(entry[&1]) and entry[&1] != "")) and
      is_struct(entry["evidence_at"], DateTime)
  end

  defp put(nil, _profile_id, _source_id, _toolkit, %{"status" => "resolved"}, _now), do: :ok

  defp put(nil, profile_id, source_id, toolkit, entry, now) do
    Repo.insert!(%OpenThread{
      profile_id: profile_id,
      source_id: source_id,
      toolkit: toolkit,
      thread_key: entry["thread_key"],
      kind: entry["kind"],
      status: "open",
      summary: entry["summary"],
      quote: entry["quote"] || "",
      counterpart: entry["counterpart"],
      url: entry["url"],
      due_on: entry["due_on"],
      evidence_at: entry["evidence_at"],
      checked_ts: entry["checked_ts"],
      first_seen_at: now,
      changed_at: now
    })
  end

  # The owner's correction stands until they open the thread again.
  defp put(
         %OpenThread{corrected_at: %DateTime{}},
         _profile_id,
         _source_id,
         _toolkit,
         _entry,
         _now
       ),
       do: :ok

  defp put(%OpenThread{} = thread, _profile_id, _source_id, _toolkit, entry, now) do
    evidence_at =
      if DateTime.compare(entry["evidence_at"], thread.evidence_at) == :gt,
        do: entry["evidence_at"],
        else: thread.evidence_at

    changes = %{
      status: entry["status"],
      summary: entry["summary"],
      quote: entry["quote"] || "",
      counterpart: entry["counterpart"],
      url: entry["url"],
      due_on: entry["due_on"],
      evidence_at: evidence_at,
      checked_ts: later_ts(thread.checked_ts, entry["checked_ts"])
    }

    changed = Enum.any?(changes, fn {field, value} -> Map.fetch!(thread, field) != value end)

    if changed,
      do: thread |> Ecto.Changeset.change(Map.put(changes, :changed_at, now)) |> Repo.update!(),
      else: :ok
  end

  defp later_ts(a, b) when is_binary(a) and is_binary(b),
    do: if(ts_value(b) > ts_value(a), do: b, else: a)

  defp later_ts(a, b), do: a || b

  defp ts_value(ts) do
    case Float.parse(ts) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  # Threads past retention leave, then the oldest uncorrected ones beyond the
  # profile's bound. Corrections leave only by retention: dropping one would
  # let the next extraction bring the thread back.
  defp expire(profile_id, now) do
    cutoff = cutoff(now)

    from(t in OpenThread, where: t.profile_id == ^profile_id and t.evidence_at < ^cutoff)
    |> Repo.delete_all()

    uncorrected =
      from(t in OpenThread, where: t.profile_id == ^profile_id and is_nil(t.corrected_at))

    keep =
      from(t in uncorrected,
        order_by: [desc: t.evidence_at, asc: t.id],
        limit: @per_profile_limit,
        select: t.id
      )

    from(t in uncorrected, where: t.id not in subquery(keep)) |> Repo.delete_all()
  end

  @doc """
  Deletes at most `batch` threads of any profile past retention, for the
  hourly sweep. Returns how many it deleted.
  """
  def expire_all(now \\ SystemsClock.utc_now(), batch \\ 1_000) do
    ids = from(t in OpenThread, where: t.evidence_at < ^cutoff(now), limit: ^batch, select: t.id)
    {count, _} = from(t in OpenThread, where: t.id in subquery(ids)) |> Repo.delete_all()
    count
  end

  defp open_query(profile_id),
    do: from(t in OpenThread, where: t.profile_id == ^profile_id and t.status == "open")

  @doc """
  The owner's correction: `open`, `resolved` or `dismissed`. Only a thread of
  this profile changes. A resolved or dismissed thread stays so until the
  owner opens it again. It takes the profile lock that recording holds, so a
  correction and an extraction never overwrite each other.
  """
  def set_status(profile_id, id, status, now \\ SystemsClock.utc_now())

  def set_status(profile_id, id, status, now)
      when is_binary(profile_id) and is_binary(id) and status in @statuses do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      # The extraction records under this lock, so a correction lands wholly
      # before or after it, never on the copy it read.
      Repo.transaction(fn ->
        from(p in RecommendationProfile, where: p.id == ^profile_id, lock: "FOR UPDATE")
        |> Repo.one()

        case Repo.get_by(OpenThread, id: uuid, profile_id: profile_id) do
          %OpenThread{} = thread ->
            corrected_at = if status == "open", do: nil, else: now

            thread
            |> Ecto.Changeset.change(status: status, corrected_at: corrected_at, changed_at: now)
            |> Repo.update!()

          nil ->
            Repo.rollback(:open_thread_not_found)
        end
      end)
    else
      _ -> {:error, :open_thread_not_found}
    end
  end

  def set_status(_profile_id, _id, _status, _now), do: {:error, :invalid_open_thread}

  @doc "Deletes all of the profile's threads."
  def purge(profile_id) when is_binary(profile_id) do
    from(t in OpenThread, where: t.profile_id == ^profile_id) |> Repo.delete_all()
    :ok
  end
end
