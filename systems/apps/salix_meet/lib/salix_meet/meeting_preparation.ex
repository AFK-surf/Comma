defmodule SalixMeet.MeetingPreparation do
  @moduledoc "Authorization for meeting coordination and assigned Task research."

  alias SalixMeet.{MeetingPlan, PreparationTask}
  alias SalixStore.{Keys, S3}

  def authorize_organization_call(call, ctx),
    do: SalixMeet.PreparationAuthority.authorize_call(call, ctx)

  def seal_schedule(id, payload, scheduled_for),
    do: SalixMeet.PreparationAuthority.seal_schedule(id, payload, scheduled_for)

  def start_research(group_id, plan_id, revision, worker_id, caller_agent_id) do
    with :ok <- authorize_router(group_id, caller_agent_id) do
      PreparationTask.start(group_id, plan_id, revision, caller_agent_id, worker_id)
    end
  end

  def open_trigger(
        group_id,
        meeting_plan_id,
        trigger_kind,
        dispatch_revision,
        caller_agent_id,
        session_id \\ nil
      ) do
    with :ok <- authorize_author(group_id, meeting_plan_id, caller_agent_id, session_id) do
      MeetingPlan.open_trigger(group_id, meeting_plan_id, trigger_kind, dispatch_revision)
    end
  end

  def record_decision(
        group_id,
        meeting_plan_id,
        dispatch_revision,
        decision,
        baseline,
        caller_agent_id,
        session_id \\ nil
      ) do
    with :ok <- authorize_author(group_id, meeting_plan_id, caller_agent_id, session_id) do
      MeetingPlan.record_decision(
        group_id,
        meeting_plan_id,
        dispatch_revision,
        decision,
        baseline
      )
    end
  end

  def publish_report(group_id, plan_id, revision, report, caller_agent_id, session_id \\ nil) do
    with :ok <- authorize_author(group_id, plan_id, caller_agent_id, session_id),
         {:ok, plan} <- MeetingPlan.prepare_report(group_id, plan_id, revision, report) do
      writeback =
        case SalixMeet.Ports.CalendarPreparation.write(plan) do
          {:ok, result} ->
            result

          {:error, :calendar_preparation_write_unknown} ->
            %{"status" => "unknown", "reason" => "Read the exact event before another attempt."}

          {:error, reason} ->
            %{"status" => "failed", "reason" => inspect(reason)}
        end

      {:ok,
       %{
         "status" => "saved",
         "notice" => "scheduled_for_T_minus_#{plan["preparation_lead_minutes"] || 10}",
         "calendar_writeback" => writeback
       }}
    end
  end

  def personal_context(group_id, plan_id, revision, cursor, caller_id, session_id) do
    with :ok <- authorize_author(group_id, plan_id, caller_id, session_id),
         {:ok, plan} <- current_plan(group_id, plan_id, revision) do
      SalixMeet.PersonalPreparation.context(plan, cursor: cursor)
    end
  end

  def read_recipient(group_id, plan_id, revision, user_id, caller_id, session_id) do
    with :ok <- authorize_author(group_id, plan_id, caller_id, session_id),
         {:ok, plan} <- current_plan(group_id, plan_id, revision) do
      SalixMeet.PersonalPreparation.read_recipient(plan, user_id)
    end
  end

  def read_status(group_id, plan_id, revision, caller_id, session_id) do
    with :ok <- authorize_author(group_id, plan_id, caller_id, session_id),
         {:ok, plan} <- current_plan(group_id, plan_id, revision),
         {:ok, pending?} <- SalixMeet.PersonalPreparation.has_pending?(plan),
         {:ok, complete?} <- SalixMeet.PersonalPreparation.research_complete?(plan) do
      {:ok,
       %{
         "shared_report_saved" => is_binary(get_in(plan, ["preparation", "report"])),
         "personal_reports_pending" => pending?,
         "personal_research_complete" => complete?,
         "source_label" => [
           "task|" <> get_in(plan, ["preparation", "research_task", "conversation_id"])
         ]
       }}
    end
  end

  def read_shared_source(group_id, plan_id, revision, args, caller_id, session_id) do
    with :ok <- authorize_author(group_id, plan_id, caller_id, session_id),
         {:ok, plan} <- current_plan(group_id, plan_id, revision) do
      SalixMeet.PreparationSources.read(plan, args)
    end
  end

  def validate_completion(plan) do
    with true <- is_binary(get_in(plan, ["preparation", "report"])),
         {:ok, true} <- SalixMeet.PersonalPreparation.research_complete?(plan) do
      :ok
    else
      _ -> {:error, :meeting_preparation_incomplete}
    end
  end

  def publish_personal_report(
        group_id,
        plan_id,
        revision,
        connect_id,
        user_id,
        report,
        evidence,
        caller_id,
        session_id
      ) do
    with :ok <- authorize_author(group_id, plan_id, caller_id, session_id),
         {:ok, plan} <- current_plan(group_id, plan_id, revision) do
      SalixMeet.PersonalPreparation.submit(plan, connect_id, user_id, report, evidence,
        author: %{"agent_id" => caller_id, "session_id" => session_id}
      )
    end
  end

  def set_personal_reminders(group_id, origin, enabled),
    do: SalixMeet.PersonalPreparation.set_preference(group_id, origin, enabled)

  defp current_plan(group_id, plan_id, revision) do
    with {:ok, plan} <- MeetingPlan.get(group_id, plan_id) do
      if get_in(plan, ["preparation", "dispatch_revision"]) == revision,
        do: {:ok, plan},
        else: {:error, :stale_dispatch_revision}
    end
  end

  defp authorize_author(group_id, plan_id, caller_id, session_id) do
    with {:ok, plan} <- MeetingPlan.get(group_id, plan_id) do
      if get_in(plan, ["publication_target", "provider"]) == "slack" do
        PreparationTask.authorize(plan, caller_id, session_id)
      else
        authorize_router(group_id, caller_id)
      end
    end
  end

  defp authorize_router(group_id, caller_agent_id) do
    with {:ok, %{body: body}} <- S3.get(Keys.ctl_group(group_id)),
         {:ok, %{"router_agent_id" => ^caller_agent_id}} <- Jason.decode(body) do
      :ok
    else
      {:ok, _other} -> {:error, :router_required}
      {:error, _} = error -> error
      _ -> {:error, :router_required}
    end
  end
end
