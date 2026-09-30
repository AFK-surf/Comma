defmodule SalixMeet do
  @moduledoc """
  Public read API over meeting state (`meet/{id}/state.json`, see
  `SalixMeet.Store`).

  `list_group_meetings/1` is the surface the Bridge For Teams dashboard calls
  over erpc to render meeting records: it returns compact, JSON-safe maps —
  no runtime tokens, no leases, no raw caption/chat bodies.
  """

  alias SalixMeet.{FallbackMessageManifest, Store}
  alias SalixStore.{MeetingGroupProjectionReadiness, MeetingGroupProjections}
  alias SystemsObservability.Context

  @delivery_failure_kinds ~w(canvas_unavailable router_summary_timeout)
  @canvas_url_sources ~w(files_info derived legacy)

  @doc """
  List a group's meetings as compact records, newest first.

  Each record carries what a dashboard needs to show the meeting and its
  outcome: title/status/provider, the summary the meeting agent produced
  (key points + action items), counts for captions/chats, which artifact
  kinds exist (transcript/audio/...), and the Slack thread reference.
  """
  @spec list_group_meetings(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_group_meetings(group_id) when is_binary(group_id) do
    with {:ok, ids} <- Store.list() do
      meetings =
        ids
        |> Enum.flat_map(fn id ->
          case Store.get(id) do
            {:ok, doc, _etag} -> group_meeting_record(doc, group_id)
            _ -> []
          end
        end)
        |> Enum.sort_by(&(-(&1["start_at"] || &1["created_at"] || 0)))

      {:ok, meetings}
    end
  end

  @doc """
  Bounded, typed-failure group source for production Triage.

  Unlike `list_group_meetings/1` this never scans every meeting in the
  deployment and never degrades to a partial answer: it reads only the group's
  own PostgreSQL projection, refuses to answer before the release backfill is
  sealed, and reports
  truncation explicitly rather than silently cutting the list. The readiness
  and completeness protocol is modeled in `tla/salix/MeetingGroupIndex.tla`.
  """
  @spec list_group_meetings_bounded(String.t(), keyword()) ::
          {:ok, map()}
          | {:error, :invalid | :meeting_source_unsealed | :unavailable | :timeout | :truncated}
  def list_group_meetings_bounded(group_id, opts)
      when is_binary(group_id) and group_id != "" and is_list(opts) do
    limit = Keyword.get(opts, :limit, 25)
    deadline_ms = Keyword.get(opts, :deadline_ms, 500)

    if is_integer(limit) and limit > 0 and limit <= 50 and is_integer(deadline_ms) and
         deadline_ms >= 10 and deadline_ms <= 2_000 do
      context = Context.capture()

      # `async_nolink/2`, not `Task.async/1`: a linked crash in the projection read
      # killed the CALLER before `Task.yield/2` could return the `{:exit, _}`
      # diagnostic the clause below exists to produce, so a broken index took
      # down the Triage freeze instead of failing typed.
      task =
        Task.Supervisor.async_nolink(SalixMeet.TaskSupervisor, fn ->
          Context.run(context, fn -> do_list_group_meetings_bounded(group_id, limit) end)
        end)

      case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, _reason} -> {:error, :unavailable}
        nil -> {:error, :timeout}
      end
    else
      {:error, :invalid}
    end
  end

  def list_group_meetings_bounded(_group_id, _opts), do: {:error, :invalid}

  @doc """
  Read one exact meeting through the sealed group projection without scanning.

  `with_ifc: true` returns `{:ok, meeting, ifc}` for the agent read adapter.
  The label is derived from the same authoritative state as the public record,
  within the same deadline; it is not part of the meeting's business JSON.
  """
  @spec get_group_meeting_bounded(String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:ok, map(), map() | nil}
          | {:error, :invalid | :meeting_source_unsealed | :not_found | :unavailable | :timeout}
  def get_group_meeting_bounded(group_id, meeting_id, opts \\ [])

  def get_group_meeting_bounded(group_id, meeting_id, opts)
      when is_binary(group_id) and group_id != "" and is_binary(meeting_id) and
             meeting_id != "" and is_list(opts) do
    deadline_ms = Keyword.get(opts, :deadline_ms, 500)

    if is_integer(deadline_ms) and deadline_ms >= 10 and deadline_ms <= 2_000 and
         Keyword.keys(opts) -- [:deadline_ms, :with_ifc] == [] and
         is_boolean(Keyword.get(opts, :with_ifc, false)) do
      context = Context.capture()

      task =
        Task.Supervisor.async_nolink(SalixMeet.TaskSupervisor, fn ->
          Context.run(context, fn ->
            do_get_group_meeting_bounded(
              group_id,
              meeting_id,
              Keyword.get(opts, :with_ifc, false)
            )
          end)
        end)

      case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, _reason} -> {:error, :unavailable}
        nil -> {:error, :timeout}
      end
    else
      {:error, :invalid}
    end
  end

  def get_group_meeting_bounded(_group_id, _meeting_id, _opts), do: {:error, :invalid}

  defp do_get_group_meeting_bounded(group_id, meeting_id, with_ifc) do
    if MeetingGroupProjectionReadiness.ready?() do
      with {:ok, ^group_id} <- MeetingGroupProjections.fetch_group(meeting_id),
           {:ok, doc, _etag} <- Store.get_indexed(meeting_id),
           [meeting] <- group_meeting_record(doc, group_id) do
        if with_ifc do
          {:ok, meeting, SalixMeet.IFC.ReadLabels.for_meeting(doc["state"], meeting)}
        else
          {:ok, meeting}
        end
      else
        {:ok, _other_group} -> {:error, :not_found}
        {:error, :not_found} -> {:error, :not_found}
        {:error, _reason} -> {:error, :unavailable}
        _invalid -> {:error, :unavailable}
      end
    else
      {:error, :meeting_source_unsealed}
    end
  end

  defp do_list_group_meetings_bounded(group_id, limit) do
    if MeetingGroupProjectionReadiness.ready?() do
      with {:ok, %{meeting_ids: meeting_ids, truncated: false}} <-
             MeetingGroupProjections.list_group(group_id, limit: limit),
           {:ok, meetings} <- read_group_projected_meetings(meeting_ids, group_id) do
        {:ok,
         %{
           "meetings" => Enum.sort_by(meetings, &(-(&1["start_at"] || &1["created_at"] || 0))),
           "completeness" => "complete",
           "truncated" => false
         }}
      else
        {:ok, %{truncated: true}} -> {:error, :truncated}
        {:error, _reason} -> {:error, :unavailable}
        _invalid -> {:error, :unavailable}
      end
    else
      {:error, :meeting_source_unsealed}
    end
  end

  # Projection lookup is one indexed PostgreSQL query; each row then costs one
  # authoritative S3 state GET. Reads run with bounded concurrency and preserve
  # all-or-nothing semantics for storage faults or invalid identity. A
  # definitive missing state is a harmless dangling projection and is skipped.
  @projected_read_concurrency 8
  @projected_read_timeout_ms 1_500

  defp read_group_projected_meetings(meeting_ids, group_id) do
    context = Context.capture()

    meeting_ids
    |> Task.async_stream(
      fn meeting_id ->
        Context.run(context, fn -> read_group_projected_meeting(meeting_id, group_id) end)
      end,
      max_concurrency: @projected_read_concurrency,
      ordered: true,
      timeout: @projected_read_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, meeting}}, {:ok, meetings} -> {:cont, {:ok, [meeting | meetings]}}
      {:ok, :dangling}, {:ok, meetings} -> {:cont, {:ok, meetings}}
      _invalid_or_unavailable, _acc -> {:halt, {:error, :unavailable}}
    end)
    |> case do
      {:ok, meetings} -> {:ok, Enum.reverse(meetings)}
      error -> error
    end
  end

  defp read_group_projected_meeting(meeting_id, group_id) when is_binary(meeting_id) do
    with {:ok, doc, _etag} <- Store.get_indexed(meeting_id),
         [meeting] <- group_meeting_record(doc, group_id) do
      {:ok, meeting}
    else
      {:error, :not_found} -> :dangling
      _invalid_or_unavailable -> :error
    end
  end

  defp read_group_projected_meeting(_meeting_id, _group_id), do: :error

  defp group_meeting_record(doc, group_id) do
    state = doc["state"] || %{}
    delivery = state["delivery"] || %{}

    if state["group_id"] == group_id do
      [
        %{
          "meeting_id" => doc["id"],
          "title" => state["title"],
          "status" => state["status"],
          "reason_code" => SalixMeet.Outcome.normalize(state["reason_code"]),
          "reason_message" => SalixMeet.Outcome.text(state["reason_code"]),
          "provider" => state["provider"],
          "meet_url" => state["meet_url"],
          "start_at" => state["start_at"],
          "joined_at" => state["joined_at"],
          "caption_language" => state["caption_language"],
          "summary" => state["summary"],
          "delivery_status" => delivery["status"],
          "delivery_failure_kind" => delivery_failure_kind(delivery["failure_kind"]),
          "notes_delivery_status" => public_notes_delivery_status(state, delivery, doc["id"]),
          "notes_delivery_surface" => public_notes_delivery_surface(state, delivery, doc["id"]),
          "published_at" => delivery["published_at"],
          "canvas_id" =>
            delivery["canvas_id"] || get_in(delivery, ["canvas_create", "canvas_id"]),
          "canvas_create_status" =>
            public_canvas_create_status(get_in(delivery, ["canvas_create", "status"])),
          "canvas_url" => delivery["canvas_url"],
          "canvas_url_source" => public_canvas_url_source(delivery["canvas_url_source"]),
          "canvas_link_status" =>
            public_canvas_link_status(get_in(delivery, ["canvas_link", "status"])),
          "canvas_access_status" =>
            public_canvas_access_status(get_in(delivery, ["canvas_access", "status"])),
          "captions_count" => state["captions"] |> List.wrap() |> length(),
          "chats_count" => state["chats"] |> List.wrap() |> length(),
          "artifacts" => state["artifacts"] |> Kernel.||(%{}) |> Map.keys() |> Enum.sort(),
          "slack_channel_id" => get_in(state, ["slack_ref", "channel_id"]),
          "slack_thread_ts" => get_in(state, ["slack_ref", "thread_ts"]),
          "created_at" => doc["created_at"]
        }
      ]
    else
      []
    end
  end

  defp delivery_failure_kind(kind) when kind in @delivery_failure_kinds, do: kind
  defp delivery_failure_kind(_kind), do: nil

  defp public_notes_delivery_status(state, delivery, meeting_id) do
    cond do
      explicit_notes_visible?(delivery, meeting_id) -> "visible"
      state["status"] == "done" and delivery["published_at"] not in [nil, "", false] -> "visible"
      legacy_terminal_summary_visible?(state, delivery) -> "visible"
      state["status"] == "done" and delivery["status"] == "failed_terminal" -> "unavailable"
      state["status"] == "done" -> "pending"
      true -> nil
    end
  end

  defp public_notes_delivery_surface(state, delivery, meeting_id) do
    notes = delivery["notes_delivery"] || %{}

    cond do
      explicit_notes_visible?(delivery, meeting_id) and
          notes["surface"] in ["canvas", "message_fallback", "canvas_link_message"] ->
        notes["surface"]

      state["status"] == "done" and delivery["published_at"] not in [nil, "", false] ->
        "canvas"

      legacy_terminal_summary_visible?(state, delivery) ->
        "canvas_link_message"

      true ->
        nil
    end
  end

  defp legacy_terminal_summary_visible?(state, delivery) do
    state["status"] == "done" and delivery["status"] == "failed_terminal" and
      to_string(delivery["summary_message_ts"] || "") != "" and
      to_string(delivery["summary_message_kind"] || "") in ["", "summary"]
  end

  defp explicit_notes_visible?(delivery, meeting_id) do
    notes = delivery["notes_delivery"] || %{}

    notes["status"] == "visible" and
      (notes["kind"] != "summary_fallback" or
         FallbackMessageManifest.notes_visible?(delivery, meeting_id))
  end

  defp public_canvas_create_status(status)
       when status in [
              "ready",
              "v2_ready",
              "v3_ready",
              "v4_ready",
              "created",
              "v2_created",
              "v3_created",
              "v4_created"
            ],
       do: "created"

  defp public_canvas_create_status(status)
       when status in [
              "creating",
              "v2_creating",
              "v3_creating",
              "v4_creating",
              "v2_fallback_creating",
              "v4_fallback_creating"
            ],
       do: "creating"

  defp public_canvas_create_status(status)
       when status in [
              "retryable",
              "create_retryable",
              "v2_create_retryable",
              "v3_create_retryable",
              "v4_create_retryable",
              "v2_fallback_retryable",
              "v4_fallback_retryable"
            ],
       do: "retrying"

  defp public_canvas_create_status(status)
       when status in [
              "unknown",
              "v2_unknown",
              "v3_unknown",
              "v4_unknown",
              "v2_fallback_unknown",
              "v4_fallback_unknown",
              "conflict"
            ],
       do: "reconciling"

  defp public_canvas_create_status(status)
       when status in ["abandoned", "v2_abandoned", "v4_abandoned"],
       do: "unavailable"

  defp public_canvas_create_status(nil), do: nil
  defp public_canvas_create_status(_status), do: "unknown"

  defp public_canvas_link_status("resolved"), do: "resolved"
  defp public_canvas_link_status("pending"), do: "resolving"

  defp public_canvas_link_status(status) when status in ["abandoned", "v2_abandoned"],
    do: "unavailable"

  defp public_canvas_link_status(nil), do: nil
  defp public_canvas_link_status(_status), do: "unknown"

  defp public_canvas_access_status(status) when status in ["granted", "v2_granted"],
    do: "granted"

  defp public_canvas_access_status(status) when status in ["link_shared", "v2_link_shared"],
    do: "link_shared"

  defp public_canvas_access_status(status) when status in ["pending", "v2_pending"],
    do: "granting"

  defp public_canvas_access_status(status) when status in ["abandoned", "v2_abandoned"],
    do: "unavailable"

  defp public_canvas_access_status(nil), do: nil
  defp public_canvas_access_status(_status), do: "unknown"

  defp public_canvas_url_source(source) when source in @canvas_url_sources, do: source
  defp public_canvas_url_source(nil), do: nil
  defp public_canvas_url_source(_source), do: "unknown"
end
