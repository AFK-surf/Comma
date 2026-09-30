defmodule BridgeForTeams.Schedules do
  @moduledoc """
  Recurring schedules owned by a project's Agent Swarm.

  Salix is the source of truth: schedule definitions are rows in the salix
  control Postgres (`SalixCluster.Schedules` over
  docs/storage-search.md), carrying the owning `agent_id`
  (a Salix agent id) or a Task receiver payload bound to a Salix group.
  Listing is owner-filtered at the store: this context asks Salix over
  `:erpc` for exactly the project's agent ids plus its Task group binding,
  and unrelated schedules are neither queried nor transferred. Each result is
  tagged with its target type so the dashboard can render the right
  destination.
  """
  require Logger

  alias BridgeForTeams.{Agents, Observability}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Agent, Project}

  # Salix briefly unreachable — surface so the UI can say so rather than show a
  # misleadingly empty list.
  @transient [:unavailable, :timeout]

  @doc """
  List every schedule owned by the project, including task schedules bound to
  its Salix group.

  Returns `{:ok, [schedule]}` where each `schedule` is the string-keyed Salix
  definition decorated with its target. Agent schedules include the owning
  agent:

      %{"id" => "sch1_…", "agent_id" => "agt1_…", "prompt" => "…",
        "interval_minutes" => 5, "cron" => nil, "timezone" => "UTC",
        "created_at" => 1_700_000_000_000, "last_run" => nil,
        "bft_agent_id" => <bft agent uuid>, "agent_name" => "router",
        "target_type" => "agent"}

  Task schedules instead carry `"target_type" => "task"` and their
  `"conversation_id"`. Schedules are ordered by target then creation time. When
  Salix is unreachable the whole call returns `{:error, :unavailable | :timeout}`.
  """
  @spec list_project_schedules(Project.t()) :: {:ok, [map()]} | {:error, term()}
  def list_project_schedules(%Project{} = project) do
    case Agents.fetch_agents(project.id) do
      {:ok, agents} ->
        list_project_schedules(project, Map.new(agents, &{&1.salix_agent_id, &1}))

      {:error, _} = error ->
        maybe_record_schedule_list_diagnostic(project, %{}, error)
        error
    end
  end

  defp list_project_schedules(project, agents_by_salix_id) do
    result =
      case Client.impl().list_schedules_for_owners(
             Map.keys(agents_by_salix_id),
             project.salix_group_id
           ) do
        {:ok, schedules} when is_list(schedules) ->
          decorated =
            schedules
            |> Enum.flat_map(
              &decorate_project_schedule(&1, agents_by_salix_id, project.salix_group_id)
            )
            |> Enum.sort_by(&schedule_sort_key/1)

          {:ok, decorated}

        {:error, reason} when reason in @transient ->
          {:error, reason}

        {:error, _other} = err ->
          err
      end

    maybe_record_schedule_list_diagnostic(project, agents_by_salix_id, result)

    result
  end

  defp maybe_record_schedule_list_diagnostic(
         %Project{} = project,
         agents_by_salix_id,
         {:error, reason}
       )
       when reason in @transient do
    reason_class = Atom.to_string(reason)

    attrs = %{
      org_id: project.org_id,
      project_id: project.id,
      domain: "schedule",
      resource_type: "project_schedule_index",
      resource_id: project.id,
      source: "salix.schedule",
      event_type: "project.schedules.unavailable",
      severity: "warning",
      status: "unavailable",
      reason_class: reason_class,
      summary: "Project schedules could not be loaded from Salix",
      evidence: %{
        "project_id" => project.id,
        "salix_group_id" => project.salix_group_id,
        "salix_agent_count" => map_size(agents_by_salix_id),
        "surface" => "project_schedules",
        "reason_class" => reason_class,
        "status" => "unavailable"
      },
      correlation_id: "project:#{project.id}:schedules:index",
      occurred_at: DateTime.utc_now()
    }

    case Observability.create_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, observability_reason} ->
        Logger.warning(
          "project_schedules_observability_failed reason=#{inspect(observability_reason)} project_id=#{project.id}"
        )
    end
  end

  defp maybe_record_schedule_list_diagnostic(_project, _agents_by_salix_id, _result), do: :ok

  # Definition fields a project may set on its schedules. The schedule `id` and
  # the owning `agent_id` are stamped here, never caller-controlled.
  @writable_fields ~w(prompt cron interval_minutes timezone session_id)

  @doc """
  Create a recurring schedule owned by one of the project's agents.

  `attrs` (string or atom keys) carries the definition: a non-empty `prompt`,
  exactly one of a positive integer `interval_minutes` or a `cron` expression
  (with an optional IANA `timezone`), and an optional `session_id`. The target
  agent is `attrs["agent_id"]` — either a BridgeForTeams agent uuid or a
  `salix_agent_id`, which must belong to the project; when omitted the
  project's first provisioned agent owns the schedule. The Salix definition's
  `agent_id` is stamped from the resolved agent here, never caller-controlled.

  Returns `{:ok, schedule}` decorated like `list_project_schedules/1`,
  `{:error, :invalid_schedule}` for a bad definition,
  `{:error, :agent_not_found}` when the named agent isn't the project's,
  `{:error, :no_agent}` when the project has no provisioned agent, or the
  Salix error (`:unavailable | :timeout | ...`).
  """
  @spec create_project_schedule(Project.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_project_schedule(%Project{} = project, attrs, opts \\ []) when is_map(attrs) do
    attrs = stringify(attrs)
    schedule_id = SalixStore.Ids.new_schedule_id()

    result =
      with {:ok, agent} <- resolve_target_agent(project, attrs["agent_id"]) do
        definition =
          attrs
          |> Map.take(@writable_fields)
          |> Map.merge(%{"id" => schedule_id, "agent_id" => agent.salix_agent_id})

        with :ok <- validate_definition(definition),
             {:ok, schedule} <- Client.impl().create_schedule(definition) do
          {:ok, decorate_agent(schedule, agent)}
        end
      end

    case result do
      {:ok, schedule} ->
        maybe_record_schedule_audit(
          project,
          "project_schedule.created",
          schedule["id"],
          schedule,
          opts
        )

        {:ok, schedule}

      {:error, _reason} = err ->
        maybe_record_schedule_write_attempt(
          err,
          project,
          "project_schedule.created",
          schedule_id,
          nil,
          opts
        )

        err
    end
  end

  @doc """
  Merge `changes` into the schedule `schedule_id`, but only when it is owned by
  one of the project's agents — updating another swarm's schedule (or an
  unknown id) returns `{:error, :not_found}`.

  Only #{inspect(@writable_fields)} may change; the schedule `id` and owning
  `agent_id` cannot. Cron and interval stay mutually exclusive: switching the
  recurrence kind explicitly nils out the other field in the merged Salix
  definition, and a merge that would leave neither (or both) valid returns
  `{:error, :invalid_schedule}`.
  """
  @spec update_project_schedule(Project.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_project_schedule(%Project{} = project, schedule_id, changes, opts \\ [])
      when is_binary(schedule_id) and is_map(changes) do
    changes = changes |> stringify() |> Map.take(@writable_fields)

    result =
      with {:ok, current} <- find_owned_schedule(project, schedule_id),
           changes = normalize_recurrence_switch(changes, current),
           :ok <- validate_changes(changes),
           :ok <- validate_definition(Map.merge(current, changes)),
           {:ok, updated} <- Client.impl().update_schedule(schedule_id, changes) do
        {:ok, Map.merge(updated, Map.take(current, ["bft_agent_id", "agent_name"]))}
      end

    case result do
      {:ok, schedule} ->
        maybe_record_schedule_audit(
          project,
          "project_schedule.updated",
          schedule_id,
          schedule,
          opts
        )

        {:ok, schedule}

      {:error, _reason} = err ->
        maybe_record_schedule_write_attempt(
          err,
          project,
          "project_schedule.updated",
          schedule_id,
          nil,
          opts
        )

        err
    end
  end

  @doc """
  Delete the schedule `schedule_id`, but only when it is owned by one of the
  project's agents — deleting another swarm's schedule (or an unknown id) returns
  `{:error, :not_found}`. Otherwise delegates to Salix (idempotent on a missing
  id) and returns `:ok` on success.
  """
  @spec delete_project_schedule(Project.t(), String.t(), keyword()) ::
          :ok | {:error, :not_found} | {:error, term()}
  def delete_project_schedule(%Project{} = project, schedule_id, opts \\ [])
      when is_binary(schedule_id) do
    case find_owned_schedule(project, schedule_id) do
      {:ok, schedule} ->
        case Client.impl().delete_schedule(schedule_id) do
          :ok ->
            maybe_record_schedule_audit(
              project,
              "project_schedule.deleted",
              schedule_id,
              schedule,
              opts
            )

            :ok

          {:error, _reason} = err ->
            maybe_record_schedule_write_attempt(
              err,
              project,
              "project_schedule.deleted",
              schedule_id,
              schedule,
              opts
            )

            err
        end

      {:error, _reason} = err ->
        maybe_record_schedule_write_attempt(
          err,
          project,
          "project_schedule.deleted",
          schedule_id,
          nil,
          opts
        )

        err
    end
  end

  # The decorated schedule when one of the project's agents owns `schedule_id`,
  # `{:error, :not_found}` otherwise (or the listing error).
  defp find_owned_schedule(%Project{} = project, schedule_id) do
    with {:ok, schedules} <- list_project_schedules(project) do
      case Enum.find(schedules, &(&1["id"] == schedule_id and &1["target_type"] == "agent")) do
        nil -> {:error, :not_found}
        schedule -> {:ok, schedule}
      end
    end
  end

  defp resolve_target_agent(%Project{} = project, agent_id) do
    with {:ok, agents} <- Agents.fetch_agents(project.id) do
      if agent_id in [nil, ""] do
        case agents do
          [agent | _rest] -> {:ok, agent}
          [] -> {:error, :no_agent}
        end
      else
        case Enum.find(agents, &(&1.id == agent_id or &1.salix_agent_id == agent_id)) do
          %Agent{} = agent -> {:ok, agent}
          nil -> {:error, :agent_not_found}
        end
      end
    end
  end

  # Mirrors the salix-side create validation (`SalixCluster.Schedules`): a
  # non-empty prompt plus exactly one of a positive `interval_minutes` or a
  # `cron` expression. Applied to the full (merged) definition so updates can't
  # drift into an unfireable shape; nil values count as absent because that is
  # how the salix due math treats them.
  defp validate_definition(definition) do
    cond do
      not nonblank?(definition["prompt"]) -> {:error, :invalid_schedule}
      not recurrence_valid?(definition) -> {:error, :invalid_schedule}
      not optional_string?(definition["timezone"]) -> {:error, :invalid_schedule}
      not optional_string?(definition["session_id"]) -> {:error, :invalid_schedule}
      true -> :ok
    end
  end

  defp recurrence_valid?(definition) do
    interval = definition["interval_minutes"]
    cron = definition["cron"]

    cond do
      is_integer(interval) and interval > 0 -> is_nil(cron)
      nonblank?(cron) -> is_nil(interval)
      true -> false
    end
  end

  defp validate_changes(changes) when changes == %{}, do: {:error, :invalid_schedule}
  defp validate_changes(_changes), do: :ok

  # Cron and interval are mutually exclusive in a definition, but the salix
  # update is a blind CAS merge — switching kinds must explicitly nil out the
  # other field or the stale one would linger (and an integer interval always
  # wins the due math).
  defp normalize_recurrence_switch(changes, current) do
    cond do
      nonblank?(changes["cron"]) and not Map.has_key?(changes, "interval_minutes") and
          not is_nil(current["interval_minutes"]) ->
        Map.put(changes, "interval_minutes", nil)

      is_integer(changes["interval_minutes"]) and not Map.has_key?(changes, "cron") and
          not is_nil(current["cron"]) ->
        Map.put(changes, "cron", nil)

      true ->
        changes
    end
  end

  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_value), do: false

  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp maybe_record_schedule_audit(%Project{} = project, action, schedule_id, schedule, opts) do
    if audit_enabled?(opts) do
      case Observability.record_audit(%{
             org_id: project.org_id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: "project_schedule",
             resource_id: schedule_id,
             resource_label: schedule_label(schedule_id, schedule),
             result: "ok",
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             metadata: schedule_metadata(project, schedule_id, schedule)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, reason} ->
          Logger.warning("schedule_audit_failed action=#{action} reason=#{inspect(reason)}")
          :ok
      end
    end
  end

  defp maybe_record_schedule_write_attempt(
         {:error, reason},
         project,
         action,
         schedule_id,
         schedule,
         opts
       ) do
    if audit_enabled?(opts) do
      case Observability.record_write_attempt(%{
             org_id: project.org_id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: "project_schedule",
             resource_id: schedule_id,
             resource_label: schedule_label(schedule_id, schedule),
             result: "failed",
             reason: reason,
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             surface: "schedule",
             metadata: schedule_metadata(project, schedule_id, schedule)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, audit_reason} ->
          Logger.warning(
            "schedule_write_attempt_audit_failed action=#{action} reason=#{inspect(audit_reason)}"
          )

          :ok
      end
    end
  end

  defp decorate_project_schedule(schedule, agents_by_salix_id, group_id) when is_map(schedule) do
    cond do
      # A Task row's ownership is decided by its group binding ONLY: a Task
      # bound to another group must never fall through to the agent branch
      # (it would be decorated as target_type "agent" and become mutable —
      # including deletable — by the wrong project).
      schedule["receiver"] == "task" ->
        if task_schedule_for_group?(schedule, group_id),
          do: [decorate_task(schedule)],
          else: []

      agent = agents_by_salix_id[schedule["agent_id"]] ->
        [decorate_agent(schedule, agent)]

      true ->
        []
    end
  end

  defp decorate_project_schedule(_schedule, _agents_by_salix_id, _group_id), do: []

  defp task_schedule_for_group?(
         %{
           "receiver" => "task",
           "payload" => %{
             "agent_group_id" => group_id,
             "conversation_id" => conversation_id
           }
         },
         group_id
       )
       when is_binary(conversation_id) and conversation_id != "",
       do: true

  defp task_schedule_for_group?(_schedule, _group_id), do: false

  defp decorate_agent(schedule, %Agent{} = agent) when is_map(schedule) do
    Map.merge(schedule, %{
      "bft_agent_id" => agent.id,
      "agent_name" => agent.salix["name"] || agent.salix_agent_id,
      "target_type" => "agent"
    })
  end

  defp decorate_task(%{"payload" => %{"conversation_id" => conversation_id}} = schedule) do
    Map.merge(schedule, %{
      "conversation_id" => conversation_id,
      "target_type" => "task"
    })
  end

  defp schedule_sort_key(%{"target_type" => "task"} = schedule) do
    {1, schedule["conversation_id"], schedule["created_at"] || 0}
  end

  defp schedule_sort_key(schedule) do
    {0, schedule["agent_name"] || schedule["agent_id"] || "", schedule["created_at"] || 0}
  end

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      configured?(Keyword.get(opts, :actor_user_id)) ||
      configured?(Keyword.get(opts, :actor_label))
  end

  defp configured?(value) when is_binary(value), do: String.trim(value) != ""
  defp configured?(value), do: not is_nil(value)

  defp schedule_label(schedule_id, schedule) when is_map(schedule) do
    schedule["agent_name"] || schedule["agent_id"] || schedule_id
  end

  defp schedule_label(schedule_id, _schedule), do: schedule_id

  defp schedule_metadata(%Project{} = project, schedule_id, schedule) do
    %{
      "project_id" => project.id,
      "salix_group_id" => project.salix_group_id,
      "schedule_id" => schedule_id,
      "salix_agent_id" => schedule && schedule["agent_id"],
      "bft_agent_id" => schedule && schedule["bft_agent_id"],
      "agent_name_configured" => configured?(schedule && schedule["agent_name"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
