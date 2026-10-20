defmodule SalixIM.TaskPlacement do
  @moduledoc """
  Where a new Task runs and which model its Worker Session uses. A Router's
  `task.create` and a product that creates a Task for its Group (the
  BridgeForTeams dashboard, `create_task_conversation/3`) make the same checks.

  A Task names a place (`runs_on`) and a model (`model`), or leaves them out:

    * A Worker bound to a station (`station_binding`) runs each Task there.
    * With no place, the Group's default place (`SalixAgent.TaskPlace`) applies,
      checked as a named place is. A Group that has set none, or chose Salix,
      runs it inside Salix. `runs_on {"kind": "salix"}` asks for Salix whatever
      the default is. A model only Salix runs (not of kind runtime) runs inside
      Salix too.
    * A place is checked by the product (`SalixIM.Ports.TaskCreate.runs_on/2`):
      the Cloud VM switch on and the VM running, a station connected and ready,
      and no person's own computer for a Loop Task.
    * With no model, a Task inside Salix runs the Group's default Task model
      (`SalixIM.TaskConversationInput`) and a station its own default model.

  A refusal is a structured reason (`t:refusal/0`); `message/1` answers the text
  a Router reads.
  """

  alias SalixIM.GroupDirectory
  alias SalixIM.Ports.TaskCreate

  @typedoc """
  Why a place or model was refused. `source` says where the place came from:
  `:requested` (named), `:binding` (the Worker's station binding), `:default`
  (the Group's default place) or `:salix`.
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
          session_model: map() | nil,
          source: :requested | :binding | :default | :salix
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
    with {:ok, placed, bound_model} <- station_binding(target_agent_id, params),
         {:ok, placed, source} <- default_place(scope, params, placed),
         {:ok, runs_on} <- runs_on(scope, target_agent_id, placed, loop?, source),
         {:ok, session_model} <-
           session_model(scope, target_agent_id, placed, runs_on, bound_model) do
      {:ok, %{params: placed, runs_on: runs_on, session_model: session_model, source: source}}
    end
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
  def create_task_conversation(group_id, router_agent_id, attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with {:ok, group} <- group(group_id),
         :ok <- router(group, router_agent_id),
         scope = %{tenant_id: group["tenant_id"], group_id: group_id},
         {:ok, worker} <- task_worker(scope),
         {:ok, placement} <-
           resolve(scope, worker, Map.take(attrs, ["runs_on", "model"]), false) do
      TaskCreate.create_task_conversation(
        group_id,
        router_agent_id,
        worker,
        attrs
        |> Map.drop(["runs_on", "model", "session_model"])
        |> put_present("runs_on", placement.runs_on)
        |> put_present("session_model", placement.session_model)
      )
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
    do: "this Worker runs its Tasks on #{Jason.encode!(bound)}; omit runs_on or give that one"

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
  # (`bound_model`, which no product check is asked about).
  defp station_binding(target_agent_id, params) do
    case GroupDirectory.get_agent(target_agent_id) do
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
            case group_default_place(group) do
              nil -> {:ok, placed, :salix}
              place -> {:ok, Map.put(placed, "runs_on", place), :default}
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

  # A Task of an internal Worker can run on a station instead: a desktop
  # station (`{"kind": "station", "device_id": ...}`) or the Group's Cloud VM
  # (`{"kind": "cloud_vm"}`). The product resolves the device; the station runs
  # the Task's runtime model choice (`SalixIM.Ports.TaskStations`). A Loop runs
  # while every app is closed, so the product refuses a person's own computer
  # for a Loop Task (`loop`).
  defp runs_on(scope, target_agent_id, params, loop?, source) do
    case params["runs_on"] do
      nil ->
        {:ok, nil}

      request when is_map(request) ->
        with {:ok, _agent} <- GroupDirectory.get_agent(target_agent_id),
             {:ok, runs_on} <-
               TaskCreate.runs_on(
                 %{
                   tenant_id: scope.tenant_id,
                   group_id: scope.group_id,
                   agent_id: target_agent_id,
                   loop: loop?
                 },
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

  defp runs_on_refusal(:runs_on_unsupported, _source),
    do: "this product does not accept runs_on; omit it"

  defp runs_on_refusal(:personal_station_for_loop, :binding),
    do:
      "this Worker runs its Tasks on a person's own computer (its station binding), " <>
        "which stops taking Tasks when the app quits, so it cannot run a Loop Task. " <>
        "Give agent_id of a Worker that runs inside Salix or on the Group's Cloud VM, " <>
        "or ask the user to bind this Worker to the Cloud VM. The Task was not made."

  defp runs_on_refusal(:personal_station_for_loop, :default),
    do:
      "the Group's default place to run Tasks is a person's own computer, which stops " <>
        "taking Tasks when the app quits, so it cannot run a Loop Task. Give runs_on " <>
        "{kind: salix} to run the Loop inside Salix, or {kind: cloud_vm}. The Task " <>
        "was not made."

  defp runs_on_refusal(:personal_station_for_loop, _source),
    do:
      "that station is a person's own computer, which stops taking Tasks when the app " <>
        "quits, so it cannot run a Loop Task. Omit runs_on to run the Loop inside " <>
        "Salix, or give runs_on {kind: cloud_vm}. The Task was not made."

  # The Group's default place refused the Task: the refusal a place the Router
  # named gets, and that the place is the Group's default, which people change
  # in the product's settings.
  defp runs_on_refusal(reason, :default),
    do:
      runs_on_refusal(reason, :requested) <>
        " (It is the Group's default place to run Tasks, set in the product's settings. " <>
        "Tell the user, or give runs_on {kind: salix} to run the Task inside Salix.)"

  defp runs_on_refusal(:cloud_vm_not_running, _source),
    do: "the Group's Cloud VM is not running: start it with cloud_vm.start, then create the Task"

  defp runs_on_refusal(:device_offline, _source),
    do: "that station is not connected now; the Task was not made"

  defp runs_on_refusal({reason, info}, _source)
       when reason in [:device_needs_station, :station_outdated],
       do: station_refusal(reason, info)

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
