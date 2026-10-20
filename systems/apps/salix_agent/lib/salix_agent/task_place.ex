defmodule SalixAgent.TaskPlace do
  @moduledoc """
  A Group's default place to run Tasks: where a Task a Router creates runs
  when it names no place (`runs_on`). It is a value on the Group record
  (`default_task_place`), which the Group's product sets (Comma Settings >
  Models, the BridgeForTeams swarm settings).

    * `%{"kind" => "salix"}`: inside Salix. A Group that has set none runs its
      Tasks there too.
    * `%{"kind" => "cloud_vm"}`: the Group's Cloud VM.
    * `%{"kind" => "station", "device_id" => id}`: a station of the Group.

  Only the shape is checked when it is set, and the Cloud VM only while the
  Group's Cloud VM switch is on; the product checks that a station is one of
  its own. Each Task checks the place again when it is created
  (`SalixIM.Ports.TaskCreate.runs_on/2`): the Cloud VM switch on and the VM
  running, a station connected and ready, and no person's own computer for a
  Loop Task. A place that fails refuses the Task, which is not moved
  elsewhere.
  """

  alias SalixStore.{CasRecord, Ids, Keys}

  @field "default_task_place"
  @salix %{"kind" => "salix"}
  @cloud_vm %{"kind" => "cloud_vm"}

  @doc "Running inside Salix, as a default place."
  def salix, do: @salix

  @doc "The Group's Cloud VM, as a default place."
  def cloud_vm, do: @cloud_vm

  @doc "The Group's default place, or nil when it has set none (inside Salix)."
  @spec get(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get(group_id) do
    with true <- Ids.valid_group_id?(group_id),
         {:ok, group} <- CasRecord.get(Keys.ctl_group(group_id)) do
      {:ok, of_group(group)}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc "The default place a Group record holds, or nil."
  @spec of_group(map()) :: map() | nil
  def of_group(group) when is_map(group) do
    value = group[@field]
    if valid?(value), do: value
  end

  @doc "Whether `value` is a stored default place."
  def valid?(@salix), do: true
  def valid?(@cloud_vm), do: true

  def valid?(%{"kind" => "station", "device_id" => device_id} = value)
      when map_size(value) == 2 and is_binary(device_id),
      do: device_id == String.trim(device_id) and device_id_ok?(device_id)

  def valid?(_value), do: false

  @doc """
  Check `place` and store it as the default place of the Group of
  `tenant_id`. `nil` clears it: the Group has set none again. The Cloud VM
  needs the Group's Cloud VM switch on (`:cloud_vm_disabled`); the Group's
  own Cloud VM station is named as `{kind: cloud_vm}` (`:use_cloud_vm_kind`).
  """
  @spec put(String.t(), String.t(), term()) :: {:ok, map() | nil} | {:error, term()}
  def put(tenant_id, group_id, nil),
    do: write(tenant_id, group_id, fn _group, _current -> nil end)

  def put(tenant_id, group_id, place) do
    with {:ok, value} <- normalize(place, group_id) do
      write(tenant_id, group_id, fn group, _current ->
        if value == @cloud_vm and group["cloud_vm_enabled"] != true,
          do: {:error, :cloud_vm_disabled},
          else: value
      end)
    end
  end

  @doc """
  Store `value`, already a stored place, only while the Group has set none:
  the first default a release derives from earlier settings. Answers the
  Group's default afterwards.
  """
  @spec put_new(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_new(tenant_id, group_id, value) do
    if valid?(value),
      do: write(tenant_id, group_id, fn _group, current -> current || value end),
      else: {:error, :invalid_task_place}
  end

  defp normalize(%{} = place, group_id) do
    case Map.new(place, fn {key, value} -> {to_string(key), value} end) do
      %{"kind" => "station", "device_id" => device_id} = request
      when map_size(request) == 2 and is_binary(device_id) ->
        device_id = String.trim(device_id)

        cond do
          device_id == SalixStore.RuntimeIds.cloud_vm_device_id(group_id) ->
            {:error, :use_cloud_vm_kind}

          device_id_ok?(device_id) ->
            {:ok, %{"kind" => "station", "device_id" => device_id}}

          true ->
            {:error, :invalid_task_place}
        end

      request ->
        if request in [@salix, @cloud_vm], do: {:ok, request}, else: {:error, :invalid_task_place}
    end
  end

  defp normalize(_place, _group_id), do: {:error, :invalid_task_place}

  defp device_id_ok?(device_id),
    do:
      device_id != "" and byte_size(device_id) <= 256 and
        not String.starts_with?(device_id, "dev-cloudvm-")

  defp write(tenant_id, group_id, next) do
    with true <- Ids.valid_group_id_for_tenant?(group_id, tenant_id),
         {:ok, group} <-
           CasRecord.update(
             Keys.ctl_group(group_id),
             fn
               %{"tenant_id" => ^tenant_id} = group ->
                 current = of_group(group)

                 case next.(group, current) do
                   {:error, _reason} = error -> error
                   ^current -> {:unchanged, group}
                   nil -> Map.delete(group, @field)
                   value -> Map.put(group, @field, value)
                 end

               _other_tenant ->
                 {:error, :not_found}
             end,
             create: false
           ) do
      SalixStore.ReadScope.invalidate({:record, Keys.ctl_group(group_id)})
      {:ok, of_group(group)}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end
end
