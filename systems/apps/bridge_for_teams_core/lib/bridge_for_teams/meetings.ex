defmodule BridgeForTeams.Meetings do
  @moduledoc """
  Bot-attended meeting records for a project.

  Salix is the source of truth: when a Google Meet link is dropped in a
  connected IM channel (e.g. Slack), the group's hidden meeting agent joins
  the call, captures captions/chat, and produces a summary with key points
  and action items (`SalixMeet`). This context reads those records over
  `:erpc` (`SalixMeet.list_group_meetings/1`) so the dashboard can show each
  meeting and turn its action items into board tasks.

  The deployed meeting-summary replay claim, immutable request identity, model
  side effect, and settlement protocol are machine-checked in
  `tla/salix/MeetingSummaryReplay.tla`.
  """
  alias BridgeForTeams.Observability
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{OperationRun, Organization, Project, User}
  alias SystemsObservability.Context

  # One nested deadline budget, outermost first, so an inner diagnosis always
  # reaches the freeze instead of being masked by a generic outer timeout:
  #
  #   BFT wait (3000ms) > erpc call (2500ms) > SalixMeet read (2000ms)
  #
  # The erpc leg adds its own headroom on top of the source deadline (see
  # `BridgeForTeams.Salix.ERPC.list_group_meetings_bounded/2`), and SalixMeet
  # caps `list_group_meetings_bounded/2` at 2000ms, which is why that is the
  # innermost value.
  @triage_deadline_ms 3_000
  @triage_source_deadline_ms 2_000

  @doc """
  List the project's meeting records, newest first.

  Each record is a string-keyed map: `meeting_id`, `title`, `status`
  (`provisioning/joining/active/processing/done/failed/cancelled`),
  `reason_code` and localized `reason_message` distinguish refusal, full, removal,
  and admission timeout without exposing raw runtime errors.
  `provider`, `meet_url`, `start_at` (unix seconds), `summary`
  (`title`/`key_points`/`action_items`), `captions_count`, `artifacts`
  (kinds present, e.g. `["audio", "transcript"]`), and the Slack thread ref
  (`slack_channel_id`/`slack_thread_ts`). Delivery observability includes
  `delivery_status`, the finite `delivery_failure_kind`,
  `notes_delivery_status` (`visible/pending/unavailable`),
  `notes_delivery_surface` (`canvas/canvas_link_message/message_fallback`),
  `published_at`, `canvas_id`, `canvas_create_status`, `canvas_url`,
  `canvas_url_source`, `canvas_link_status`, and `canvas_access_status`; raw
  provider/runtime error text stays internal. `published_at` remains
  Canvas-specific even when full notes are visible through a Slack message
  fallback. `canvas_id` includes a durable provisional Canvas when access failed
  before publication. Public Canvas stages are normalized to
  finite values (`created/creating/retrying/reconciling/unavailable`,
  `resolved/resolving/unavailable`, and
  `granted/link_shared/granting/unavailable`). `canvas_url_source` is one of
  `files_info`, explicitly unverified `derived`, or `legacy` for a persisted URL
  whose original lookup provenance predates this field.

  Best-effort by design: New Home must render when Salix is down, so any
  error collapses to an empty list.
  """
  @spec list_meetings(Project.t() | nil) :: [map()]
  def list_meetings(%Project{salix_group_id: group_id}) when is_binary(group_id) do
    case Client.impl().list_group_meetings(group_id) do
      {:ok, meetings} when is_list(meetings) -> Enum.filter(meetings, &is_map/1)
      _ -> []
    end
  end

  def list_meetings(_project), do: []

  @doc "Run an authenticated, idempotent, no-delivery meeting-summary replay."
  @spec replay_summary(Organization.t(), Project.t(), User.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def replay_summary(org, project, actor, meeting_id, request_id, opts \\ [])

  def replay_summary(
        %Organization{} = org,
        %Project{salix_group_id: group_id} = project,
        %User{} = actor,
        meeting_id,
        request_id,
        opts
      )
      when is_binary(group_id) and group_id != "" and is_binary(meeting_id) and
             is_binary(request_id) and is_list(opts) do
    run_model = Keyword.get(opts, :run_model, false) == true
    external_run_id = "meeting_summary_replay:" <> request_id

    with :ok <- validate_replay_identity(meeting_id, request_id),
         {:new, run} <- create_or_replay_run(org, project, meeting_id, external_run_id, run_model) do
      execute_new_replay(run, org, project, actor, group_id, meeting_id, request_id, run_model)
    else
      {:replay, %OperationRun{} = run} -> {:ok, public_replay_run(run, true)}
      {:error, _reason} = error -> error
    end
  end

  def replay_summary(_org, _project, _actor, _meeting_id, _request_id, _opts),
    do: {:error, :invalid_replay_request}

  defp execute_new_replay(run, org, project, actor, group_id, meeting_id, request_id, run_model) do
    case record_replay_started(org, project, actor, meeting_id, request_id, run_model) do
      :ok ->
        result = run_replay(group_id, meeting_id, run_model)

        with {:ok, completed} <- complete_replay_run(run, result),
             :ok <- record_replay_completed(org, project, actor, completed, request_id) do
          {:ok, public_replay_run(completed, false)}
        end

      {:error, :audit_unavailable} = error ->
        _ = fail_replay_run(run, "audit_unavailable")
        error
    end
  end

  defp fail_replay_run(run, reason_class) do
    Observability.update_operation_run(run, %{
      status: "failed",
      reason_class: reason_class,
      finished_at: DateTime.utc_now(),
      evidence: Map.put(run.evidence, "passed", false)
    })
  end

  defp validate_replay_identity(meeting_id, request_id) do
    valid = ~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\z/

    if Regex.match?(valid, meeting_id) and Regex.match?(valid, request_id),
      do: :ok,
      else: {:error, :invalid_replay_request}
  end

  defp create_or_replay_run(org, project, meeting_id, external_run_id, run_model) do
    existing =
      Observability.list_operation_runs(org.id,
        external_run_id: external_run_id,
        limit: 1
      )
      |> List.first()

    case existing do
      %OperationRun{} = run -> replay_or_conflict(run, project.id, meeting_id, run_model)
      nil -> insert_replay_run(org, project, meeting_id, external_run_id, run_model)
    end
  end

  defp insert_replay_run(org, project, meeting_id, external_run_id, run_model) do
    attrs = %{
      org_id: org.id,
      project_id: project.id,
      run_type: "meeting_summary_replay",
      external_run_id: external_run_id,
      request_id: String.replace_prefix(external_run_id, "meeting_summary_replay:", ""),
      status: "running",
      started_at: DateTime.utc_now(),
      evidence: %{
        "meeting_id" => meeting_id,
        "mode" => if(run_model, do: "model_replay", else: "plan_only")
      }
    }

    case Observability.create_operation_run_once(attrs) do
      {:ok, run} ->
        {:new, run}

      {:error, :already_exists} ->
        case Observability.list_operation_runs(org.id,
               external_run_id: external_run_id,
               limit: 1
             ) do
          [%OperationRun{} = run | _] ->
            replay_or_conflict(run, project.id, meeting_id, run_model)

          _ ->
            {:error, :replay_run_unavailable}
        end

      {:error, _reason} ->
        {:error, :replay_run_unavailable}
    end
  end

  defp replay_or_conflict(run, project_id, meeting_id, run_model) do
    expected_mode = if(run_model, do: "model_replay", else: "plan_only")

    if run.project_id == project_id and run.evidence["meeting_id"] == meeting_id and
         run.evidence["mode"] == expected_mode,
       do: {:replay, run},
       else: {:error, :replay_request_conflict}
  end

  defp run_replay(group_id, meeting_id, run_model) do
    client = Client.impl()

    if function_exported?(client, :replay_meeting_summary, 3) do
      client.replay_meeting_summary(group_id, meeting_id, run_model: run_model)
    else
      {:error, :online_replay_unsupported}
    end
  end

  defp complete_replay_run(run, {:ok, report}) when is_map(report) do
    passed = report["passed"] == true

    Observability.update_operation_run(run, %{
      status: if(passed, do: "ok", else: "failed"),
      reason_class: if(passed, do: nil, else: "quality_gate_failed"),
      finished_at: DateTime.utc_now(),
      evidence:
        Map.merge(run.evidence, %{
          "report_json" => Jason.encode!(report),
          "passed" => passed
        })
    })
  end

  defp complete_replay_run(run, {:error, reason}) do
    Observability.update_operation_run(run, %{
      status: "failed",
      reason_class: replay_reason_class(reason),
      finished_at: DateTime.utc_now(),
      evidence: Map.put(run.evidence, "passed", false)
    })
  end

  defp complete_replay_run(run, _other),
    do: complete_replay_run(run, {:error, :invalid_replay_response})

  defp record_replay_started(org, project, actor, meeting_id, request_id, run_model) do
    case Observability.record_audit(%{
           org_id: org.id,
           actor_type: "user",
           actor_user_id: actor.id,
           actor_label: actor.email,
           action: "meeting.summary_replay.started",
           resource_type: "meeting",
           resource_id: meeting_id,
           resource_label: "Meeting summary replay",
           request_id: request_id,
           result: "ok",
           metadata: %{
             "project_id" => project.id,
             "mode" => if(run_model, do: "model_replay", else: "plan_only"),
             "delivery_writes" => false
           }
         }) do
      {:ok, _audit} -> :ok
      {:error, _changeset} -> {:error, :audit_unavailable}
    end
  end

  defp record_replay_completed(org, project, actor, run, request_id) do
    case Observability.record_audit(%{
           org_id: org.id,
           actor_type: "user",
           actor_user_id: actor.id,
           actor_label: actor.email,
           action: "meeting.summary_replay.completed",
           resource_type: "meeting",
           resource_id: run.evidence["meeting_id"],
           resource_label: "Meeting summary replay",
           request_id: request_id,
           result: if(run.status == "ok", do: "ok", else: "failed"),
           reason_class: run.reason_class,
           metadata: %{
             "project_id" => project.id,
             "operation_run_id" => run.id,
             "mode" => run.evidence["mode"],
             "passed" => run.status == "ok",
             "delivery_writes" => false
           }
         }) do
      {:ok, _audit} -> :ok
      {:error, _changeset} -> {:error, :audit_unavailable}
    end
  end

  defp public_replay_run(run, replayed?) do
    %{
      "run_id" => run.id,
      "request_id" => run.request_id,
      "meeting_id" => run.evidence["meeting_id"],
      "mode" => run.evidence["mode"],
      "status" => run.status,
      "reason_class" => run.reason_class,
      "passed" => run.status == "ok",
      "report" => decode_replay_report(run.evidence["report_json"]),
      "replayed" => replayed?,
      "delivery_writes" => false
    }
  end

  defp decode_replay_report(report_json) when is_binary(report_json) do
    case Jason.decode(report_json) do
      {:ok, report} when is_map(report) -> report
      _other -> nil
    end
  end

  defp decode_replay_report(_report_json), do: nil

  defp replay_reason_class(reason)
       when reason in [
              :online_replay_disabled,
              :meeting_not_found,
              :meeting_not_terminal,
              :transcript_missing,
              :duration_missing,
              :production_context_unavailable,
              :online_replay_unsupported
            ],
       do: Atom.to_string(reason)

  defp replay_reason_class(_reason), do: "replay_failed"

  @doc """
  Typed, bounded meeting source for one Triage evaluation.

  Unlike `list_meetings/1` this never collapses an error to an empty list: a
  frozen Triage context must not silently claim the project has no meeting
  facts. It reaches `SalixMeet.list_group_meetings_bounded/2`, which reads only
  the group's own sealed PostgreSQL projection; a Salix whose projection is not yet backfilled and
  sealed fails closed with `:meeting_source_unsealed` rather than
  degrading to the unbounded dashboard scan.

  The `function_exported?/3` guard checks the LOCAL client module — this app's
  own `:erpc` binding — not the remote Salix node. It is a wiring check ("is the
  configured client the bounded one?"). A remote node that cannot serve the call
  surfaces as an `:erpc` failure inside the task, which the `{:exit, _}` clause
  below turns into `:triage_meeting_source_unavailable`.

  The task runs under `BridgeForTeams.TaskSupervisor` with `async_nolink/2`:
  `Task.async/1` LINKS, so a crashing meeting source killed this process — the
  Triage freeze — before `Task.yield/2` could ever return the `{:exit, _}`
  diagnostic the clause below exists to produce.
  """
  @spec list_triage_meetings(Project.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_triage_meetings(%Project{salix_group_id: group_id}, opts)
      when is_binary(group_id) and group_id != "" and is_list(opts) do
    client = Client.impl()
    deadline_ms = Keyword.get(opts, :deadline_ms, @triage_deadline_ms)
    source_opts = Keyword.put(opts, :deadline_ms, source_deadline_ms(deadline_ms))

    if Code.ensure_loaded?(client) and function_exported?(client, :list_group_meetings_bounded, 2) and
         is_integer(deadline_ms) and deadline_ms > 0 do
      context = Context.capture()

      task =
        Task.Supervisor.async_nolink(BridgeForTeams.TaskSupervisor, fn ->
          Context.run(context, fn -> client.list_group_meetings_bounded(group_id, source_opts) end)
        end)

      case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok,
         {:ok, %{"meetings" => meetings, "completeness" => "complete", "truncated" => false}}}
        when is_list(meetings) ->
          {:ok, Enum.filter(meetings, &is_map/1)}

        {:ok, {:error, :meeting_source_unsealed}} ->
          {:error, :meeting_source_unsealed}

        {:ok, {:error, reason}} ->
          {:error, {:triage_meeting_source_unavailable, reason}}

        {:exit, _reason} ->
          {:error, :triage_meeting_source_unavailable}

        nil ->
          {:error, :triage_meeting_source_timeout}

        {:ok, _invalid} ->
          {:error, :triage_meeting_source_invalid}
      end
    else
      {:error, :triage_meeting_source_unavailable}
    end
  end

  def list_triage_meetings(_project, _opts), do: {:error, :triage_meeting_source_invalid}

  # The source deadline stays strictly inside the wait it runs under, so a
  # typed inner refusal (`:truncated`, `:unavailable`) always wins the race
  # against this process's generic timeout.
  defp source_deadline_ms(deadline_ms) when is_integer(deadline_ms),
    do: min(@triage_source_deadline_ms, max(10, div(deadline_ms * 2, 3)))

  defp source_deadline_ms(_deadline_ms), do: @triage_source_deadline_ms

  @doc "Whether the meeting reached a terminal state with a usable outcome."
  @spec summarized?(map()) :: boolean()
  def summarized?(meeting) when is_map(meeting) do
    meeting["status"] == "done" and is_map(meeting["summary"])
  end

  @doc """
  The meeting's action items as a normalized list of
  `%{"description" => ..., "owner" => ..., "deadline" => ...}` maps
  (string items become description-only maps; blank ones are dropped).
  """
  @spec action_items(map()) :: [map()]
  def action_items(meeting) when is_map(meeting) do
    meeting["summary"]
    |> Kernel.||(%{})
    |> Map.get("action_items")
    |> List.wrap()
    |> Enum.flat_map(&normalize_action_item/1)
  end

  defp normalize_action_item(item) when is_binary(item) do
    case String.trim(item) do
      "" -> []
      description -> [%{"description" => description, "owner" => "", "deadline" => ""}]
    end
  end

  defp normalize_action_item(item) when is_map(item) do
    description = item |> Map.get("description") |> to_string() |> String.trim()

    if description == "" do
      []
    else
      [
        %{
          "description" => description,
          "owner" => item |> Map.get("owner") |> to_string() |> String.trim(),
          "deadline" => item |> Map.get("deadline") |> to_string() |> String.trim()
        }
      ]
    end
  end

  defp normalize_action_item(_item), do: []
end
