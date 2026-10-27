defmodule BridgeForTeamsWeb.DashboardSwarmAgents do
  @moduledoc """
  Builds the Agent Swarm Agents page payloads and applies its writes for
  `DashboardAPIController`: the swarm's Router, one agent's detail (its model,
  prompt and, for the Router, its canonical session), the Router's model and
  prompt configuration and its session switch, and the stations a Task can
  run on (the place picker of swarm Settings).

  Workers are retired: the page lists the Router only. A Worker made before
  stays readable by its id as history; creating, configuring, moving or
  archiving one answers 410 `workers_retired`. Tasks run on the swarm's Task
  agent at the swarm's default place and model (swarm Settings).

  Every swarm member reads the list and the detail; the model catalog, the
  target picker and every write are for swarm admins. A refused write records
  a denied audit entry, as the LiveView pages did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Agents, Memberships, Models}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Agent
  alias BridgeForTeamsWeb.Dashboard.CoreComponents
  alias BridgeForTeamsWeb.StationNotice

  # ---- Reads ----

  @doc """
  The swarm's agents: its Router. `status: "unavailable"` when Salix cannot
  name it.
  """
  def page(org, project, role, _params) do
    case Agents.current_router(project) do
      {:ok, router} ->
        {:ok,
         %{
           "project" => public_project(project, role),
           "status" => "ok",
           "agents" => [summary(router)],
           "next_cursor" => nil,
           "triage_href" => triage_href(org)
         }}

      {:error, _reason} ->
        {:ok,
         %{
           "project" => public_project(project, role),
           "status" => "unavailable",
           "agents" => [],
           "next_cursor" => nil,
           "triage_href" => nil
         }}
    end
  end

  @doc """
  One agent: the list facts plus its model, prompt and, for a Router, its
  canonical session. A Worker made before Workers were retired reads as
  history (`read_only`).
  """
  def show(org, project, role, agent_id) do
    with {:ok, agent} <- project_agent(project, agent_id) do
      {:ok,
       %{
         "project" => public_project(project, role),
         "agent" =>
           agent
           |> summary()
           |> Map.merge(%{
             "created_at" => agent.created_at,
             "runtime_id" => agent.salix_agent_id,
             "model" => model(agent, org),
             "system_prompt" => Agent.instructions(agent),
             "read_only" => agent.role != "router"
           }),
         "router_session" => router_session(project, agent),
         "triage_href" => if(agent.role == "router", do: triage_href(org))
       }}
    end
  end

  @doc """
  The Configure form: the model choices this org's admins can give (the
  allowed list, or the catalog when the list is empty), the platform model the
  agent follows when it has no choice (key `""`), and a current choice the org
  no longer offers, kept visible but not selectable. The Router's instructions
  show to every swarm admin; only an org owner may change them
  (`prompt_editable`).
  """
  def config(org, user, project, role, agent_id) do
    with :ok <- admin(role),
         {:ok, agent} <- project_agent(project, agent_id),
         :ok <- router_only(agent) do
      offered = org_models(org)
      current = current_model(agent)

      {:ok,
       %{
         "agent" => %{"id" => agent.id, "name" => agent.salix["name"], "role" => agent.role},
         "system_prompt" => Agent.instructions(agent) || "",
         "prompt_editable" => org_owner?(org, user),
         "model_key" => if(current, do: Models.key(current), else: ""),
         "available" => offered != [],
         "models" => model_options(agent, offered, current)
       }}
    end
  end

  @doc """
  The stations a Task can run on, for the place picker of swarm Settings: the
  swarm's devices (a device whose Comma station takes no Tasks is listed but
  not selectable) and its Cloud VM, each with the models its station runs per
  runtime.
  """
  def targets(project, role) do
    with :ok <- admin(role) do
      {:ok, %{"stations" => stations, "cloud_vm" => cloud_vm}} = Agents.list_stations(project)

      {:ok,
       %{
         "stations" =>
           for station <- stations do
             %{
               "id" => station["device_id"],
               "label" => device_label(station),
               "connected" => station["status"] == "connected",
               "selectable" => station["station"] == "ready",
               "issue" => station_issue(station["station"]),
               "models" => station["task_models"]
             }
           end,
         "cloud_vm" => %{
           "selectable" => cloud_vm["enabled"],
           "issue" =>
             if(!cloud_vm["enabled"], do: gettext("The Cloud VM is turned off for this swarm.")),
           "models" => cloud_vm["task_models"]
         }
       }}
    end
  end

  defp station_issue("ready"), do: nil
  defp station_issue(reason), do: StationNotice.message(reason)

  # ---- Writes ----

  @doc "Workers are retired: a new one is refused with 410."
  def create(_org, user, project, role, _params) do
    with :ok <- authorize(role, project, user, "agent.created") do
      _ =
        Agents.record_agent_write_attempt(
          project,
          "agent.created",
          "failed",
          :workers_retired,
          audit_opts(user)
        )

      workers_retired()
    end
  end

  @doc """
  Save the model and the Router's instructions. A missing `model` keeps the
  model; any other value must be `null` (follow the platform model of the
  role) or a model choice the org offers now. `system_prompt` is saved as the
  Router's own `router_system_prompt`; a prompt equal to the current
  instructions is no change, and only an org owner may change them.
  """
  def configure(org, user, project, role, agent_id, params) do
    with :ok <- authorize(role, project, user, "agent.config_updated"),
         {:ok, agent} <- project_agent(project, agent_id),
         :ok <- router_only(agent),
         {:ok, attrs} <- model_config_attrs(org, agent, params),
         :ok <- prompt_owner(org, user, project, attrs) do
      case Agents.update_agent(agent, attrs, audit_opts(user)) do
        {:ok, _updated} ->
          notice(show(org, project, role, agent.id), gettext("Agent configuration saved."))

        {:error, %Ecto.Changeset{} = changeset} ->
          invalid(changeset, gettext("Could not save the configuration."))

        {:error, _reason} ->
          write_failed(gettext("Could not save the configuration."))
      end
    end
  end

  # Without its own instructions the Router runs with the shared
  # `system_prompt`, so clearing them while that one is set would only bring
  # it back.
  defp prompt_attrs(agent, params) do
    current = Agent.instructions(agent) || ""

    case params["system_prompt"] do
      prompt when not is_binary(prompt) or prompt == current ->
        {:ok, %{}}

      prompt ->
        if String.trim(prompt) == "" and agent.salix["system_prompt"] not in [nil, ""] do
          message = gettext("An existing system prompt cannot be cleared.")
          {:error, 422, "invalid_agent", message, %{"fields" => %{"system_prompt" => [message]}}}
        else
          {:ok, %{"router_system_prompt" => prompt}}
        end
    end
  end

  defp prompt_owner(org, user, project, attrs) do
    if Map.has_key?(attrs, "router_system_prompt") and not org_owner?(org, user) do
      _ =
        Agents.record_agent_write_attempt(
          project,
          "agent.config_updated",
          "denied",
          :forbidden,
          audit_opts(user)
        )

      {:error, 403, "forbidden",
       gettext("Only organization owners can change the system prompt."), %{}}
    else
      :ok
    end
  end

  defp org_owner?(org, user), do: Memberships.org_role(org.id, user.id) == {:ok, "owner"}

  defp model_config_attrs(org, agent, params) do
    with {:ok, attrs} <- prompt_attrs(agent, params) do
      model_attrs(org, attrs, params)
    end
  end

  defp model_attrs(org, attrs, params) do
    case Map.fetch(params, "model") do
      :error ->
        {:ok, attrs}

      {:ok, nil} ->
        {:ok, Map.put(attrs, "model", nil)}

      {:ok, choice} when is_map(choice) ->
        if Models.allowed?(org, choice, Models.catalog()),
          do: {:ok, Map.put(attrs, "model", choice)},
          else: invalid_model()

      {:ok, _other} ->
        invalid_model()
    end
  end

  defp invalid_model,
    do:
      {:error, 422, "invalid_model", gettext("Choose a model from the list before saving."), %{}}

  @doc "Workers are retired: moving one to another station answers 410."
  def rebind(_org, user, project, role, _agent_id, _params) do
    with :ok <- authorize(role, project, user, "agent.runtime_rebound"),
         do: workers_retired()
  end

  @doc "Workers are retired and stay as history: archiving one answers 410."
  def archive(_org, user, project, role, _agent_id, _params) do
    with :ok <- authorize(role, project, user, "agent.archived"),
         do: workers_retired()
  end

  @doc "Start a fresh canonical session for a Router, stopping the current one."
  def switch_router_session(_org, user, project, role, agent_id, params) do
    with :ok <-
           authorize(
             role,
             project,
             user,
             "agent.router_session_switched",
             gettext("Only Agent Swarm admins can switch the Router session.")
           ),
         {:ok, agent} <- project_agent(project, agent_id),
         true <-
           agent.role == "router" ||
             {:error, 422, "not_router", gettext("Only Router agents have a canonical session."),
              %{}},
         expected when is_binary(expected) <-
           text(params["expected_session_id"]) ||
             {:error, 422, "session_required",
              gettext("Refresh before switching the Router session."), %{}} do
      case Agents.switch_router_session(project, agent, expected, audit_opts(user)) do
        {:ok, %{"router_session_id" => session_id}} ->
          {:ok,
           %{
             "router_session_id" => session_id,
             "notice" => gettext("Started a new canonical Router session.")
           }}

        {:error, {:stale_router_session, current}} ->
          {:error, 409, "stale_router_session",
           gettext(
             "The Router session was already switched. The current session is shown below."
           ), %{"router_session_id" => current}}

        {:error, _reason} ->
          write_failed(gettext("Could not switch the canonical Router session."))
      end
    end
  end

  # ---- Agent facts ----

  @doc "The list facts of one agent; the Overview's Agents panel shows the same."
  def summary(%Agent{} = agent) do
    %{
      "id" => agent.id,
      "name" => agent.salix["name"],
      "role" => agent.role,
      "lifecycle" => Agent.lifecycle(agent)
    }
  end

  defp router_only(%Agent{role: "router"}), do: :ok
  defp router_only(_worker), do: workers_retired()

  defp workers_retired,
    do:
      {:error, 410, "workers_retired",
       gettext(
         "Workers are retired. Tasks run at this Agent Swarm's default place and model; set them in Settings."
       ), %{}}

  defp project_agent(project, agent_id) do
    case Agents.get_agent(to_string(agent_id)) do
      {:ok, %Agent{project_id: project_id} = agent} when project_id == project.id -> {:ok, agent}
      _other -> {:error, 404, "agent_not_found", gettext("Agent not found."), %{}}
    end
  end

  # The Slack triage Overview.
  defp triage_href(org), do: "/orgs/#{org.slug}/triage"

  defp router_session(_project, %Agent{role: role}) when role != "router", do: nil

  defp router_session(project, agent) do
    case Agents.get_salix_agent(project, agent) do
      {:ok, %{"router_session_id" => id}} when is_binary(id) -> %{"status" => "ok", "id" => id}
      _missing -> %{"status" => "unavailable", "id" => nil}
    end
  end

  # The model name: of the Agent's choice, or of the platform model that its
  # role follows. An older agent shows its recorded model. nil when Salix
  # cannot say.

  defp model(%Agent{} = agent, org) do
    case {current_model(agent), agent.salix["llm_config"]} do
      {nil, %{"model" => model}} when is_binary(model) and model != "" ->
        model

      {nil, _llm_config} ->
        case Models.platform_default(agent.role) do
          %{"label" => label} -> label
          nil -> nil
        end

      {choice, _llm_config} ->
        case Client.impl().public_model(choice, org.salix_tenant_id) do
          {:ok, public} when is_map(public) -> Models.public_label(public)
          _error -> Models.label(choice)
        end
    end
  end

  defp current_model(%Agent{salix: %{"model" => %{} = choice}}) when map_size(choice) > 0,
    do: Models.normalize(choice)

  defp current_model(_agent), do: nil

  # ---- Models ----

  defp org_models(org) do
    case Models.allowed(org, Models.catalog()) do
      {:ok, options} -> options
      {:error, _reason} -> []
    end
  end

  # The picker: the platform model first, then a current choice the org no
  # longer offers (disabled), then the offered choices grouped by vendor.
  defp model_options(agent, offered, current) do
    unavailable =
      if is_nil(current) or Enum.any?(offered, &(&1["choice"] == current)) do
        []
      else
        option = Models.option(current, [])

        [
          option_row(option, true,
            label:
              gettext("%{model} (current; unavailable for selection)", model: option["label"])
          )
        ]
      end

    [
      %{
        "key" => "",
        "choice" => nil,
        "label" => follow_default(agent),
        "disabled" => false,
        "group" => gettext("Platform")
      }
      | unavailable ++ Enum.map(offered, &option_row(&1, false, []))
    ]
  end

  defp option_row(option, disabled, opts) do
    %{
      "key" => option["key"],
      "choice" => option["choice"],
      "label" => Keyword.get(opts, :label, option["label"]),
      "disabled" => disabled,
      "group" => vendor_group(option["vendor"])
    }
  end

  defp vendor_group(vendor), do: Models.vendor_label(vendor) || gettext("Other")

  defp follow_default(agent) do
    case Models.platform_default(agent.role) do
      nil -> gettext("Default (unavailable)")
      %{"label" => label} -> gettext("Default (%{model})", model: label)
    end
  end

  # ---- Station targets ----

  defp device_label(env) do
    name = text(env["name"]) || env["device_id"]
    if name == env["device_id"], do: name, else: "#{name} / #{env["device_id"]}"
  end

  # ---- Authorization and envelopes ----

  defp admin("admin"), do: :ok

  defp admin(_role),
    do: {:error, 403, "forbidden", gettext("Only Agent Swarm admins can manage agents."), %{}}

  defp authorize(role, project, user, action, message \\ nil)
  defp authorize("admin", _project, _user, _action, _message), do: :ok

  defp authorize(_role, project, user, action, message) do
    _ = Agents.record_agent_write_attempt(project, action, "denied", :forbidden, audit_opts(user))

    {:error, 403, "forbidden", message || gettext("Only Agent Swarm admins can manage agents."),
     %{}}
  end

  defp notice({:ok, data}, notice), do: {:ok, Map.put(data, "notice", notice)}
  defp notice(error, _notice), do: error

  defp invalid(changeset, message) do
    {:error, 422, "invalid_agent", message,
     %{"fields" => Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)}}
  end

  defp write_failed(message), do: {:error, 503, "write_failed", message, %{}}

  defp public_project(project, role),
    do: %{"id" => project.id, "name" => project.name, "role" => role}

  defp audit_opts(user),
    do: [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: SystemsRuntime.Proc.uuid()
    ]

  defp actor_label(user), do: text(user.email) || text(user.name) || user.id

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
