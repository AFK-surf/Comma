defmodule SalixIM.TaskPlacement do
  @moduledoc """
  Where a new Task runs and which model its Worker Session uses. A Router's
  `task.create` and a product that creates a Task for its Group (the
  BridgeForTeams dashboard, `create_task_conversation/3`) make the same checks.

  A Task names a place (`runs_on`) and a model (`model`), or leaves them out:

    * A Worker bound to a station (`station_binding`) runs each Task there.
    * An explicit place, Worker binding or configured Group default takes
      precedence. Without them, a runtime-model Task chooses an authorized
      VMM Station, the requesting user's physical Station, then Cloudflare.
      A Task with an internal model stays inside Salix.
    * A place is checked by the product (`SalixIM.Ports.TaskCreate.runs_on/2`):
      the Cloud VM switch on (the VM itself need not be running: a Task made
      while it sleeps is kept for it and the VM woken), a station connected
      and ready.
    * A coding Task (`runs_on {"kind": "sandbox"}`) runs on a sandbox made for
      it, with the GitHub repository `repo` (`{owner, name, base_ref?,
      branch?}`, or `{owner, name, pull_request}` to continue an open pull
      request on its own head branch) checked out. The product checks the repository and the
      Group's sandbox limit. It is never a Group's default place.
    * A Mini App build (`mini_app {"app_id": ...}`) is a coding Task on the
      app's own repository: only with `runs_on {"kind": "sandbox"}` and a
      `repo` that is the app's (`SalixIM.MiniApps.repo/2`).
    * A Loop Task runs inside Salix: the Group's default place does not apply
      to it, and a station or the Cloud VM, named or bound, or a model of kind
      runtime refuses it.
    * With no model, a Task inside Salix runs the Group's default Task model
      (`SalixIM.TaskConversationInput`) and a station its own default model.

  A refusal is a structured reason (`t:refusal/0`); `message/1` answers the text
  a Router reads.
  """

  require Logger

  alias SalixIM.GroupDirectory
  alias SalixIM.Ports.TaskCreate

  @typedoc """
  Why a place or model was refused. `source` says where the place came from:
  `:requested` (named), `:binding` (the Worker's station binding), `:default`
  (the Group's default place), `:automatic` (runtime machine selection), or `:salix`.
  """
  @type refusal ::
          {:runs_on, term(), atom()}
          | {:model, term()}
          | {:bound_runs_on, map()}
          | {:bound_model, String.t()}
          | {:group, term()}
          | {:agent, term()}

  @type placement :: %{
          params: map(),
          runs_on: map() | nil,
          repo: map() | nil,
          mini_app: map() | nil,
          session_model: map() | nil,
          source: :requested | :binding | :default | :automatic | :salix
        }

  @doc """
  Check the place and model `params` name (`"runs_on"`, `"model"`) for a Task of
  Worker `target_agent_id`. `scope` carries `tenant_id` and `group_id`; `loop?`
  is true for a Loop Task. Answers the place the Task runs (nil inside Salix),
  the model its Session stores (nil for the default), where the place came
  from, and `params` with the place and model a station binding gave.
  """
  @spec resolve(map(), String.t(), map(), boolean()) :: {:ok, placement()} | {:error, refusal()}
  def resolve(scope, target_agent_id, params, loop?) when is_map(params) do
    with :ok <- repo_place(params),
         {:ok, mini_app} <- mini_app_place(scope, params) do
      case pinned_placement(scope, params, loop?) do
        {:ok, placement} -> {:ok, Map.put(placement, :mini_app, mini_app)}
        :none -> resolve_new(scope, target_agent_id, params, loop?, mini_app)
        {:error, _} = error -> error
      end
    end
  end

  defp repo_place(params) do
    if is_nil(params["repo"]) or match?(%{"kind" => "sandbox"}, params["runs_on"]),
      do: :ok,
      else: {:error, {:runs_on, :repo_requires_sandbox, :requested}}
  end

  # A Mini App build runs on a sandbox with the app's repository checked out
  # (owner and name compare case-insensitively, as GitHub's do). Checked
  # before the sandbox place, so a refused build reserves nothing.
  defp mini_app_place(_scope, params) when not is_map_key(params, "mini_app"), do: {:ok, nil}
  defp mini_app_place(_scope, %{"mini_app" => nil}), do: {:ok, nil}

  defp mini_app_place(scope, %{"mini_app" => mini_app} = params) do
    cond do
      not match?(%{"kind" => "sandbox"}, params["runs_on"]) ->
        {:error, {:runs_on, :mini_app_requires_sandbox, :requested}}

      not (match?(%{"app_id" => id} when is_binary(id) and id != "", mini_app) and
               map_size(mini_app) == 1) ->
        {:error, {:runs_on, :mini_app_not_found, :requested}}

      true ->
        case SalixIM.MiniApps.repo(scope.group_id, mini_app["app_id"]) do
          {:ok, %{"owner" => owner, "name" => name}} ->
            if same_repo?(params["repo"], owner, name),
              do: {:ok, %{"app_id" => mini_app["app_id"]}},
              else: {:error, {:runs_on, :mini_app_repo_mismatch, :requested}}

          {:error, :mini_apps_unavailable} ->
            {:error, {:runs_on, :mini_apps_unavailable, :requested}}

          {:error, _not_found} ->
            {:error, {:runs_on, :mini_app_not_found, :requested}}
        end
    end
  end

  defp same_repo?(%{"owner" => owner, "name" => name}, app_owner, app_name)
       when is_binary(owner) and is_binary(name) and is_binary(app_owner) and
              is_binary(app_name),
       do:
         String.downcase(owner) == String.downcase(app_owner) and
           String.downcase(name) == String.downcase(app_name)

  defp same_repo?(_repo, _owner, _name), do: false

  defp pinned_placement(scope, %{"model" => %{"kind" => "runtime"} = model} = params, false) do
    if is_nil(params["runs_on"]) do
      case SalixIM.ConversationServer.task_request_placement(
             scope.group_id,
             scope[:task_request_identity]
           ) do
        {:ok, %{"runs_on" => place, "session_model" => ^model}} ->
          {:ok,
           %{params: params, runs_on: place, repo: nil, session_model: model, source: :automatic}}

        {:ok, nil} ->
          :none

        {:ok, _other_model} ->
          {:error, {:model, :task_request_changed}}

        {:error, reason} ->
          {:error, {:runs_on, reason, :automatic}}
      end
    else
      :none
    end
  end

  defp pinned_placement(_, _, _), do: :none

  defp resolve_new(scope, target_agent_id, params, loop?, mini_app) do
    with {:ok, placed, bound_model} <- station_binding(target_agent_id, params, loop?),
         {:ok, placed, source} <- default_place(scope, params, placed),
         {:ok, placed, source} <- loop_place(placed, source, loop?),
         {:ok, runs_on} <- runs_on(scope, target_agent_id, placed, source),
         {runs_on, repo} = split_repo(runs_on),
         {:ok, session_model} <-
           session_model(scope, target_agent_id, placed, runs_on, bound_model) do
      {:ok,
       %{
         params: placed,
         runs_on: runs_on,
         repo: repo,
         mini_app: mini_app,
         session_model: session_model,
         source: source
       }}
    end
  end

  # The product answers a coding Task's place with its checked repository; the
  # Task keeps them apart (`runs_on`, `repo`).
  defp split_repo(%{"kind" => "sandbox"} = runs_on),
    do: {Map.delete(runs_on, "repo"), runs_on["repo"]}

  defp split_repo(runs_on), do: {runs_on, nil}

  @doc false
  def placement_attrs(attrs, placement) do
    attrs
    |> Map.drop(["runs_on", "model", "session_model", "repo", "mini_app"])
    |> put_present("runs_on", placement.runs_on)
    |> put_present("repo", placement.repo)
    |> put_present("mini_app", placement[:mini_app])
    |> put_present("session_model", placement.session_model)
    |> put_present("automatic_task_place", if(placement.source == :automatic, do: true))
  end

  @doc """
  Create a Task a product asks for in Group `group_id`, delegated by the
  Group's Router `router_agent_id`. The Group's Task agent runs it
  (`SalixIM.Ports.TaskCreate.task_worker/1`); `attrs` may name a place
  (`"runs_on"`) and a model (`"model"`), checked by `resolve/4`. The other
  attrs (`title`, `content`, `client_request_id`, `source_refs`, ...) go to the
  create unchanged.
  """
  @spec create_task_conversation(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_task_conversation(group_id, router_agent_id, attrs, trusted_context \\ %{})
      when is_map(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    started = SystemsClock.monotonic_time(:millisecond)

    with false <- Enum.any?(~w(requester_user_id automatic_task_place), &Map.has_key?(attrs, &1)),
         {:ok, group} <- group(group_id),
         :ok <- router(group, router_agent_id),
         scope =
           Map.merge(Map.take(trusted_context, [:requester_user_id]), %{
             tenant_id: group["tenant_id"],
             group_id: group_id,
             task_request_identity: attrs["client_request_id"]
           }),
         {:ok, worker} <- task_worker(scope),
         {:ok, placement} <-
           resolve(
             scope,
             worker,
             Map.take(attrs, ["runs_on", "model", "repo", "mini_app"]),
             false
           ) do
      placed = SystemsClock.monotonic_time(:millisecond)

      result =
        TaskCreate.create_task_conversation(
          group_id,
          router_agent_id,
          worker,
          placement_attrs(attrs, placement)
        )

      # Where a product's Task create spends its time: placing it, then making it.
      Logger.info(
        "task placement create group=#{group_id} source=#{placement.source} " <>
          "resolve_ms=#{placed - started} " <>
          "create_ms=#{SystemsClock.monotonic_time(:millisecond) - placed} " <>
          "ok=#{match?({:ok, _}, result)}"
      )

      result
    else
      true -> {:error, :invalid_requester_parameter}
      {:error, _} = error -> error
    end
  end

  defp group(group_id) do
    case GroupDirectory.get_group(group_id) do
      {:ok, group} -> {:ok, group}
      {:error, reason} -> {:error, {:group, reason}}
    end
  end

  defp router(%{"router_agent_id" => router_agent_id}, router_agent_id)
       when is_binary(router_agent_id),
       do: :ok

  defp router(_group, _router_agent_id), do: {:error, :router_changed}

  defp task_worker(scope) do
    case TaskCreate.task_worker(scope) do
      {:ok, agent_id} when is_binary(agent_id) -> {:ok, agent_id}
      {:error, reason} -> {:error, {:task_worker, reason}}
    end
  end

  @doc "The text a Router reads for a refusal."
  @spec message(refusal()) :: String.t()
  def message({:runs_on, reason, source}), do: runs_on_refusal(reason, source)
  def message({:model, reason}), do: model_refusal(reason)

  def message({:bound_runs_on, bound}),
    do:
      "this Worker runs its Tasks on #{Jason.encode!(bound)}; give runs_on {kind: default} or that one"

  def message({:bound_model, provider}),
    do:
      "this Worker runs #{provider} on its station: give model {kind: runtime, provider: #{provider}, model?, reasoning_effort?}, or omit it"

  def message({:group, reason}), do: "the Group is not usable here: #{inspect(reason)}"
  def message({:agent, reason}), do: "the Worker is not usable here: #{inspect(reason)}"

  # A Worker bound to a station (`station_binding`, `SalixAgent.StationBinding`)
  # runs each Task there: a Task that names no place or model takes the
  # binding's. A Task may name them itself only when they agree with the
  # binding: the same place, and a model of the same runtime. A binding
  # without a model id leaves the station's default model of its runtime
  # (`bound_model`, which no product check is asked about). A Loop Task runs
  # inside Salix (`loop_place/3`), so a bound Worker refuses it first.
  defp station_binding(target_agent_id, params, loop?) do
    case GroupDirectory.get_agent(target_agent_id) do
      {:ok, %{"station_binding" => %{"runs_on" => %{}, "model" => model}}}
      when loop? and is_map(model) and is_map_key(model, "provider") ->
        {:error, {:runs_on, :station_for_loop, :binding}}

      {:ok, %{"station_binding" => %{"runs_on" => %{} = bound, "model" => model}}}
      when is_map(model) and is_map_key(model, "provider") ->
        with {:ok, runs_on} <- bound_runs_on(bound, params["runs_on"]),
             {:ok, choice, bound_model} <- bound_choice(model, model["provider"], params["model"]) do
          {:ok, params |> Map.put("runs_on", runs_on) |> put_present("model", choice),
           bound_model}
        end

      {:ok, _unbound} ->
        {:ok, params, nil}

      {:error, reason} ->
        {:error, {:agent, reason}}
    end
  end

  defp bound_runs_on(bound, nil), do: {:ok, bound}
  defp bound_runs_on(bound, bound), do: {:ok, bound}
  defp bound_runs_on(bound, _requested), do: {:error, {:bound_runs_on, bound}}

  defp bound_choice(%{"model" => _} = model, _provider, nil), do: {:ok, model, nil}
  defp bound_choice(model, _provider, nil), do: {:ok, nil, model}

  defp bound_choice(_model, provider, %{"kind" => "runtime", "provider" => provider} = choice),
    do: {:ok, choice, nil}

  defp bound_choice(_model, provider, _choice), do: {:error, {:bound_model, provider}}

  # Answers the params with the place to check, and where it came from.
  defp default_place(scope, params, placed) do
    cond do
      params["runs_on"] == %{"kind" => "salix"} ->
        {:ok, Map.delete(placed, "runs_on"), :salix}

      not is_nil(params["runs_on"]) ->
        {:ok, placed, :requested}

      not is_nil(placed["runs_on"]) ->
        {:ok, placed, :binding}

      not (is_nil(placed["model"]) or match?(%{"kind" => "runtime"}, placed["model"])) ->
        {:ok, placed, :salix}

      true ->
        case GroupDirectory.get_group(scope.group_id) do
          {:ok, group} ->
            case {group["default_task_place"], group_default_place(group)} do
              {%{"kind" => "salix"}, _} -> {:ok, placed, :salix}
              {_, nil} -> automatic_machine(scope, placed)
              {_, place} -> {:ok, Map.put(placed, "runs_on", place), :default}
            end

          {:error, reason} ->
            {:error, {:group, reason}}
        end
    end
  end

  defp group_default_place(%{"default_task_place" => %{"kind" => "cloud_vm"} = place})
       when map_size(place) == 1,
       do: place

  defp group_default_place(%{
         "default_task_place" => %{"kind" => "station", "device_id" => device_id} = place
       })
       when map_size(place) == 2 and is_binary(device_id) and device_id != "",
       do: place

  defp group_default_place(_group), do: nil

  # Selecting an external runtime already requires a machine. Internal model
  # Tasks retain their existing Salix placement.
  defp automatic_machine(scope, %{"model" => %{"kind" => "runtime"} = model} = placed) do
    case SalixIM.ConversationServer.task_request_placement(
           scope.group_id,
           scope[:task_request_identity]
         ) do
      {:ok, %{"runs_on" => pinned}} ->
        request =
          if pinned["kind"] == "cloud_vm", do: Map.delete(pinned, "device_id"), else: pinned

        {:ok, Map.put(placed, "runs_on", request), :automatic}

      {:ok, nil} ->
        {:ok, Map.put(placed, "runs_on", %{"kind" => "automatic", "model" => model}), :automatic}

      {:error, reason} ->
        {:error, {:runs_on, reason, :automatic}}
    end
  end

  defp automatic_machine(_scope, placed), do: {:ok, placed, :salix}

  # A Loop Task runs inside Salix. Its Worker gives the Task's Loop its
  # program with loop.build and loop.create, which need a Worker Session
  # inside Salix: a station's Session has no Salix tools, so the Loop would
  # stay pending. The Group's default place gives way to Salix; a place the
  # Router names refuses the Task. A runtime model runs only on a station, so
  # it refuses the Task too, wherever the Task would run.
  defp loop_place(placed, source, true) do
    cond do
      match?(%{"runs_on" => %{}}, placed) and source not in [:default, :automatic] ->
        {:error, {:runs_on, :station_for_loop, source}}

      match?(%{"kind" => "runtime"}, placed["model"]) ->
        {:error, {:runs_on, :station_for_loop, :model}}

      Map.has_key?(placed, "runs_on") ->
        {:ok, Map.delete(placed, "runs_on"), :salix}

      true ->
        {:ok, placed, source}
    end
  end

  defp loop_place(placed, source, _loop?), do: {:ok, placed, source}

  # A Task of an internal Worker can run on a station instead: a desktop
  # station (`{"kind": "station", "device_id": ...}`) or the Group's Cloud VM
  # (`{"kind": "cloud_vm"}`). The product resolves the device; the station runs
  # the Task's runtime model choice (`SalixIM.Ports.TaskStations`).
  defp runs_on(scope, target_agent_id, params, source) do
    case params["runs_on"] do
      nil ->
        {:ok, nil}

      %{"kind" => "sandbox"} = request ->
        case params["repo"] do
          repo when is_map(repo) ->
            sandbox(scope, target_agent_id, Map.put(request, "repo", repo), source)

          _missing ->
            {:error, {:runs_on, :repo_required, source}}
        end

      request when is_map(request) ->
        with {:ok, _agent} <- GroupDirectory.get_agent(target_agent_id),
             {:ok, runs_on} <-
               TaskCreate.runs_on(
                 Map.put(scope, :agent_id, target_agent_id),
                 request
               ) do
          {:ok, runs_on}
        else
          {:error, reason} -> {:error, {:runs_on, reason, source}}
        end

      _other ->
        {:error, {:runs_on, :not_an_object, source}}
    end
  end

  defp sandbox(scope, target_agent_id, request, source) do
    with {:ok, _agent} <- GroupDirectory.get_agent(target_agent_id),
         {:ok, %{"kind" => "sandbox"} = runs_on} <-
           TaskCreate.runs_on(
             %{tenant_id: scope.tenant_id, group_id: scope.group_id, agent_id: target_agent_id},
             request
           ) do
      {:ok, runs_on}
    else
      {:ok, _other} -> {:error, {:runs_on, :runs_on_unsupported, source}}
      {:error, reason} -> {:error, {:runs_on, reason, source}}
    end
  end

  # A bound Worker whose binding names only its runtime: the station runs its
  # default model of that runtime.
  defp session_model(scope, target_agent_id, params, runs_on, bound_model) do
    if is_map(bound_model) and is_nil(params["model"]),
      do: {:ok, bound_model},
      else: session_model(scope, target_agent_id, params, runs_on)
  end

  # A Worker's Session for this Task can use its own model instead of the
  # Worker's (`SalixAgent.ModelChoice`). The product checks the choice: a
  # catalog choice inside Salix, or a runtime choice on a station. A runtime
  # choice without a model id runs the station's default model of that
  # runtime (on the Group's Cloud VM, the platform model with Codex), which no
  # product check is asked about.
  defp session_model(scope, target_agent_id, params, runs_on) do
    case params["model"] do
      nil ->
        {:ok, nil}

      %{"kind" => "runtime", "provider" => provider} = choice
      when map_size(choice) == 2 and provider in ~w(codex claude) ->
        with :ok <- model_fits_runs_on(choice, runs_on), do: {:ok, choice}

      choice when is_map(choice) ->
        with {:ok, _agent} <- GroupDirectory.get_agent(target_agent_id),
             :ok <- model_fits_runs_on(choice, runs_on),
             {:ok, model} <-
               TaskCreate.session_model(
                 %{tenant_id: scope.tenant_id, group_id: scope.group_id, runs_on: runs_on},
                 choice
               ) do
          {:ok, model}
        else
          {:error, {:model, _reason}} = error -> error
          {:error, reason} -> {:error, {:model, reason}}
        end

      _other ->
        {:error, {:model, :not_an_object}}
    end
  end

  defp model_fits_runs_on(%{"kind" => "runtime"}, nil),
    do: {:error, {:model, :runtime_requires_runs_on}}

  defp model_fits_runs_on(%{"kind" => "runtime"}, _runs_on), do: :ok
  defp model_fits_runs_on(_choice, nil), do: :ok
  defp model_fits_runs_on(_choice, _runs_on), do: {:error, {:model, :runs_on_requires_runtime}}

  defp runs_on_refusal(:not_an_object, _source), do: "runs_on must be an object"

  defp runs_on_refusal(:station_candidate_page_exhausted, _source),
    do:
      "the first eight personal Station candidates are unavailable; choose a device explicitly to check another Station"

  defp runs_on_refusal(:runs_on_unsupported, _source),
    do: "this product does not accept runs_on; omit it"

  defp runs_on_refusal(:station_for_loop, :binding),
    do:
      "this Worker runs its Tasks on a station (its station binding), and a Loop Task " <>
        "runs inside Salix, where its Worker creates the Loop. Give agent_id of a Worker " <>
        "that runs inside Salix. The Task was not made."

  defp runs_on_refusal(:station_for_loop, :model),
    do:
      "a Loop Task runs inside Salix, where its Worker creates the Loop, and a model of " <>
        "kind runtime runs only on a station. Omit model or give one not of kind runtime. " <>
        "The Task was not made."

  # A Loop Task made on a station before Loop Tasks ran only inside Salix:
  # its station Worker cannot create a new Loop.
  defp runs_on_refusal(:station_for_loop, :task),
    do:
      "this Task runs on a station, and a Loop runs only inside Salix, where its Worker " <>
        "creates it, so this Task cannot get a new Loop. Create a new Loop Task with " <>
        "task.create with runs_on {kind: salix}."

  defp runs_on_refusal(:station_for_loop, _source),
    do:
      "a Loop Task runs inside Salix, where its Worker creates the Loop; a station or " <>
        "the Cloud VM cannot. Give runs_on {kind: default} or {kind: salix}, and omit a model of " <>
        "kind runtime. Its Worker can still run commands on the Cloud VM with env.exec. " <>
        "The Task was not made."

  # The Group's default place refused the Task: the refusal a place the Router
  # named gets, and that the place is the Group's default, which people change
  # in the product's settings.
  defp runs_on_refusal(reason, :default),
    do:
      runs_on_refusal(reason, :requested) <>
        " (It is the Group's default place to run Tasks, set in the product's settings. " <>
        "Tell the user, or give runs_on {kind: salix} to run the Task inside Salix.)"

  # Automatic placement started the Group's Cloud VM and it did not come up
  # within its budget (`SalixWeb.TaskStations`); a Task that names the Cloud
  # VM waits for it instead (`SalixWeb.StationTasks`).
  defp runs_on_refusal(:cloud_vm_not_running, _source),
    do:
      "the Group's Cloud VM did not come up in time: give runs_on {kind: cloud_vm} to have the Task wait for it"

  defp runs_on_refusal(:device_offline, _source),
    do: "that station is not connected now; the Task was not made"

  defp runs_on_refusal({reason, info}, _source)
       when reason in [:device_needs_station, :station_outdated],
       do: station_refusal(reason, info)

  defp runs_on_refusal(:repo_required, _source),
    do:
      "runs_on {kind: sandbox} needs repo {owner, name, base_ref?}: the GitHub repository " <>
        "to check out. The Task was not made."

  defp runs_on_refusal(:repo_requires_sandbox, _source),
    do:
      "repo requires runs_on {kind: sandbox}. Describe existing files in content when using another machine."

  defp runs_on_refusal(:mini_app_requires_sandbox, _source),
    do:
      "mini_app requires runs_on {kind: sandbox} and repo {owner, name}: an app is built " <>
        "in a coding sandbox. The Task was not made."

  defp runs_on_refusal(:mini_app_repo_mismatch, _source),
    do:
      "repo must be the app's repository, the repo internal.apps.create returned. " <>
        "The Task was not made."

  defp runs_on_refusal(:mini_app_not_found, _source),
    do:
      "mini_app must be {app_id} of an app of this Workspace, the app_id " <>
        "internal.apps.create returned. The Task was not made."

  defp runs_on_refusal(:mini_apps_unavailable, _source),
    do: "apps are not set up here; omit mini_app. The Task was not made."

  defp runs_on_refusal(:sandbox_unavailable, _source),
    do: "coding sandboxes are not set up here; give another place. The Task was not made."

  defp runs_on_refusal(:github_not_connected, _source),
    do:
      "the Workspace has no GitHub account connected, so a sandbox cannot check out the " <>
        "repository. Ask the user to connect GitHub in Settings > Plugins. The Task was not made."

  defp runs_on_refusal(:github_reauthorization_required, _source),
    do:
      "the Workspace's GitHub connection needs the user to sign in again (Settings > Plugins). " <>
        "The Task was not made."

  defp runs_on_refusal({:repo_not_found, repo}, _source),
    do:
      "the connected GitHub account cannot read #{repo}; check the owner and name. " <>
        "The Task was not made."

  defp runs_on_refusal(:invalid_repo, _source),
    do:
      "repo must be {owner, name, base_ref?, branch?} or {owner, name, pull_request} with GitHub " <>
        "names; the Task was not made"

  defp runs_on_refusal({:pull_request_not_found, ref}, _source),
    do:
      "the connected GitHub account cannot read pull request #{ref}; check the number. " <>
        "The Task was not made."

  defp runs_on_refusal({:pull_request_unreadable, ref}, _source),
    do:
      "GitHub did not answer about pull request #{ref} just now; try again. " <>
        "The Task was not made."

  defp runs_on_refusal({:pull_request_branch_unusable, number}, _source),
    do:
      "pull request ##{number}'s head branch is gone or has a name a sandbox cannot check out. " <>
        "Omit pull_request to work on a new Task branch. The Task was not made."

  defp runs_on_refusal({:pull_request_not_open, number, state}, _source),
    do:
      "pull request ##{number} is #{state}, so a Task cannot continue it. Omit pull_request to " <>
        "work on a new Task branch. The Task was not made."

  defp runs_on_refusal({:pull_request_from_fork, number}, _source),
    do:
      "pull request ##{number} comes from a branch of another repository, which the sandbox " <>
        "cannot push to. Omit pull_request to work on a new Task branch. The Task was not made."

  defp runs_on_refusal({:sandbox_limit, max}, _source),
    do:
      "the Workspace already runs #{max} coding sandboxes, the most it may; end one " <>
        "(set its Task completed) or wait. The Task was not made."

  defp runs_on_refusal(:device_not_found, _source),
    do: "that station is not known in this Group; check device.list"

  defp runs_on_refusal(:cloud_vm_disabled, _source),
    do: "the Workspace's Cloud VM switch is off; give another station"

  defp runs_on_refusal(reason, _source), do: "runs_on is not usable here: #{inspect(reason)}"

  # A device that cannot take Tasks: what its user does, for the agent to pass
  # on, with the structured reason (`SalixStore.StationReadiness`).
  defp station_refusal(reason, info) do
    tasks = if info["tasks"], do: "tasks #{info["tasks"]}, ", else: ""

    "#{SalixStore.StationReadiness.instructions(reason)} The Task was not made " <>
      "(reason: #{reason}; #{tasks}needs tasks #{info["required_tasks"]}). Tell the user."
  end

  defp model_refusal(:not_an_object), do: "model must be an object"
  defp model_refusal(:runtime_requires_runs_on), do: "model of kind runtime requires runs_on"
  defp model_refusal(:runs_on_requires_runtime), do: "runs_on requires model of kind runtime"

  defp model_refusal(:model_selection_unsupported),
    do: "this product does not accept model; omit it to use the default Task model"

  defp model_refusal(:model_not_allowed),
    do:
      "the organization does not allow this model choice; ask the user to pick another or an admin to allow it"

  defp model_refusal({:not_on_station, models}),
    do:
      "that station has no profile with this model enabled; it runs #{Jason.encode!(models)} (or omit model to use its default)"

  defp model_refusal(reason),
    do: "model is not usable here: #{inspect(reason)}; check agent.models"

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
