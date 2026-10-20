defmodule SalixIM.Ports.TaskStations do
  @moduledoc """
  Outbound port to the stations whose Sessions take part in a Task Salix keeps
  (`systems/station/docs/tasks.md`).

  SalixIM owns the Task and its Messages. The configured product module
  (`:task_stations_mod`) asks the station to take part before the Task is made,
  records the Session once it is, and gives each station the Messages it has
  not had.
  """

  @doc """
  Asks a station to start a Session for a Task about to be made. `invite`
  carries `tenant_id`, `group_id`, `conversation_id`, `device_id` and `start`
  (what the station starts its Session with). Answered at once.
  """
  @callback invite(invite :: map()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  The station's Session takes part in the Task just made: `row` carries
  `tenant_id`, `group_id`, `conversation_id`, `device_id`, `session`, the
  Worker's `agent_id` (who authors what the Session writes) and the `start` it
  was invited with (a station that lost the Task is invited again with it).
  """
  @callback joined(row :: map()) :: :ok | {:error, term()}

  @doc "A Message was added to a Task. Never waits for a station."
  @callback appended(group_id :: String.t(), conversation_id :: String.t()) :: :ok

  @doc """
  Where the station taking part in a Task stands, for `SalixIM.StationTaskWatch`
  (one bounded read of the station's participation, its device record and,
  for the Group's Cloud VM, its Workload): `place` is `:cloud_vm` when the
  station is the Group's Cloud VM and `:device` otherwise; `connected?` says
  whether its connector is connected now; `sent` is the Message seq through
  which it was given the Task; `vm_status` is the Cloud VM's Workload status
  (`ready`, `waking`, `archived`…), nil for a device or for a Group with no
  Cloud VM Workload. `:not_station` when no station takes part in the Task;
  `{:error, reason}` when a read failed, so the watch asks again later rather
  than taking the failure for a stage.
  """
  @callback standing(group_id :: String.t(), conversation_id :: String.t()) ::
              {:ok,
               %{
                 place: :cloud_vm | :device,
                 connected?: boolean(),
                 sent: non_neg_integer(),
                 vm_status: String.t() | nil
               }}
              | :not_station
              | {:error, term()}

  @doc """
  Where the station's Session of the Task stands, for `SalixIM.StationTaskWatch`
  once the station has the delegation: one `task.status` request to the
  station, answered at once and started nothing by. `state` is `:running` (a
  turn runs there, or is starting), `:waiting` (the agent declared it waits
  on work it started), `:idle` (nothing runs, nothing pending),
  `:cannot_start` (Messages are pending but its runtime did not start, tried
  again backing off; `last_failure` says why last, at most 200 characters) or
  `:gone` (the station has no thread of the Task, or no such Session takes
  part); `pending` counts the Messages not handed to the Session yet; `for_ms`
  is how long it has been in the state (a duration, so the clocks need not
  agree), nil when it does not know. `:unknown` when the station cannot be asked now, did not answer
  in time, or does not know the request (a station from before it).
  """
  @callback session_status(group_id :: String.t(), conversation_id :: String.t()) ::
              {:ok,
               %{
                 state: :running | :waiting | :idle | :cannot_start | :gone,
                 pending: non_neg_integer(),
                 for_ms: non_neg_integer() | nil,
                 last_failure: String.t() | nil
               }}
              | :unknown

  @spec invite(map()) :: {:ok, String.t()} | {:error, term()}
  def invite(invite) when is_map(invite) do
    case impl() do
      nil -> {:error, :task_stations_not_configured}
      module -> module.invite(invite)
    end
  end

  @spec joined(map()) :: :ok | {:error, term()}
  def joined(row) when is_map(row) do
    case impl() do
      nil -> {:error, :task_stations_not_configured}
      module -> module.joined(row)
    end
  end

  @spec appended(String.t(), String.t()) :: :ok
  def appended(group_id, conversation_id) do
    case impl() do
      nil -> :ok
      module -> module.appended(group_id, conversation_id)
    end
  end

  @spec standing(String.t(), String.t()) :: {:ok, map()} | :not_station | {:error, term()}
  def standing(group_id, conversation_id) do
    case impl() do
      nil -> :not_station
      module -> module.standing(group_id, conversation_id)
    end
  end

  @spec session_status(String.t(), String.t()) :: {:ok, map()} | :unknown
  def session_status(group_id, conversation_id) do
    case impl() do
      nil -> :unknown
      module -> module.session_status(group_id, conversation_id)
    end
  end

  @doc false
  def impl, do: SystemsRuntime.get_env(:salix_im, :task_stations_mod)
end
