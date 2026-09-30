defmodule SalixMeet.CalendarProjection do
  @moduledoc """
  One durable, CAS-fenced calendar work projection per group.

  Fresh local occurrences and pre-dispatch recovery occurrences have independent
  bounded capacity. A single cursor rotates across the combined candidate
  order, and one projection ETag fences both lists and that cursor.
  """

  alias SalixStore.{Ids, JSON, Keys, S3}

  @version 3
  @default_max_events 50
  @max_status_events 50

  defstruct [
    :tenant_id,
    :group_id,
    :calendar_id,
    :lease_epoch,
    :updated_at,
    :cursor,
    :etag,
    :new?,
    fresh: [],
    recovery: []
  ]

  @type t :: %__MODULE__{}

  @spec load(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(group, opts \\ []) when is_map(group) do
    tenant_id = trim(group["tenant_id"])
    group_id = trim(group["group_id"])
    calendar_id = trim(group["calendar_id"])
    lease_epoch = Keyword.get(opts, :lease_epoch, 0)
    now = Keyword.get(opts, :now, now_ms())
    max_events = positive(Keyword.get(opts, :max_events), @default_max_events)

    with true <- tenant_id != "" and group_id != "" do
      case S3.get(key(group_id)) do
        {:ok, %{body: body, etag: etag}} ->
          decode(
            body,
            tenant_id,
            group_id,
            calendar_id,
            lease_epoch,
            etag,
            max_events
          )

        {:error, :not_found} ->
          new_projection(
            tenant_id,
            group_id,
            calendar_id,
            lease_epoch,
            now,
            max_events
          )

        {:error, reason} ->
          {:error, {:calendar_projection_read, reason}}
      end
    else
      false -> {:error, :invalid_calendar_projection_scope}
    end
  end

  @spec reconcile(t(), [map()], map(), keyword()) ::
          {:ok, t(), %{partial_errors: [map()]}}
  def reconcile(%__MODULE__{} = snapshot, fresh_events, recovery_results, opts)
      when is_list(fresh_events) and is_map(recovery_results) do
    max_events = positive(Keyword.get(opts, :max_events), 1)
    now = Keyword.get(opts, :now, now_ms())

    fresh =
      fresh_events
      |> Enum.filter(&is_map/1)
      |> Enum.map(&entry(snapshot, &1, nil, now))
      |> Enum.uniq_by(& &1["meeting_id"])
      |> Enum.take(max_events)

    fresh_ids = MapSet.new(fresh, & &1["meeting_id"])

    {recovery, partial_errors} =
      (snapshot.fresh ++ snapshot.recovery)
      |> Enum.reject(&MapSet.member?(fresh_ids, snapshot_meeting_id(snapshot, &1["event"])))
      |> Enum.reduce({[], []}, fn prior, {retained, errors} ->
        mid = prior["meeting_id"]

        case Map.get(recovery_results, mid) do
          {:retain, event, error} when is_map(event) ->
            retained_entry =
              snapshot
              |> entry(event, prior["recovery_started_at"] || now, now)
              |> Map.put("last_error", persistable_error(error))

            errors =
              if is_nil(error),
                do: errors,
                else: [%{meeting_id: mid, reason: error} | errors]

            {[retained_entry | retained], errors}

          {:drop, _reason} ->
            {retained, errors}

          _missing_or_invalid ->
            {retained, errors}
        end
      end)

    recovery =
      recovery
      |> Enum.reverse()
      |> Enum.uniq_by(& &1["meeting_id"])
      |> Enum.take(max_events)

    updated = %{snapshot | fresh: fresh, recovery: recovery, updated_at: now}
    {:ok, updated, %{partial_errors: Enum.reverse(partial_errors)}}
  end

  @spec candidates(t()) :: [map()]
  def candidates(%__MODULE__{} = snapshot), do: candidates(snapshot, nil)

  @doc false
  @spec dispatch_meeting_ids(t(), map()) :: [String.t()]
  def dispatch_meeting_ids(%__MODULE__{} = snapshot, %{"event" => event})
      when is_map(event) do
    [snapshot_meeting_id(snapshot, event)]
  end

  def dispatch_meeting_ids(%__MODULE__{}, _entry), do: []

  @spec candidates(t(), pos_integer() | nil) :: [map()]
  def candidates(%__MODULE__{} = snapshot, limit) do
    limit = if is_integer(limit) and limit > 0, do: limit, else: nil
    fresh = if limit, do: Enum.take(snapshot.fresh, limit), else: snapshot.fresh
    recovery = if limit, do: Enum.take(snapshot.recovery, limit), else: snapshot.recovery

    candidates =
      Enum.map(fresh, &candidate(snapshot, :fresh, &1)) ++
        Enum.map(recovery, &candidate(snapshot, :recovery, &1))

    candidates
    |> Enum.sort_by(& &1.key)
    |> rotate_after(snapshot.cursor || "")
  end

  @spec advance(t(), String.t() | map()) :: t()
  def advance(%__MODULE__{} = snapshot, %{key: key}), do: advance(snapshot, key)
  def advance(%__MODULE__{} = snapshot, key) when is_binary(key), do: %{snapshot | cursor: key}

  @spec checkpoint_intent(t()) :: t()
  def checkpoint_intent(%__MODULE__{} = snapshot), do: snapshot

  @spec checkpoint(t()) :: {:ok, t()} | {:error, term()}
  def checkpoint(%__MODULE__{} = snapshot) do
    body = Jason.encode!(to_map(snapshot))

    opts =
      if snapshot.new?,
        do: [if_none_match: "*"],
        else: [if_match: snapshot.etag]

    case S3.put(key(snapshot.group_id), body, opts) do
      {:ok, %{etag: etag}} ->
        {:ok, %{snapshot | etag: etag, new?: false}}

      {:error, :precondition_failed} ->
        {:error, :stale}

      {:error, {:ambiguous, _reason}} ->
        verify_checkpoint(snapshot)

      {:error, reason} ->
        {:error, {:calendar_projection_write, reason}}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    %{
      "version" => @version,
      "tenant_id" => snapshot.tenant_id,
      "group_id" => snapshot.group_id,
      "calendar_id" => snapshot.calendar_id,
      "lease_epoch" => snapshot.lease_epoch,
      "updated_at" => snapshot.updated_at,
      "cursor" => snapshot.cursor,
      "fresh" => snapshot.fresh,
      "recovery" => snapshot.recovery
    }
  end

  @doc "Read a bounded, non-mutating diagnostic view of one group's durable projection."
  @spec status(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def status(group_id, limit \\ 20) do
    with true <- Ids.valid_group_id?(group_id),
         true <- is_integer(limit) and limit in 1..@max_status_events do
      case S3.get(key(group_id)) do
        {:ok, %{body: body}} -> decode_status(body, group_id, limit)
        {:error, :not_found} -> {:ok, empty_status("not_scanned", limit)}
        {:error, reason} -> {:error, {:calendar_projection_read, reason}}
      end
    else
      false -> {:error, :invalid_calendar_projection_status_query}
    end
  end

  @spec meeting_id(map(), map()) :: String.t()
  def meeting_id(group, event) do
    payload = [
      "comma-calendar-occurrence-v1",
      trim(group["tenant_id"]),
      trim(group["group_id"]),
      event["occurrence_ref"]
    ]

    digest =
      payload
      |> JSON.stringify()
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))

    "mtg-cal-" <> Base.encode16(digest, case: :lower)
  end

  @spec key(String.t()) :: String.t()
  def key(group_id), do: Keys.ctl_meet_calendar_projection(group_id)

  defp new_projection(
         tenant_id,
         group_id,
         calendar_id,
         lease_epoch,
         now,
         _max_events
       ) do
    {:ok,
     %__MODULE__{
       tenant_id: tenant_id,
       group_id: group_id,
       calendar_id: calendar_id,
       lease_epoch: lease_epoch,
       updated_at: now,
       cursor: "",
       etag: nil,
       new?: true,
       fresh: [],
       recovery: []
     }}
  end

  defp decode(
         body,
         tenant_id,
         group_id,
         calendar_id,
         lease_epoch,
         etag,
         max_events
       ) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
         ^tenant_id <- trim(decoded["tenant_id"]),
         ^group_id <- trim(decoded["group_id"]) do
      decode_version(
        decoded,
        tenant_id,
        group_id,
        calendar_id,
        lease_epoch,
        etag,
        max_events
      )
    else
      _ -> {:error, :invalid_calendar_projection}
    end
  end

  defp decode_version(
         %{"version" => @version} = decoded,
         tenant_id,
         group_id,
         calendar_id,
         lease_epoch,
         etag,
         max_events
       ) do
    with fresh when is_list(fresh) <- decoded["fresh"],
         recovery when is_list(recovery) <- decoded["recovery"],
         cursor when is_binary(cursor) <- decoded["cursor"] || "" do
      {:ok,
       %__MODULE__{
         tenant_id: tenant_id,
         group_id: group_id,
         calendar_id: calendar_id,
         lease_epoch: lease_epoch,
         updated_at: decoded["updated_at"],
         cursor: cursor,
         etag: etag,
         new?: false,
         fresh: fresh |> Enum.filter(&valid_entry?/1) |> Enum.take(max_events),
         recovery: recovery |> Enum.filter(&valid_entry?/1) |> Enum.take(max_events)
       }}
    else
      _ -> {:error, :invalid_calendar_projection}
    end
  end

  defp decode_version(
         %{"version" => 2},
         tenant_id,
         group_id,
         calendar_id,
         lease_epoch,
         etag,
         _max_events
       ) do
    {:ok,
     %__MODULE__{
       tenant_id: tenant_id,
       group_id: group_id,
       calendar_id: calendar_id,
       lease_epoch: lease_epoch,
       updated_at: now_ms(),
       cursor: "",
       etag: etag,
       new?: false,
       fresh: [],
       recovery: []
     }}
  end

  defp decode_version(_decoded, _tenant, _group, _calendar, _lease, _etag, _max),
    do: {:error, :invalid_calendar_projection}

  defp decode_status(body, group_id, limit) do
    with {:ok, %{"group_id" => ^group_id, "version" => @version} = decoded} <-
           Jason.decode(body),
         fresh when is_list(fresh) <- decoded["fresh"],
         recovery when is_list(recovery) <- decoded["recovery"] do
      fresh = Enum.filter(fresh, &valid_entry?/1)
      recovery = Enum.filter(recovery, &valid_entry?/1)

      entries =
        (Enum.map(fresh, &status_entry("fresh", &1)) ++
           Enum.map(recovery, &status_entry("recovery", &1)))
        |> Enum.sort_by(fn entry ->
          event = entry["event"]
          {event["start_ms"] || 0, event["event_id"] || "", entry["meeting_id"]}
        end)
        |> Enum.take(limit)

      {:ok,
       %{
         "state" => "active",
         "calendar_id" => decoded["calendar_id"],
         "updated_at" => decoded["updated_at"],
         "fresh_count" => length(fresh),
         "recovery_count" => length(recovery),
         "candidate_count" => length(fresh) + length(recovery),
         "returned_count" => length(entries),
         "limit" => limit,
         "truncated" => length(fresh) + length(recovery) > length(entries),
         "entries" => entries
       }}
    else
      {:ok, %{"group_id" => ^group_id, "version" => 2}} ->
        {:ok, empty_status("not_scanned", limit)}

      _ ->
        {:error, :invalid_calendar_projection}
    end
  end

  defp status_entry(kind, entry) do
    %{
      "kind" => kind,
      "meeting_id" => entry["meeting_id"],
      "event" => entry["event"],
      "recovery_started_at" => entry["recovery_started_at"],
      "last_error_present" => not is_nil(entry["last_error"]),
      "updated_at" => entry["updated_at"]
    }
  end

  defp empty_status(state, limit) do
    %{
      "state" => state,
      "calendar_id" => nil,
      "updated_at" => nil,
      "fresh_count" => 0,
      "recovery_count" => 0,
      "candidate_count" => 0,
      "returned_count" => 0,
      "limit" => limit,
      "truncated" => false,
      "entries" => []
    }
  end

  defp entry(snapshot, event, recovery_started_at, now) do
    %{
      "meeting_id" => snapshot_meeting_id(snapshot, event),
      "event" => event,
      "recovery_started_at" => recovery_started_at,
      "last_error" => nil,
      "updated_at" => now
    }
  end

  defp candidate(snapshot, kind, entry) do
    event = entry["event"]
    canonical_mid = snapshot_meeting_id(snapshot, event)
    rank = if kind == :fresh, do: 0, else: 1
    start_ms = if is_integer(event["start_ms"]), do: max(event["start_ms"], 0), else: 0

    key =
      [
        Integer.to_string(rank),
        start_ms |> Integer.to_string() |> String.pad_leading(20, "0"),
        trim(event["event_id"]),
        canonical_mid
      ]
      |> Enum.join(<<0>>)

    %{
      kind: kind,
      key: key,
      meeting_id: canonical_mid,
      dispatch_meeting_ids: dispatch_meeting_ids(snapshot, entry),
      event: event
    }
  end

  defp snapshot_meeting_id(%__MODULE__{} = snapshot, event),
    do: meeting_id(snapshot_group(snapshot), event)

  defp snapshot_group(snapshot) do
    %{
      "tenant_id" => snapshot.tenant_id,
      "group_id" => snapshot.group_id,
      "calendar_id" => snapshot.calendar_id
    }
  end

  defp rotate_after(candidates, ""), do: candidates

  defp rotate_after(candidates, cursor) do
    {after_cursor, before_or_at} = Enum.split_with(candidates, &(&1.key > cursor))
    after_cursor ++ before_or_at
  end

  defp verify_checkpoint(snapshot) do
    case S3.get(key(snapshot.group_id)) do
      {:ok, %{body: body, etag: etag}} ->
        if Jason.decode!(body) == to_map(snapshot),
          do: {:ok, %{snapshot | etag: etag, new?: false}},
          else: {:error, :stale}

      _ ->
        {:error, :stale}
    end
  end

  defp valid_entry?(%{"meeting_id" => mid, "event" => %{"occurrence_ref" => ref}}),
    do: trim(mid) != "" and is_map(ref)

  defp valid_entry?(_entry), do: false

  defp positive(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive(_value, fallback), do: fallback
  defp persistable_error(nil), do: nil
  defp persistable_error(error) when is_binary(error), do: error
  defp persistable_error(error), do: inspect(error)
  defp trim(value), do: String.trim(to_string(value || ""))

  defp now_ms, do: System.system_time(:millisecond)
end
