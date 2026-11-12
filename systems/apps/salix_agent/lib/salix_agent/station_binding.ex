defmodule SalixAgent.StationBinding do
  @moduledoc """
  Where a Worker's Tasks run: a station bound to the Worker, and the runtime
  model that station runs for them.

  The Agent record field `station_binding` holds:

    * `runs_on`: `%{"kind" => "station", "device_id" => id}` (a user's Comma
      station, or a VMM Workload's station by its device id, the Group's own
      VM on its Agent VMM Host among them,
      `SalixStore.ComputeGroupStation.vmm_group_vm?/2`),
      `%{"kind" => "cloud_vm"}` (the Group's Cloud VM; where it is retired it
      is refused, and the Cloud VM cutover binds a Worker of a Group whose VM
      is on its Agent VMM Host to that VM's station instead) or
      `%{"kind" => "sandbox"}`
      (a sandbox of its own for each Task, `SalixWeb.CodingSandboxes`; each
      Task takes one of the Group's live-sandbox slots, and where sandboxes
      are not set up the Tasks are refused as `sandbox_unavailable`). The
      Cloud VM belongs to the Group, which decides whether its Agents may
      start it and place Tasks there (`SalixAgent.CloudVM.allowed?/1`); the
      binding only makes it the Worker's default Task location.
    * `model`: `%{"kind" => "runtime", "provider" => "codex" | "claude"}` with
      an optional `model` and `reasoning_effort` (`SalixAgent.ModelChoice`).
      Without `model` the station runs its default model for that runtime.
    * `binding_revision`: incremented by each rebind.

  Salix hosts a bound Worker's Tasks. `im_api.internal.task.create` gives each
  Task the binding's `runs_on` and model when the call gives none; the station
  runs a Session for the Task (`SalixWeb.StationTasks`). A bound Worker is an
  internal Worker.
  """

  alias SalixAgent.ModelChoice
  alias SalixStore.RuntimeIds

  @providers ~w(codex claude)
  @cloud_vm_retired_message "the Group's Cloud VM is retired here: bind the Worker with runs_on {kind: sandbox}"

  @retired_external_message "external Workers are retired; create a Worker bound to a station instead: " <>
                              "station_binding {runs_on: {kind: station, device_id} | {kind: cloud_vm}, " <>
                              "model: {kind: runtime, provider: codex | claude, model?, reasoning_effort?}}"

  @doc "The error a create or configure answers when it asks for an External Runtime Worker."
  def retired_external_message, do: @retired_external_message

  @doc "The binding of an Agent record, or nil."
  @spec get(map()) :: map() | nil
  def get(%{"station_binding" => %{"runs_on" => %{}} = binding}), do: binding
  def get(_agent), do: nil

  @doc "Whether an Agent record is a Worker bound to a station."
  def bound?(agent), do: not is_nil(get(agent))

  @doc """
  Whether an Agent record is a live Worker bound to its Group's Cloud VM. An
  archived Worker uses nothing.
  """
  def cloud_vm?(%{"station_binding" => %{"runs_on" => %{"kind" => "cloud_vm"}}} = agent),
    do: not Map.has_key?(agent, "archived_at") and agent["permanent_archive"] != true

  def cloud_vm?(_agent), do: false

  @doc """
  Check a requested binding against the tenant and Group of the Worker and
  answer the value to store. `revision` is the `binding_revision` to store.
  """
  @spec normalize(term(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def normalize(%{} = request, tenant_id, group_id, revision)
      when is_integer(revision) and revision > 0 do
    request = stringify(request)

    with :ok <- known_keys(request, ~w(runs_on model)),
         {:ok, runs_on} <- runs_on(request["runs_on"], group_id),
         {:ok, model} <- model(request["model"], tenant_id) do
      {:ok, %{"runs_on" => runs_on, "model" => model, "binding_revision" => revision}}
    end
  end

  def normalize(_request, _tenant_id, _group_id, _revision),
    do: {:error, {:bad_request, "station_binding must be an object"}}

  @doc """
  Check a `runs_on` a Worker of Group `group_id` can be bound to. Where its
  Cloud VM is retired (`SalixAgent.Sandboxes.cloud_vm_retired?/1`): bind a
  sandbox instead.
  """
  @spec runs_on(term(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def runs_on(%{"kind" => "cloud_vm"} = runs_on, group_id) when map_size(runs_on) == 1 do
    if SalixAgent.Sandboxes.cloud_vm_retired?(group_id),
      do: {:error, {:bad_request, @cloud_vm_retired_message}},
      else: {:ok, %{"kind" => "cloud_vm"}}
  end

  def runs_on(%{"kind" => "sandbox"} = runs_on, _group_id) when map_size(runs_on) == 1,
    do: {:ok, %{"kind" => "sandbox"}}

  # A Group VM is a station only on its Agent VMM Host; on Cloudflare it is
  # the Cloud VM, which the station form must not reach past its retirement.
  def runs_on(%{"kind" => "station", "device_id" => device_id} = runs_on, group_id)
      when map_size(runs_on) == 2 and is_binary(device_id) do
    device_id = String.trim(device_id)

    cond do
      device_id == "" or byte_size(device_id) > 256 ->
        {:error, {:bad_request, "station_binding.runs_on.device_id is invalid"}}

      String.starts_with?(device_id, "dev-cloudvm-") and
          not SalixStore.ComputeGroupStation.vmm_group_vm?(group_id, device_id) ->
        {:error,
         {:bad_request,
          if(SalixAgent.Sandboxes.cloud_vm_retired?(group_id),
            do: @cloud_vm_retired_message,
            else: "bind the Group's Cloud VM with runs_on {kind: cloud_vm}"
          )}}

      true ->
        {:ok, %{"kind" => "station", "device_id" => device_id}}
    end
  end

  def runs_on(_runs_on, _group_id),
    do:
      {:error,
       {:bad_request,
        "station_binding.runs_on must be {kind: station, device_id}, {kind: cloud_vm} or {kind: sandbox}"}}

  @doc "Check the runtime model of a binding. Without `model`, the station's default runs."
  @spec model(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def model(%{"kind" => "runtime", "provider" => provider} = choice, tenant_id)
      when provider in @providers do
    cond do
      not Enum.all?(Map.keys(choice), &(&1 in ~w(kind provider model reasoning_effort))) ->
        {:error, {:bad_request, "station_binding.model has unknown fields"}}

      Map.has_key?(choice, "model") ->
        case ModelChoice.choose(choice, tenant_id) do
          {:ok, value} ->
            {:ok, value}

          {:error, _reason} ->
            {:error,
             {:bad_request, "station_binding.model is not a #{provider} model of the catalog"}}
        end

      Map.has_key?(choice, "reasoning_effort") ->
        {:error, {:bad_request, "station_binding.model.reasoning_effort requires model"}}

      true ->
        {:ok, %{"kind" => "runtime", "provider" => provider}}
    end
  end

  def model(_choice, _tenant_id),
    do:
      {:error,
       {:bad_request,
        "station_binding.model must be {kind: runtime, provider: codex | claude, model?, reasoning_effort?}"}}

  @doc "Whether `device_id` names the Group's Cloud VM station."
  def cloud_vm_device?(group_id, device_id),
    do: device_id == RuntimeIds.cloud_vm_device_id(group_id)

  defp known_keys(request, keys) do
    if Enum.all?(Map.keys(request), &(&1 in keys)),
      do: :ok,
      else: {:error, {:bad_request, "station_binding takes only runs_on and model"}}
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value), do: value
end
