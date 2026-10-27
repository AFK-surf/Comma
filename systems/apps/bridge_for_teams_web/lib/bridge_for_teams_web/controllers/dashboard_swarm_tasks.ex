defmodule BridgeForTeamsWeb.DashboardSwarmTasks do
  @moduledoc """
  Builds the Agent Swarm Tasks page payloads and applies its writes for
  `DashboardAPIController`.

  Tasks are Salix conversations of the swarm's group, read one page of
  100 at a time, most recently updated first; `next_cursor` continues the
  list. Search and the status filter run in the browser over the pages
  loaded so far. When Salix is down, the first page answers
  `status: "unavailable"`; a later page answers 503 so the browser keeps its
  cursor, and a stale or malformed cursor answers 422.

  A new Task goes to the swarm's Task agent through its Router
  (`BridgeForTeams.Conversations.create_project_task_conversation/4`). The
  New task form chooses where it runs and its model from `targets/3`: inside
  Salix, the swarm's Cloud VM while it is on, or a connected station that
  takes Tasks, with the swarm's default place and default Task model marked.

  The Scheduled view lists the swarm's recurring schedules: one
  owner-filtered Salix read, cut to 200 rows. Schedules are created and
  edited in task detail; this page only deletes them.

  Every swarm member reads and creates Tasks, on any place of the swarm; only
  swarm admins delete schedules. A refused write records a denied audit
  entry, as the LiveView page did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Agents, Conversations, Models, Observability, Projects, Schedules}
  alias BridgeForTeamsWeb.Dashboard.SchedulePresentation
  alias BridgeForTeamsWeb.StationNotice

  @task_page 100
  @schedule_limit 200
  @task_roles ~w(admin user)
  @platform_task_model %{"kind" => "platform", "tier" => "worker"}

  @doc "One page of tasks."
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

        {:ok, data}

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
           "status" => "unavailable"
         }}
    end
  end

  defp invalid_cursor,
    do:
      {:error, 422, "invalid_cursor", gettext("This page of tasks is no longer available."), %{}}

  @doc """
  Create a Task with `title` and `content`; answers its detail address. It may
  name where it runs (`runs_on`) and its model (`model`), as `targets/3` lists
  them; without them the swarm's default place and default Task model apply.
  An `agent_id` is ignored: the swarm's Task agent runs every Task.
  """
  def create(org, user, project, role, params) do
    if role in @task_roles do
      with {:ok, attrs} <- task_attrs(params),
           {:ok, router} <- router(project),
           {:ok, %{"conversation_id" => id}} <-
             Conversations.create_project_task_conversation(
               project,
               router,
               attrs,
               audit_opts(user)
             ) do
        {:ok, %{"id" => id, "href" => task_href(org, project, id)}}
      else
        {:error, _status, _code, _message, _details} = error -> error
        {:error, reason} -> create_error(reason)
      end
    else
      record_denied(
        org,
        user,
        project,
        "project_conversation.created",
        "project_conversation",
        "conversation",
        %{}
      )

      forbidden(gettext("Only Agent Swarm members can create tasks."))
    end
  end

  defp task_attrs(params) do
    content = text(params["content"])

    cond do
      Map.has_key?(params, "requester_user_id") or Map.has_key?(params, "automatic_task_place") ->
        {:error, 422, "invalid_task",
         gettext("The Task requester comes from your signed-in session."), %{}}

      is_nil(content) ->
        message = gettext("Say what the task should do.")
        {:error, 422, "invalid_task", message, %{"fields" => %{"content" => [message]}}}

      not optional_object?(params["runs_on"]) or not optional_object?(params["model"]) ->
        {:error, 422, "invalid_place",
         gettext("Choose Salix, the Cloud VM or a station of this swarm."), %{}}

      true ->
        {:ok,
         %{"title" => text(params["title"]) || "", "content" => content}
         |> put_present("runs_on", params["runs_on"])
         |> put_present("model", params["model"])}
    end
  end

  defp optional_object?(value), do: is_nil(value) or is_map(value)

  defp router(project) do
    case Agents.current_router(project) do
      {:ok, router} -> {:ok, router}
      {:error, reason} when reason in [:unavailable, :timeout] -> {:error, :unavailable}
      {:error, _reason} -> {:error, :router_not_configured}
    end
  end

  # Salix refused the place or the model, or could not take the Task now. A
  # Salix node of the release before answers unavailable: the browser asks
  # again.
  defp create_error({:runs_on, reason, _source}), do: place_error(reason)

  defp create_error({:model, {:not_on_station, _models}}),
    do:
      {:error, 422, "invalid_model",
       gettext("That station has no profile with this model enabled. Choose another model."), %{}}

  defp create_error({:model, :model_not_allowed}),
    do:
      {:error, 422, "invalid_model",
       gettext("The organization does not allow this model. Choose another model."), %{}}

  defp create_error({:model, _reason}),
    do: {:error, 422, "invalid_model", gettext("Choose a model from the list."), %{}}

  defp create_error({:bad_request, _message}),
    do:
      {:error, 422, "task_refused",
       gettext("The station did not take the task. Check the station and try again."), %{}}

  defp create_error(reason)
       when reason in [:router_not_configured, :router_changed],
       do:
         {:error, 409, "router_not_configured",
          gettext("This Agent Swarm has no Router to create tasks yet."), %{}}

  defp create_error(_unavailable),
    do:
      {:error, 503, "runtime_unavailable",
       gettext("Could not create the task. Salix is unavailable — retry shortly."), %{}}

  defp place_error(:cloud_vm_disabled),
    do:
      {:error, 422, "cloud_vm_disabled", gettext("The Cloud VM is turned off for this swarm."),
       %{}}

  defp place_error(:device_offline),
    do:
      {:error, 422, "station_offline",
       gettext("That station is not connected now. Choose another place."), %{}}

  defp place_error({reason, _info}) when reason in [:device_needs_station, :station_outdated],
    do: {:error, 422, Atom.to_string(reason), StationNotice.message(reason), %{}}

  defp place_error(_reason),
    do:
      {:error, 422, "invalid_place",
       gettext("Choose Salix, the Cloud VM or a station of this swarm."), %{}}

  @doc """
  The places and models the New task form offers. `places`: inside Salix
  (always), the swarm's Cloud VM while it is on, and each connected station
  that takes Tasks, each with the models it runs per coding agent (`models`)
  and whether it is the swarm's default place (`default`). `models`: the
  models a Task inside Salix can choose (the platform model and the org's
  offered models), after the swarm's default Task model (key "").
  """
  def targets(org, project, role) do
    if role in @task_roles do
      {:ok, %{"stations" => stations, "cloud_vm" => cloud_vm}} = Agents.list_stations(project)

      default =
        case Projects.default_task_place(project) do
          {:ok, %{} = place} -> place
          _salix_or_unknown -> %{"kind" => "salix"}
        end

      places =
        [%{"id" => "salix", "kind" => "salix", "label" => gettext("Salix"), "models" => %{}}] ++
          if(cloud_vm["enabled"],
            do: [
              %{
                "id" => "cloud_vm",
                "kind" => "cloud_vm",
                "label" => gettext("The Cloud VM"),
                "models" => cloud_vm["task_models"]
              }
            ],
            else: []
          ) ++
          for station <- stations,
              station["station"] == "ready" and station["status"] == "connected" do
            %{
              "id" => station["device_id"],
              "kind" => "station",
              "device_id" => station["device_id"],
              "label" => device_label(station),
              "models" => station["task_models"]
            }
          end

      {:ok,
       %{
         "places" => Enum.map(places, &Map.put(&1, "default", default?(&1, default))),
         "models" => salix_models(org, project)
       }}
    else
      forbidden(gettext("Only Agent Swarm members can create tasks."))
    end
  end

  defp default?(%{"kind" => "station", "device_id" => id}, %{"kind" => "station"} = default),
    do: default["device_id"] == id

  defp default?(%{"kind" => kind}, %{"kind" => kind}), do: kind != "station"
  defp default?(_place, _default), do: false

  defp device_label(station) do
    name = text(station["name"]) || station["device_id"]
    if name == station["device_id"], do: name, else: "#{name} / #{station["device_id"]}"
  end

  # The swarm's default Task model first (key "": the Task names no model),
  # then the platform model and the org's offered models.
  defp salix_models(org, project) do
    offered = offered(org)

    default_label =
      case Projects.default_task_model(project) do
        {:ok, nil} -> platform_label()
        {:ok, @platform_task_model} -> platform_label()
        {:ok, choice} -> Models.option(choice, offered)["label"]
        {:error, _reason} -> nil
      end

    default =
      %{
        "key" => "",
        "choice" => nil,
        "label" =>
          if(default_label,
            do: gettext("Swarm default (%{model})", model: default_label),
            else: gettext("Swarm default")
          )
      }

    platform = %{
      "key" => Models.key(@platform_task_model),
      "choice" => @platform_task_model,
      "label" => platform_label()
    }

    [default, platform] ++
      Enum.map(offered, &%{"key" => &1["key"], "choice" => &1["choice"], "label" => &1["label"]})
  end

  defp platform_label do
    case Models.platform_default("worker") do
      %{"label" => model} -> gettext("Platform model (%{model})", model: model)
      nil -> gettext("Platform model")
    end
  end

  defp offered(org) do
    case Models.allowed(org, Models.catalog()) do
      {:ok, options} -> options
      {:error, _reason} -> []
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
        request_id: SystemsRuntime.Proc.uuid(),
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
    do: [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: SystemsRuntime.Proc.uuid()
    ]

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

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
