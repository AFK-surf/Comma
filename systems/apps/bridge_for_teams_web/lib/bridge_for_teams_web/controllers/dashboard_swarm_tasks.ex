defmodule BridgeForTeamsWeb.DashboardSwarmTasks do
  @moduledoc """
  Builds the Agent Swarm Tasks page payloads and applies its writes for
  `DashboardAPIController`.

  Tasks are Salix conversations of the swarm's group, read one page of
  100 at a time, most recently updated first; `next_cursor` continues the
  list. The first page also carries the swarm's agents (one bounded Salix
  page) for the New task form. Search and the status filter run in the
  browser over the pages loaded so far. When Salix is down, the first page
  answers `status: "unavailable"`; a later page answers 503 so the browser
  keeps its cursor, and a stale or malformed cursor answers 422.

  The Scheduled view lists the swarm's recurring schedules: one
  owner-filtered Salix read, cut to 200 rows. Schedules are created and
  edited in task detail; this page only deletes them.

  Every swarm member reads; only swarm admins write. A refused write records a
  denied audit entry, as the LiveView page did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Agents, Conversations, Observability, Schedules}
  alias BridgeForTeamsWeb.Dashboard.SchedulePresentation

  @task_page 100
  @agent_page_limit 500
  @schedule_limit 200

  @doc "One page of tasks; the first page adds the agents a new task can use."
  def page(org, project, role, params) do
    cursor = text(params["cursor"])

    case Conversations.page_project_conversations(project, limit: @task_page, cursor: cursor) do
      {:ok, page} ->
        data = %{
          "project" => public_project(project, role),
          "tasks" => Enum.map(page.items, &public_task(&1, org, project)),
          "next_cursor" => page.next_cursor,
          "status" => "ok"
        }

        {:ok, if(cursor, do: data, else: Map.put(data, "agents", agents(project)))}

      {:error, :invalid_cursor} ->
        invalid_cursor()

      {:error, {:bad_request, _reason}} ->
        invalid_cursor()

      # A later page that fails is not the end of the list: the client keeps
      # its cursor and offers a retry.
      {:error, _reason} when is_binary(cursor) ->
        {:error, 503, "runtime_unavailable",
         gettext("Could not load more tasks. Salix is unavailable — retry shortly."), %{}}

      {:error, _reason} ->
        {:ok,
         %{
           "project" => public_project(project, role),
           "tasks" => [],
           "next_cursor" => nil,
           "status" => "unavailable",
           "agents" => agents(project)
         }}
    end
  end

  defp invalid_cursor,
    do:
      {:error, 422, "invalid_cursor", gettext("This page of tasks is no longer available."), %{}}

  @doc "Create a task for one of the swarm's agents; answers its detail address."
  def create(org, user, project, role, params) do
    agent_id = text(params["agent_id"])

    if role == "admin" do
      with {:ok, agents} <- agent_choices(project),
           %{} = agent <- Enum.find(agents, &(&1.id == agent_id)),
           {:ok, conversation} <-
             Conversations.create_project_conversation(
               project,
               agent,
               %{"title" => text(params["title"]) || ""},
               audit_opts(user)
             ) do
        id = conversation["conversation_id"]
        {:ok, %{"id" => id, "href" => task_href(org, project, id)}}
      else
        nil ->
          {:error, 422, "invalid_agent", gettext("Choose an agent for this task."),
           %{"fields" => %{"agent_id" => [gettext("Choose an agent for this task.")]}}}

        {:error, _reason} ->
          {:error, 503, "write_failed", gettext("Could not create the task."), %{}}
      end
    else
      record_denied(
        org,
        user,
        project,
        "project_conversation.created",
        "project_conversation",
        "conversation",
        %{"agent_id_configured" => not is_nil(agent_id)}
      )

      forbidden(gettext("Only Agent Swarm admins can manage tasks."))
    end
  end

  @doc "The swarm's recurring schedules, agent and task schedules alike."
  def schedules(org, project, role) do
    case Schedules.list_project_schedules(project) do
      {:ok, schedules} ->
        {:ok,
         %{
           "project" => public_project(project, role),
           "status" => "ok",
           "schedules" =>
             schedules
             |> Enum.take(@schedule_limit)
             |> Enum.map(&public_schedule(&1, org, project)),
           "truncated" => length(schedules) > @schedule_limit
         }}

      {:error, _reason} ->
        {:ok,
         %{
           "project" => public_project(project, role),
           "status" => "unavailable",
           "schedules" => [],
           "truncated" => false
         }}
    end
  end

  @doc """
  Delete one schedule. A task schedule clears the task's binding and keeps the
  task; an agent schedule is deleted in Salix. Answers the refreshed list.
  """
  def delete_schedule(org, user, project, role, schedule_id) do
    if role == "admin" do
      with {:ok, schedules} <- Schedules.list_project_schedules(project),
           :ok <- delete_listed(schedules, schedule_id, project, user) do
        schedules(org, project, role)
      else
        {:error, :not_found} ->
          {:error, 404, "schedule_not_found", gettext("That schedule no longer exists."), %{}}

        {:error, _reason} ->
          {:error, 503, "write_failed", gettext("Could not delete the schedule."), %{}}
      end
    else
      record_denied(
        org,
        user,
        project,
        "project_schedule.deleted",
        "project_schedule",
        "schedule",
        %{"schedule_id_configured" => not is_nil(text(schedule_id))}
      )

      forbidden(gettext("Only Agent Swarm admins can manage schedules."))
    end
  end

  defp delete_listed(schedules, schedule_id, project, user) do
    case Enum.find(schedules, &(&1["id"] == schedule_id)) do
      %{"target_type" => "task", "conversation_id" => conversation_id} ->
        with {:ok, _conversation} <-
               Conversations.delete_project_task_schedule(
                 project,
                 conversation_id,
                 audit_opts(user)
               ),
             do: :ok

      %{"target_type" => "agent"} ->
        Schedules.delete_project_schedule(project, schedule_id, audit_opts(user))

      _missing ->
        {:error, :not_found}
    end
  end

  # One bounded Salix page. More agents than the page holds is refused rather
  # than guessed, as on the LiveView page.
  defp agent_choices(project) do
    case Agents.page_agents(project, limit: @agent_page_limit) do
      {:ok, %{items: items, next_cursor: nil}} -> {:ok, items}
      {:ok, _page} -> {:error, :agent_page_required}
      {:error, _reason} = error -> error
    end
  end

  defp agents(project) do
    case agent_choices(project) do
      {:ok, agents} ->
        %{
          "status" => "ok",
          "items" =>
            Enum.map(agents, &%{"id" => &1.id, "name" => &1.salix["name"] || &1.salix_agent_id})
        }

      {:error, _reason} ->
        %{"status" => "unavailable", "items" => []}
    end
  end

  defp public_task(conversation, org, project) do
    id = conversation["conversation_id"]

    %{
      "id" => id,
      "title" => text(conversation["title"]),
      "status" => text(conversation["status"]) || "active",
      "kind" => text(conversation["kind"]),
      "scheduled" => scheduled?(conversation),
      "updated_at" => iso_timestamp(conversation["updated_at"]),
      "href" => task_href(org, project, id)
    }
  end

  defp scheduled?(%{"schedule" => %{"schedule_id" => id}}), do: not is_nil(text(id))
  defp scheduled?(_conversation), do: false

  defp public_schedule(schedule, org, project) do
    task? = schedule["target_type"] == "task"

    %{
      "id" => schedule["id"],
      "target" => if(task?, do: "task", else: "agent"),
      "agent_name" => if(task?, do: nil, else: schedule["agent_name"]),
      "prompt" => if(task?, do: nil, else: text(schedule["prompt"])),
      "recurrence" => SchedulePresentation.recurrence(schedule),
      "last_run_at" => iso_timestamp(schedule["last_run"]),
      "href" =>
        if(task?,
          do: task_href(org, project, schedule["conversation_id"]),
          else: "/orgs/#{org.slug}/projects/#{project.id}/agents/#{schedule["bft_agent_id"]}"
        )
    }
  end

  defp public_project(project, role),
    do: %{"id" => project.id, "name" => project.name, "role" => role}

  defp task_href(org, project, id), do: "/orgs/#{org.slug}/projects/#{project.id}/tasks/#{id}"

  defp record_denied(org, user, project, action, resource_type, surface, metadata) do
    _ =
      Observability.record_write_attempt(%{
        org_id: org.id,
        actor_user_id: user.id,
        actor_label: actor_label(user),
        action: action,
        resource_type: resource_type,
        resource_label: project.name,
        result: "denied",
        reason: :forbidden,
        request_id: Ecto.UUID.generate(),
        surface: surface,
        metadata:
          Map.merge(
            %{
              "project_id" => project.id,
              "salix_group_id" => project.salix_group_id,
              "surface" => surface
            },
            metadata
          )
      })

    :ok
  end

  defp forbidden(message), do: {:error, 403, "forbidden", message, %{}}

  defp audit_opts(user),
    do: [actor_user_id: user.id, actor_label: actor_label(user), request_id: Ecto.UUID.generate()]

  defp actor_label(user), do: text(user.email) || text(user.name) || user.id

  # Salix stores times as unix seconds or milliseconds.
  defp iso_timestamp(value) when is_integer(value) do
    unit = if value > 99_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp iso_timestamp(value) when is_binary(value), do: value
  defp iso_timestamp(_value), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
