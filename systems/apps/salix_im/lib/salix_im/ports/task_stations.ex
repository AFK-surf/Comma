defmodule SalixIM.Ports.TaskStations do
  @moduledoc """
  Outbound port to the stations whose Sessions take part in a Task Salix keeps, and the
  sandboxes of coding Tasks
  (`systems/station/docs/tasks.md`).

  SalixIM owns the Task and its Messages. The configured product module
  (`:task_stations_mod`) asks the station to take part before the Task is made,
  records the Session once it is, and gives each station the Messages it has
  not had.
  """

  @doc """
  Asks a station to start a Session for a Task about to be made. `invite`
  carries `tenant_id`, `group_id`, `conversation_id`, `device_id` and `start`
  (what the station starts its Session with), and `replace: true` when the
  Task runs another model on a station that takes part in it already: a new
  Session then takes the place of the one it had. Answered at once: the
  Session, or `{:ok, :when_connected}` for a station that is not connected
  now but comes back when Salix wakes it (the Group's Cloud VM): the Task is
  made, and the station is invited with `start` when it connects
  (`joined/1`). A person's station that is not connected is
  `{:error, :device_offline}`.
  """
  @callback invite(invite :: map()) ::
              {:ok, String.t()} | {:ok, :when_connected} | {:error, term()}

  @doc """
  The station's Session takes part in the Task just made: `row` carries
  `tenant_id`, `group_id`, `conversation_id`, `device_id`, `session`, the
  Worker's `agent_id` (who authors what the Session writes) and the `start` it
  was invited with (a station that lost the Task is invited again with it).
  With `session` nil, the station is expected (`invite/1` answered
  `{:ok, :when_connected}`): the product wakes it, invites it with `start`
  when it connects, and gives it the Task then.
  """
  @callback joined(row :: map()) :: :ok | {:error, term()}

  @doc """
  Reserves the sandbox of a sandbox Task about to be made (`runs_on {kind:
  sandbox}`), in place of inviting a station: no station runs it yet. The
  product makes the sandbox and invites its station once it connects.
  `reservation` carries what `joined/1`'s row does but `session`, and the
  Task's `repo` (nil for a Task without a repository), the subscription
  `account_id` it runs on (nil for the default) and its `requester` (a user
  id or nil).
  """
  @callback sandbox(reservation :: map()) :: :ok | {:error, term()}

  @doc "Replaces an existing coding sandbox's GitHub ACL. L4ES owns validation and storage."
  @callback update_github(String.t(), String.t(), map() | false) ::
              {:ok, map() | false} | {:error, term()}

  @doc """
  The web terminal links of those of coding Tasks `conversation_ids` that
  have a sandbox, by Task id, in one read: what a member opens to work in
  the sandbox while it runs. A link is no credential.
  """
  @callback terminal_urls(group_id :: String.t(), conversation_ids :: [String.t()]) :: %{
              String.t() => String.t()
            }

  @doc """
  A Task's status changed to `status`: a coding Task that ended or was
  archived gives up its sandbox. Never waits for a provider.
  """
  @callback task_status(
              group_id :: String.t(),
              conversation_id :: String.t(),
              status :: String.t()
            ) ::
              :ok

  @doc """
  The Task now runs elsewhere (`SalixIM.TaskRun`): every station that took
  part leaves it, told so unless it runs it now; `to`, when the Task runs on a
  station now, is the row `joined/1` takes for its new Session (nil when it
  runs inside Salix). `move` carries `group_id`, `conversation_id` and `to`.
  """
  @callback moved(move :: map()) :: :ok | {:error, term()}

  @doc """
  The Sessions of stations taking part in a Task, by device: one bounded read
  of its participation (`SalixIM.TaskRun` asks it before a switch).
  """
  @callback sessions(group_id :: String.t(), conversation_id :: String.t()) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}
  @optional_callbacks moved: 1, sessions: 2, terminal_urls: 2, update_github: 3

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
                 place: :cloud_vm | :sandbox | :device,
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

  @spec invite(map()) :: {:ok, String.t()} | {:ok, :when_connected} | {:error, term()}
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

  @spec sandbox(map()) :: :ok | {:error, term()}
  def sandbox(reservation) when is_map(reservation) do
    case impl() do
      nil -> {:error, :task_stations_not_configured}
      module -> module.sandbox(reservation)
    end
  end

  def update_github(group_id, conversation_id, github) do
    module = impl()

    if module && function_exported?(module, :update_github, 3),
      do: module.update_github(group_id, conversation_id, github),
      else: {:error, :task_stations_not_configured}
  end

  @spec terminal_urls(String.t(), [String.t()]) :: %{String.t() => String.t()}
  def terminal_urls(_group_id, []), do: %{}

  def terminal_urls(group_id, conversation_ids) when is_list(conversation_ids) do
    module = impl()

    if module && function_exported?(module, :terminal_urls, 2),
      do: module.terminal_urls(group_id, conversation_ids),
      else: %{}
  end

  @spec task_status(String.t(), String.t(), String.t()) :: :ok
  def task_status(group_id, conversation_id, status) do
    case impl() do
      nil -> :ok
      module -> module.task_status(group_id, conversation_id, status)
    end
  end

  @spec moved(map()) :: :ok | {:error, term()}
  def moved(move) when is_map(move) do
    case impl() do
      nil ->
        {:error, :task_stations_not_configured}

      module ->
        if function_exported?(module, :moved, 1),
          do: module.moved(move),
          else: {:error, :task_run_unsupported}
    end
  end

  @spec sessions(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def sessions(group_id, conversation_id) do
    case impl() do
      nil ->
        {:ok, %{}}

      module ->
        if function_exported?(module, :sessions, 2),
          do: module.sessions(group_id, conversation_id),
          else: {:ok, %{}}
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
