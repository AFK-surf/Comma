defmodule BridgeForTeamsWeb.DashboardSwarmAgents do
  @moduledoc """
  Builds the Agent Swarm Agents page payloads and applies its writes for
  `DashboardAPIController`: the paged agent list, one agent's detail (its
  model, binding, Triage use and canonical Router session), new internal and
  external agents, model and prompt configuration, runtime rebind, archive and
  the Router session switch.

  The list reads one Salix page of 100 agents; `next_cursor` continues it. Each
  page also reads the group's Router and the Triage assignment once, so a page
  costs the same however many agents it holds. When Salix is down, the first
  page answers `status: "unavailable"`; a later page answers 503 so the browser
  keeps its cursor, and a stale cursor answers 422.

  External agents run on a Connected Device (from the device projection) or a
  Compute Workload (one Salix page of 50, with the selection fence the write
  sends back). Core validates the chosen target again before it binds.

  Every swarm member reads the list and the detail; the model catalog, the
  target pickers and every write are for swarm admins. A refused write records
  a denied audit entry, as the LiveView pages did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Agents, Environments, Models}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Agent
  alias BridgeForTeamsWeb.Dashboard.CoreComponents
  alias SalixStore.RuntimeIds

  @agent_page 100
  @workload_page 50
  @workload_providers ~w(codex pi claude)

  # ---- Reads ----

  @doc "One page of agents with their role badges; `cursor` continues the list."
  def page(org, project, role, params) do
    cursor = text(params["cursor"])

    case Agents.page_agents(project, limit: @agent_page, cursor: cursor) do
      {:ok, page} ->
        router = router(project)
        triage = triage_binding(project)

        {:ok,
         %{
           "project" => public_project(project, role),
           "status" => "ok",
           "agents" => Enum.map(page.items, &row(&1, router, triage)),
           "next_cursor" => page.next_cursor,
           "triage_href" => triage_href(org, router)
         }}

      {:error, :invalid_cursor} ->
        {:error, 422, "invalid_cursor", gettext("This page of agents is no longer available."),
         %{}}

      # A later page that fails is not the end of the list.
      {:error, _reason} when is_binary(cursor) ->
        {:error, 503, "runtime_unavailable",
         gettext("Could not load more agents. Salix is unavailable — retry shortly."), %{}}

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
  One agent: the row facts plus its model, prompt, binding, Triage use (read
  fresh, for the archive confirmation) and, for a Router, its canonical session.
  """
  def show(org, project, role, agent_id) do
    with {:ok, agent} <- project_agent(project, agent_id) do
      router = router(project)
      triage = triage_binding(project)
      config = agent.salix["runtime_config"]

      {:ok,
       %{
         "project" => public_project(project, role),
         "agent" =>
           agent
           |> row(router, triage)
           |> Map.merge(%{
             "created_at" => agent.created_at,
             "runtime_id" => agent.salix_agent_id,
             "model" => model(agent, org),
             "system_prompt" => text(agent.salix["system_prompt"]),
             "binding" => if(rebindable?(agent), do: public_binding(config))
           }),
         "triage" => triage_status(triage, agent),
         "router_session" => router_session(project, agent),
         "triage_href" => triage_href(org, router)
       }}
    end
  end

  @doc """
  The Configure form: the models this org's admins may assign (catalog ∩
  allowlist), the role default the agent follows when nothing is pinned, and a
  pinned model the org no longer offers, kept visible but not selectable.
  """
  def config(org, project, role, agent_id) do
    with :ok <- admin(role),
         {:ok, agent} <- project_agent(project, agent_id) do
      templates = org_templates(org)
      current = agent.salix["template_id"] || ""

      {:ok,
       %{
         "agent" => %{"id" => agent.id, "name" => agent.salix["name"], "role" => agent.role},
         "template_id" => current,
         "system_prompt" => agent.salix["system_prompt"] || "",
         "available" => templates != [],
         "models" => model_options(org, agent, templates, current)
       }}
    end
  end

  @doc "Connected devices of the swarm and their external runtimes, for the picker."
  def targets(project, role) do
    with :ok <- admin(role) do
      {:ok, environments} = Environments.list_projected_environments(project.id)

      {:ok,
       %{
         "devices" =>
           for env <- environments, env["status"] == "connected", is_binary(env["device_id"]) do
             %{
               "id" => env["device_id"],
               "label" => device_label(env),
               "runtimes" => Enum.map(external_runtimes(env), &public_runtime/1)
             }
           end
       }}
    end
  end

  @doc """
  One page of 50 Compute Workloads for `provider`. Unavailable workloads are
  left out unless asked for. An outage answers `status: "unavailable"`.
  """
  def workloads(project, role, params) do
    with :ok <- admin(role) do
      provider =
        if params["provider"] in @workload_providers, do: params["provider"], else: "codex"

      show_unavailable? = params["include_unavailable"] in [true, "true"]

      opts =
        [
          limit: @workload_page,
          query: text(params["query"]) || "",
          include_unavailable: show_unavailable?
        ]
        |> put_opt(:cursor, text(params["cursor"]))

      {:ok,
       case Agents.page_external_worker_targets(project, provider, opts) do
         {:ok, page} ->
           page = stringify(page)

           %{
             "status" => "ok",
             "items" =>
               (page["items"] || [])
               |> Enum.filter(&(show_unavailable? or &1["selectable"] == true))
               |> Enum.map(&public_workload/1),
             "next_cursor" => page["next_cursor"]
           }

         {:error, _reason} ->
           %{"status" => "unavailable", "items" => [], "next_cursor" => nil}
       end}
    end
  end

  # ---- Writes ----

  @doc "Create an internal worker, or an external one bound to the chosen target."
  def create(_org, user, project, role, params) do
    with :ok <- authorize(role, project, user, "agent.created") do
      name = text(params["name"]) || ""

      result =
        if params["type"] == "external" do
          with {:ok, target} <- target(params["target"]) do
            attrs = if name == "", do: %{}, else: %{"name" => name}
            Agents.create_external_agent(project, attrs, target, audit_opts(user))
          end
        else
          Agents.create_agent(
            project.id,
            %{"name" => name, "role" => "worker"},
            audit_opts(user)
          )
        end

      case result do
        {:ok, agent} ->
          {:ok,
           %{
             "id" => agent.id,
             "notice" => gettext("Agent creation accepted. Refresh the list after provisioning.")
           }}

        {:error, 422, _code, _message, _details} = error ->
          error

        {:error, %Ecto.Changeset{} = changeset} ->
          invalid(changeset, gettext("Could not create the agent."))

        {:error, reason} ->
          if params["type"] == "external",
            do: target_error(reason, gettext("Could not create the agent.")),
            else: write_failed(gettext("Could not create the agent."))
      end
    end
  end

  @doc """
  Save the model and system prompt. A missing `template_id` keeps the model;
  any other value must be `""` (follow the role default) or a model the org
  offers now. An untouched empty prompt is not a request to clear it.
  """
  def configure(org, user, project, role, agent_id, params) do
    with :ok <- authorize(role, project, user, "agent.config_updated"),
         {:ok, agent} <- project_agent(project, agent_id),
         {:ok, attrs} <- config_attrs(org, agent, params) do
      case Agents.update_agent(agent, attrs, audit_opts(user)) do
        {:ok, _updated} ->
          notice(show(org, project, role, agent.id), gettext("Agent configuration saved."))

        {:error, %Ecto.Changeset{} = changeset} ->
          invalid(changeset, gettext("Could not save the configuration."))

        {:error, {:bad_request, "system_prompt cannot be cleared"}} ->
          message = gettext("An existing system prompt cannot be cleared.")

          {:error, 422, "invalid_agent", message, %{"fields" => %{"system_prompt" => [message]}}}

        {:error, _reason} ->
          write_failed(gettext("Could not save the configuration."))
      end
    end
  end

  defp config_attrs(org, agent, params) do
    attrs =
      params
      |> Map.take(["template_id", "system_prompt"])
      |> Map.filter(fn {_key, value} -> is_binary(value) end)

    attrs =
      if attrs["system_prompt"] == "" and agent.salix["system_prompt"] in [nil, ""],
        do: Map.delete(attrs, "system_prompt"),
        else: attrs

    case attrs do
      %{"template_id" => ""} ->
        {:ok, attrs}

      %{"template_id" => id} ->
        if Enum.any?(org_templates(org), &(&1["template_id"] == id)),
          do: {:ok, attrs},
          else:
            {:error, 422, "invalid_model", gettext("Choose a model from the list before saving."),
             %{}}

      _no_change ->
        {:ok, attrs}
    end
  end

  @doc """
  Bind an external worker's new sessions to another target. The write carries
  the binding revision it was shown, so a concurrent change is refused.
  """
  def rebind(org, user, project, role, agent_id, params) do
    with :ok <- authorize(role, project, user, "agent.runtime_rebound"),
         {:ok, agent} <- project_agent(project, agent_id),
         true <-
           rebindable?(agent) ||
             target_error(:unsupported_runtime_binding, gettext("Could not rebind the runtime.")),
         {:ok, expected} <- binding_revision(params["expected_binding_revision"]),
         {:ok, target} <- target(params["target"]) do
      case Agents.rebind_external_target(project, agent, target, expected, audit_opts(user)) do
        {:ok, _agent} ->
          notice(show(org, project, role, agent.id), gettext("Agent runtime rebound."))

        {:error, %Ecto.Changeset{} = changeset} ->
          invalid(changeset, gettext("Could not rebind the runtime."))

        {:error, reason} ->
          target_error(reason, gettext("Could not rebind the runtime."))
      end
    end
  end

  @doc """
  Archive a worker. Archiving the Triage Worker needs the Triage revision the
  confirmation showed; a changed assignment is refused so it can be reviewed.
  """
  def archive(org, user, project, role, agent_id, params) do
    with :ok <- authorize(role, project, user, "agent.archived"),
         {:ok, agent} <- project_agent(project, agent_id) do
      opts =
        case params["triage_revision"] do
          revision when is_integer(revision) ->
            Keyword.put(audit_opts(user), :triage_worker_revision, revision)

          _none ->
            audit_opts(user)
        end

      case Agents.archive_agent(agent, opts) do
        {:ok, _archived} ->
          {:ok,
           %{
             "redirect" => "/orgs/#{org.slug}/projects/#{project.id}/agents",
             "notice" => gettext("Agent archived.")
           }}

        {:error, :triage_worker_confirmation_required} ->
          {:error, 409, "triage_confirmation_required",
           gettext(
             "This Worker is now assigned to Triage. Open Archive again to review the impact."
           ), %{}}

        {:error, :router_agent} ->
          {:error, 422, "router_agent", gettext("Router agents cannot be archived."), %{}}

        {:error, _reason} ->
          write_failed(gettext("Could not archive the agent."))
      end
    end
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
      "lifecycle" => Agent.lifecycle(agent),
      "runtime" => runtime_source(agent.salix["runtime_config"])
    }
  end

  defp row(agent, router, triage) do
    Map.merge(summary(agent), %{
      "triage" => triage_worker?(triage, agent),
      "group_router" =>
        match?(%Agent{}, router) and router.salix_agent_id == agent.salix_agent_id,
      "rebindable" => rebindable?(agent)
    })
  end

  defp runtime_source(%{"kind" => "compute_workload"}), do: "compute"

  defp runtime_source(%{"kind" => kind}) when kind in ~w(external connected_runtime),
    do: "connected"

  defp runtime_source(_config), do: "internal"

  # Only an existing external worker moves to another target.
  defp rebindable?(%Agent{role: "worker", salix: record}),
    do: runtime_source(record["runtime_config"]) != "internal"

  defp rebindable?(_agent), do: false

  defp project_agent(project, agent_id) do
    case Agents.get_agent(to_string(agent_id)) do
      {:ok, %Agent{project_id: project_id} = agent} when project_id == project.id -> {:ok, agent}
      _other -> {:error, 404, "agent_not_found", gettext("Agent not found."), %{}}
    end
  end

  # The group's Router, for the badge and the Triage link. Unknown when Salix
  # cannot say.
  defp router(project) do
    case Agents.current_router(project) do
      {:ok, router} -> router
      _unknown -> nil
    end
  end

  defp triage_binding(project) do
    case Agents.triage_worker_binding(project) do
      {:ok, binding} -> binding
      _unavailable -> :unavailable
    end
  end

  defp triage_worker?(%{"worker_agent_id" => id}, agent) when is_binary(id),
    do: id == agent.salix_agent_id

  defp triage_worker?(_binding, _agent), do: false

  defp triage_status(:unavailable, _agent),
    do: %{"status" => "unavailable", "used" => false, "revision" => nil}

  defp triage_status(binding, agent) do
    used = triage_worker?(binding, agent)
    %{"status" => "ok", "used" => used, "revision" => if(used, do: binding["revision"])}
  end

  # The Worker for Triage section of the Slack triage Overview.
  defp triage_href(org, %Agent{id: id}),
    do: "/orgs/#{org.slug}/triage?agent=#{id}#triage-worker-configuration"

  defp triage_href(_org, nil), do: nil

  defp router_session(_project, %Agent{role: role}) when role != "router", do: nil

  defp router_session(project, agent) do
    case Agents.get_salix_agent(project, agent) do
      {:ok, %{"router_session_id" => id}} when is_binary(id) -> %{"status" => "ok", "id" => id}
      _missing -> %{"status" => "unavailable", "id" => nil}
    end
  end

  # A pinned model resolves live from the catalog (its template id when Salix
  # cannot say); an older agent shows its recorded model.
  defp model(%Agent{salix: %{"template_id" => id}}, org) when is_binary(id) and id != "" do
    case Client.impl().get_template(id, org.salix_tenant_id) do
      {:ok, template} when is_map(template) -> template["model"] || id
      _error -> id
    end
  end

  defp model(%Agent{salix: %{"llm_config" => %{"model" => model}}}, _org)
       when is_binary(model) and model != "",
       do: model

  defp model(_agent, _org), do: nil

  defp public_binding(config) do
    config = stringify(config || %{})
    compute? = config["kind"] == "compute_workload"

    %{
      "summary" => binding_summary(config),
      "revision" => config["binding_revision"] || 0,
      "location" => if(compute?, do: "compute", else: "connected"),
      "device_id" => config["device_id"],
      "device_runtime_id" => config["device_runtime_id"],
      "provider" => get_in(config, ["runtime_spec", "provider"]) || "codex",
      "workload_id" => config["workload_id"]
    }
  end

  defp binding_summary(%{"kind" => "compute_workload"} = config) do
    provider = get_in(config, ["runtime_spec", "provider"]) || "—"
    "#{String.capitalize(provider)} · #{short_id(config["workload_id"])}"
  end

  defp binding_summary(config) do
    provider = config["provider"] || "—"
    "#{String.capitalize(provider)} · #{short_id(config["device_runtime_id"])}"
  end

  defp short_id(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp short_id(_value), do: "—"

  # ---- Models ----

  defp org_templates(org) do
    case Models.list_for_org(org) do
      {:ok, templates} -> templates
      {:error, _reason} -> []
    end
  end

  # The LiveView picker: the role default first, a pinned model the org no
  # longer offers next (disabled), then the platform-billed models; private
  # and subscription models form their own BYOK group.
  defp model_options(org, agent, templates, current) do
    by_id = Map.new(templates, &{&1["template_id"], &1})
    platform = gettext("Platform billing")

    offered =
      for option <- Models.options(templates, current) do
        {label, id} =
          if is_list(option),
            do: {option[:key], option[:value]},
            else: option

        %{
          "id" => id,
          "label" => label,
          "disabled" => false,
          "group" => if(byok?(by_id[id]), do: "BYOK", else: platform)
        }
      end

    unavailable =
      if current == "" or Map.has_key?(by_id, current) do
        []
      else
        template =
          case Client.impl().get_template(current, org.salix_tenant_id) do
            {:ok, template} when is_map(template) -> template
            _error -> %{"template_id" => current}
          end

        [
          %{
            "id" => current,
            "label" =>
              gettext("%{model} (current; unavailable for selection)",
                model: Models.label(template)
              ),
            "disabled" => true,
            "group" => platform
          }
        ]
      end

    {byok, platform_options} = Enum.split_with(unavailable ++ offered, &(&1["group"] == "BYOK"))

    [
      %{
        "id" => "",
        "label" => follow_default(agent),
        "disabled" => false,
        "group" => platform
      }
      | platform_options
    ] ++ byok
  end

  defp byok?(nil), do: false

  defp byok?(template) do
    template["scope"] == "tenant" or not is_nil(template["tenant_id"]) or
      template["account_pool"] in ["codex", "claude"] or
      get_in(template, ["provider_config", "account_pool"]) in ["codex", "claude"]
  end

  defp follow_default(agent) do
    case Models.platform_defaults()[agent.role] do
      nil -> gettext("Default (unavailable)")
      template -> gettext("Default (%{model})", model: Models.label(template))
    end
  end

  # ---- External targets ----

  defp external_runtimes(env) do
    for runtime <- env["device_runtimes"] || [],
        is_map(runtime),
        runtime <- [stringify(runtime)],
        RuntimeIds.external_runtime_provider?(runtime["provider"]),
        text(runtime["device_runtime_id"]),
        do: runtime
  end

  defp device_label(env) do
    name = text(env["name"]) || env["device_id"]
    if name == env["device_id"], do: name, else: "#{name} / #{env["device_id"]}"
  end

  defp public_runtime(runtime) do
    status = text(runtime["status"])

    %{
      "id" => runtime["device_runtime_id"],
      "label" =>
        [runtime["provider"], runtime["device_runtime_id"], runtime["version"]]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" / "),
      "ready" => status == "ready",
      "status" => status || "not ready",
      "version" => text(runtime["version"]),
      "checked_at" => iso_timestamp(runtime["readiness_checked_at"]),
      "issue" => text(runtime["issue"])
    }
  end

  defp public_workload(item) do
    %{
      "id" => item["workload_id"],
      "label" => item["label"],
      "node" => get_in(item, ["node", "label"]),
      "selectable" => item["selectable"] == true,
      "availability" => availability_label(item),
      "tone" => availability_tone(item),
      "issue" =>
        if(is_map(item["reconcile_error"]), do: reconcile_error(item["reconcile_error"])),
      "selection_fence" => item["selection_fence"]
    }
  end

  defp availability_label(%{"selectable" => false, "reason" => reason}), do: reason_label(reason)

  defp availability_label(%{"availability" => "sleeping"}),
    do: gettext("Sleeping · starts when work arrives")

  defp availability_label(%{"availability" => "queued"}), do: gettext("Waiting for Host capacity")
  defp availability_label(%{"availability" => "starting"}), do: gettext("Starting")

  defp availability_label(%{"availability" => "action_required"} = item),
    do: reason_label(item["availability_issue"])

  defp availability_label(_item), do: gettext("Ready to select")

  defp availability_tone(%{"selectable" => false}), do: "warn"
  defp availability_tone(%{"availability" => "ready"}), do: "ok"
  defp availability_tone(%{"availability" => "sleeping"}), do: "neutral"
  defp availability_tone(_item), do: "warn"

  defp reason_label("provider_unsupported"), do: gettext("Provider unsupported")
  defp reason_label("registration_unavailable"), do: gettext("Node unavailable")
  defp reason_label("binding_unavailable"), do: gettext("Provider binding unavailable")
  defp reason_label("environment_not_ready"), do: gettext("Environment not ready")
  defp reason_label("allocation_not_ready"), do: gettext("Allocation not ready")
  defp reason_label("workload_not_ready"), do: gettext("Workload not ready")
  defp reason_label("runtime_missing"), do: gettext("Runtime missing")
  defp reason_label("runtime_generation_mismatch"), do: gettext("Runtime is outdated")
  defp reason_label("runtime_not_connected"), do: gettext("Runtime not connected")

  defp reason_label("runtime_recovery_expired"),
    do: gettext("Runtime recovery needs operator attention")

  defp reason_label("runtime_not_ready"), do: gettext("Runtime not ready")
  defp reason_label("runtime_catching_up"), do: gettext("Runtime catching up")
  defp reason_label("resource_capacity_exhausted"), do: gettext("Host capacity needs attention")
  defp reason_label("scope_mismatch"), do: gettext("Outside this Agent Swarm")
  defp reason_label(_reason), do: gettext("Unavailable")

  defp reconcile_error(error) do
    ["code", "stage", "resource", "message", "available_bytes", "required_bytes"]
    |> Enum.flat_map(fn key ->
      case Map.fetch(error, key) do
        {:ok, value} -> ["#{key}=#{value}"]
        :error -> []
      end
    end)
    |> Enum.join(" / ")
  end

  # The browser names the target; core validates it again before binding.
  defp target(%{"kind" => "compute_workload"} = target) do
    if text(target["workload_id"]) && is_map(target["selection_fence"]),
      do:
        {:ok,
         %{
           "kind" => "compute_workload",
           "workload_id" => text(target["workload_id"]),
           "selection_fence" => target["selection_fence"]
         }},
      else: invalid_target(gettext("Select a Compute Workload."))
  end

  defp target(target) do
    target = if is_map(target), do: target, else: %{}

    cond do
      is_nil(text(target["device_id"])) ->
        invalid_target(gettext("Select a connected device."))

      is_nil(text(target["device_runtime_id"])) ->
        invalid_target(gettext("Select an external runtime."))

      true ->
        {:ok,
         %{
           "kind" => "connected_runtime",
           "device_id" => text(target["device_id"]),
           "device_runtime_id" => text(target["device_runtime_id"])
         }}
    end
  end

  defp invalid_target(message), do: {:error, 422, "invalid_target", message, %{}}

  defp binding_revision(revision) when is_integer(revision) and revision >= 0, do: {:ok, revision}

  defp binding_revision(revision) when is_binary(revision) do
    case Integer.parse(revision) do
      {value, ""} -> binding_revision(value)
      _invalid -> binding_revision(nil)
    end
  end

  defp binding_revision(_revision), do: target_error(:stale_binding_revision, "")

  # A rejected target says why, in the reader's language.
  defp target_error(reason, fallback) do
    {status, code, message} =
      case reason do
        reason when reason in [:runtime_unavailable, :runtime_not_ready] ->
          {422, "runtime_not_ready", gettext("Selected external runtime is not ready.")}

        reason when reason in [:runtime_not_found, :target_not_found, :not_found] ->
          {422, "runtime_not_found", gettext("Selected external runtime is no longer available.")}

        :runtime_ambiguous ->
          {422, "runtime_ambiguous",
           gettext("Selected external runtime is ambiguous. Select the device and runtime again.")}

        :unsupported_agent_role ->
          {422, "unsupported_agent_role",
           gettext("Only worker agents can be rebound to an external runtime.")}

        :unsupported_runtime_binding ->
          {422, "unsupported_runtime_binding",
           gettext("Only existing external workers can be rebound.")}

        reason when reason in [:stale_binding_revision, :binding_conflict] ->
          {409, "stale_binding", gettext("The binding changed. Reopen the form and try again.")}

        :selection_changed ->
          {409, "selection_changed",
           gettext("The selected Workload changed. Refresh the list and select it again.")}

        {:target_unavailable, detail} ->
          {409, "target_unavailable",
           gettext("The selected Workload is not ready: %{reason}.",
             reason: reason_label(if(is_atom(detail), do: to_string(detail), else: detail))
           )}

        # Caller input core refuses; the form checks most of it first.
        :runtime_required ->
          {422, "runtime_required", gettext("Select an external runtime.")}

        reason when reason in [:target_required, :invalid_query] ->
          {422, "target_required", gettext("Select a Compute Workload.")}

        :provider_mismatch ->
          {422, "provider_mismatch",
           gettext(
             "The selected Workload runs a different provider. Refresh the list and select it again."
           )}

        :provider_unsupported ->
          {422, "provider_unsupported",
           gettext("The selected Workload's provider is not supported.")}

        reason when reason in [:not_provisioned, :agent_provisioning] ->
          {409, "agent_provisioning",
           gettext("The agent is still being set up. Try again when it is ready.")}

        :agent_not_in_project ->
          {404, "agent_not_found", gettext("Agent not found.")}

        _other ->
          {503, "write_failed", fallback}
      end

    {:error, status, code, message, %{}}
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
    do: [actor_user_id: user.id, actor_label: actor_label(user), request_id: Ecto.UUID.generate()]

  defp actor_label(user), do: text(user.email) || text(user.name) || user.id

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp stringify(%_{} = value), do: value

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  # Devices report readiness checks in unix milliseconds.
  defp iso_timestamp(value) when is_integer(value) do
    unit = if value > 99_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _invalid -> nil
    end
  end

  defp iso_timestamp(_value), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
