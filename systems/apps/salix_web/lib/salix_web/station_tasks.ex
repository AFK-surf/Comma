defmodule SalixWeb.StationTasks do
  require SystemsRuntime.Proc

  @moduledoc """
  Salix as the Station a Task is kept on, for the Sessions of other stations
  taking part in it (`systems/station/docs/tasks.md`): the same requests
  as between any two stations, over the device's connector connection.

    * `invite/1` (`task.invite`): asks the station to start a Session for the
      Task, before the Task is made. Answered at once: the Session, or why not
      (not connected, cannot run the model). Nothing is written into the Task.
      The Group's Cloud VM whose Workload is not `ready` (archived, waking,
      not made yet, or its station not connected) is not asked: it answers
      `when_connected`, and the Task is made for it all the same.
      With `replace` (the Task now runs another model there), the station's
      new Session takes the place of those it had in the Task.
    * `moved/1`: the Task now runs elsewhere (`SalixIM.TaskRun`). Each station
      that took part and does not run it now is told (`task.leave`, best
      effort: one not connected is not told) and given nothing more; the
      station that runs it now, if one does, takes part with its new Session
      and is given the Task from its start.
    * `joined/1`: the Session takes part (`SalixStore.StationTaskSessions`,
      `sent` 0) and is given the Task. With no Session (`when_connected`), the
      station is expected in the Task: given it as any station is, which asks
      for its VM's wake (below), and invited with its `start` once the VM is
      ready and it is connected (its hello, or the VM's `vm_ready/2`), its
      Session then taking part; the first giving follows at once.
    * `give/3` (`task.put`): the Messages after `sent`, a part at a time, until
      the station has all. Given when a Message is added (`appended/2`), when
      Salix starts (`give_all/0`) and when the station says hello. A station
      that is not connected is not asked again: it says hello when it is. The
      Group's Cloud VM comes back only when Salix wakes it, so its wake is
      asked for then, once for each giving, as work for the VM asks
      (`SalixWeb.CloudVM.RuntimeLifecycle.wake/1`). One
      that was asked but did not answer is given again after 1 s, 2 s, 4 s… at
      most a minute, until it has it; a new Message or its hello gives at once.
      A station that has no thread of the Task (it lost it) answers `unknown`:
      it is invited again with the `start` it was first invited with, its new
      Session takes the place of the old, and it is given the Task from its
      start. That invite says through which Message its Sessions answered the
      Task already (`answered`: the seq of the last Message one of them ended
      a turn with), so it answers nothing again; each Message its Sessions
      posted, the old one's too, is given as its own. One whose Sessions of
      it ended answers `gone`: it is given nothing more.
    * `post/2` (`task.post`): a Message of the station's Session, written as the
      Task's Worker (who is delivered nothing), once per `key`; its seq. Its
      `milestones` become the Message's `milestone` blocks
      (`SalixIM.ConversationMilestone`); a Message of milestones alone has no
      text. `task.put` gives a Message's milestones back the same way. A post
      that ends a coding Task's turn has its sandbox's facts read
      (`SalixWeb.CodingSandboxes.turn_ended/2`).
    * `file/2` (`task.file`): a part of a file of a Message the station's
      Session was given (`files` with the Message: each by its part's index,
      its name and size); the station fetches it into the Session's uploads,
      a part at a time, before the Session hears the Message.
    * `session_status/2` (`task.status`): where the station's Session of the
      Task stands (running, waiting, idle, cannot start, gone), for the
      Task's `SalixIM.StationTaskWatch`; a read that starts nothing there.
    * `sandbox/1`, `task_status/3`: a coding Task's sandbox, reserved before
      the Task is made and given up when it ends (`SalixWeb.CodingSandboxes`),
      whose station is invited once it connects. Giving to a stopped sandbox
      makes a new one, as giving to the Cloud VM wakes it.
    * `app_deploy/2` (`task.app_deploy`), `app_logs/2` (`task.app_logs`): the
      Session of a Mini App build Task deploys a preview Version of its app,
      or reads its backend's recent logs, from the Task's current sandbox.
    * `ask/4`: a request about the station's Session of a coding Task
      (`task.diff`, `task.pull_request`, `task.save`).
    * `hello/2` (`task.hello`): the station connected; it is given what it
      missed, and told to leave (`task.leave`) each Task it names that it no
      longer takes part in (one that moved while it was not connected). With `tasks` (`[{task, fetched}]`, how far it has each), from
      there: one it has less of than it was given is given the rest again, one
      it does not name it has none of (its put answers `unknown`). Without (a
      station from before `tasks`), from what it was given.
  """

  @behaviour SalixIM.Ports.TaskStations

  require Logger
  require SystemsClock

  alias SalixStore.StationTaskSessions

  @put_limit 100
  @put_timeout_ms 30_000
  @invite_timeout_ms 60_000
  @status_timeout_ms 10_000
  @last_failure_chars 200
  @session_states %{
    "running" => :running,
    "waiting" => :waiting,
    "idle" => :idle,
    "cannot_start" => :cannot_start,
    "gone" => :gone
  }
  @put_again_max_ms 60_000
  # Bytes one `task.file` answers at most (the station's FILE_PART).
  @file_part 256 * 1024
  # The files one post may name: how many, and their bytes together.
  @max_post_files 20
  @max_post_bytes 1024 * 1024 * 1024
  @file_types ~w(file image)
  @max_text_bytes 64 * 1024
  # The files of a Mini App deploy (`task.app_deploy`), by name: what each is
  # to the app's owner, and the most bytes it may have. The owner checks the
  # bundle's contents (index.html at most 8 MiB, 25 MiB and 2,000 files in all)
  # and the backend's compressed size (3 MiB); the tar of a full bundle is a
  # little larger than its files.
  @app_files %{
    "comma-app.json" => {:manifest, 64 * 1024},
    "bundle.tar" => {:bundle, 28 * 1024 * 1024},
    "source.tar.gz" => {:source, 50 * 1024 * 1024},
    "worker.js" => {:worker, 10 * 1024 * 1024}
  }
  @max_notes_chars 2_000
  @declared ~w(all_done need_help waiting)
  @ended_turn ~w(all_done need_help)

  @doc """
  Asks the station `device_id` to start a Session for Task `conversation_id`.
  `{:ok, session}`, or why not: `:device_offline`, or the station's refusal.
  The Group's Cloud VM whose Workload is not `ready`, or whose station is
  not connected, is `{:ok, :when_connected}`: Salix wakes it, and it is
  invited once it is up (`joined/1`, `vm_ready/2`).
  """
  @impl SalixIM.Ports.TaskStations
  def invite(%{tenant_id: tenant, group_id: group, device_id: device} = invitation) do
    with :ok <- SalixStore.ComputeStation.admit_device(tenant, group, device),
         {:ok, start} <- start(invitation),
         :up <- cloud_vm_up(group, device) do
      ask_invite(
        tenant,
        group,
        device,
        invitation.conversation_id,
        start,
        invitation[:answered] || 0,
        invitation[:replace] == true
      )
    end
  end

  # A Task on a Group Station that names no model runs the platform's
  # worker model, which Salix lends that station for Codex
  # (`SalixWeb.StationLLM`), as a Worker inside Salix would. Another station,
  # a coding sandbox among them, runs its runtime's own default: a sandbox
  # runs on the subscription lent to it, which may not serve the platform's
  # model.
  defp start(%{start: start, group_id: group, device_id: device}) do
    group_station? = group_station?(group, device)

    case {group_station? and blank?(start["model"]), start["runtime"], SalixWeb.StationLLM.tier()} do
      {false, _runtime, _tier} ->
        {:ok, start}

      {true, runtime, {:ok, tier}} when runtime in [nil, "", "codex"] ->
        {:ok, Map.merge(start, %{"runtime" => "codex", "model" => tier["model"]})}

      {true, "claude", {:ok, _tier}} ->
        {:ok, start}

      {true, _runtime, _no_tier} ->
        {:ok, start}
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp group_station?(group, device) do
    tenant = SalixStore.Ids.tenant_id_from_group!(group)

    case SalixStore.ComputeStation.device_owner(tenant, group, device) do
      {_kind, %{"owner" => owner}} when owner in ["group_default", "group_station"] -> true
      :unmanaged -> device == SalixStore.RuntimeIds.cloud_vm_device_id(group)
      _ -> false
    end
  end

  defp ask_invite(tenant, group, device, conversation, start, answered, replace) do
    case admitted_run(tenant, group, device) do
      {:error, :device_offline} ->
        not_connected(group, device)

      {:error, _} = error ->
        error

      {:ok, run_id} ->
        params =
          %{"task" => conversation, "start" => start}
          |> put_answered(answered)
          |> then(&if(replace, do: Map.put(&1, "replace", true), else: &1))

        case connector().request(run_id, "task.invite", params, timeout: @invite_timeout_ms) do
          {:ok, %{"session" => session}} when is_binary(session) and session != "" ->
            {:ok, session}

          {:ok, _answer} ->
            {:error, {:station_refused, "the station started no Session"}}

          {:error, :disconnected} ->
            not_connected(group, device)

          {:error, reason} when is_binary(reason) ->
            {:error, {:station_refused, reason}}

          {:error, reason} ->
            {:error, {:station_invite_unknown, reason}}
        end
    end
  end

  # The Group's Cloud VM takes a Task once its Workload is `ready`: a wake's
  # Container restores the archive and then starts its station, and while
  # the VM wakes the device record may still show the Container before as
  # connected. Until the VM is ready, its station is not asked: it is invited
  # when the VM is ready (`vm_ready/2`). A Group with no Workload record has
  # nothing waking: its station, when connected, is up. Another station is
  # up when connected.
  defp cloud_vm_up(group, device) do
    if device == SalixStore.RuntimeIds.cloud_vm_device_id(group) do
      case SalixStore.Compute.group_workload(group) do
        {:ok, %{"status" => status}} when status != "ready" -> {:ok, :when_connected}
        _ -> :up
      end
    else
      :up
    end
  end

  # A person's station comes back when its person opens the laptop: a Task
  # for it is not made. The Group's Cloud VM comes back when Salix wakes it:
  # the Task is made, and the station invited when it connects.
  defp not_connected(group, device) do
    if device == SalixStore.RuntimeIds.cloud_vm_device_id(group),
      do: {:ok, :when_connected},
      else: {:error, :device_offline}
  end

  @doc """
  The station's Session takes part in the Task from now on, and is given it
  from its start. With no Session, the station is expected: it is given the
  Task as any station is (its VM woken), and invited once it is connected.
  """
  @impl SalixIM.Ports.TaskStations
  def joined(%{session: nil} = row) do
    with :ok <- StationTaskSessions.expect(row) do
      give(row.group_id, row.conversation_id, row.device_id)
      :ok
    end
  end

  def joined(row) do
    with :ok <- StationTaskSessions.join(row) do
      give(row.group_id, row.conversation_id, row.device_id)
      :ok
    end
  end

  @doc "Reserves a coding Task's sandbox (`SalixWeb.CodingSandboxes.reserve/1`)."
  @impl SalixIM.Ports.TaskStations
  def sandbox(reservation), do: SalixWeb.CodingSandboxes.reserve(reservation)

  @impl SalixIM.Ports.TaskStations
  def update_github(group, conversation, github),
    do: SalixWeb.CodingSandboxes.update_github(group, conversation, github)

  @doc "Coding Tasks' terminal links (`SalixWeb.CodingSandboxes.terminal_urls/2`)."
  @impl SalixIM.Ports.TaskStations
  def terminal_urls(group, conversations),
    do: SalixWeb.CodingSandboxes.terminal_urls(group, conversations)

  @doc "A coding Task's status changed (`SalixWeb.CodingSandboxes.task_status/3`)."
  @impl SalixIM.Ports.TaskStations
  def task_status(group, conversation, status),
    do: SalixWeb.CodingSandboxes.task_status(group, conversation, status)

  @doc "Task `conversation`'s status now: `{:ok, status}`, or an error when it cannot be read."
  def current_status(group, conversation), do: conversations().status(group, conversation)

  @doc "Task `conversation`'s owner: `{:ok, user_id}`, or an error when it has none or cannot be read."
  def owner(group, conversation), do: conversations().owner(group, conversation)

  @doc """
  Asks the station taking part in Task `conversation` `method` about its
  Session (`params` plus `task` and `session`), within `timeout` ms.
  `{:error, :not_connected}` when its station is not connected now.
  """
  def ask(group, conversation, method, params, timeout \\ @status_timeout_ms) do
    with {:ok, [_ | _] = rows} <- StationTaskSessions.of_task(group, conversation),
         %{tenant_id: tenant, device_id: device, session: session} <- Enum.min_by(rows, & &1.sent),
         {:ok, run_id} <- admitted_run(tenant, group, device) do
      params = Map.merge(params, %{"task" => conversation, "session" => session})

      case connector().request(run_id, method, params, timeout: timeout) do
        {:ok, answer} when is_map(answer) -> {:ok, answer}
        {:ok, _answer} -> {:error, :bad_answer}
        {:error, :disconnected} -> {:error, :not_connected}
        {:error, reason} -> {:error, {:station, reason(reason)}}
      end
    else
      {:ok, []} -> {:error, :not_station}
      {:error, _} = error -> error
    end
  end

  @doc """
  Writes `text` into Task `conversation` as its Worker, as the station's
  Session would, for what Salix says about the Task's sandbox. Once per `key`.
  """
  def notice(group, conversation, agent_id, key, text) do
    row = %{conversation_id: conversation, agent_id: agent_id}

    with {:ok, participant_id} <- worker(group, row) do
      conversations().append(group, conversation, agent_id, %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => agent_id,
        "participant_id" => participant_id,
        "content" => truncate(text),
        "client_request_id" => "sandbox-notice:" <> digest([conversation, key]),
        "metadata" => %{"kind" => "sandbox_notice"}
      })
    end
  end

  @doc """
  The Task now runs elsewhere: the stations that took part leave it, those
  that do not run it now told so; `to` (the row `joined/1` takes, or nil when
  it runs inside Salix now) takes part and is given the Task from its start.
  """
  @impl SalixIM.Ports.TaskStations
  def moved(%{group_id: group, conversation_id: conversation} = move) do
    to = move[:to]

    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation) do
      rows
      |> Enum.map(&{&1.tenant_id, &1.device_id})
      |> Enum.uniq()
      |> Enum.each(fn {tenant, device} ->
        StationTaskSessions.leave(group, conversation, device)

        if is_nil(to) or to.device_id != device,
          do: tell_left(tenant, group, conversation, device)
      end)

      if is_nil(to), do: :ok, else: joined(to)
    end
  end

  @doc "The Sessions of stations taking part in the Task, by device."
  @impl SalixIM.Ports.TaskStations
  def sessions(group, conversation) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation),
         do: {:ok, Map.new(rows, &{&1.device_id, &1.session})}
  end

  # Best effort: a station not connected now is not told, and is given
  # nothing more of the Task all the same.
  defp tell_left(tenant, group, conversation, device) do
    with run_id when is_binary(run_id) <- online_run(tenant, group, device),
         {:ok, _answer} <-
           connector().request(run_id, "task.leave", %{"task" => conversation},
             timeout: @status_timeout_ms
           ) do
      :ok
    else
      other ->
        Logger.info(
          "a station that no longer runs a Task was not told: group=#{group} task=#{conversation} device=#{device} #{inspect(other)}"
        )

        :ok
    end
  end

  @doc "A Message was added to the Task: the stations taking part are given it. Never waits for them."
  @impl SalixIM.Ports.TaskStations
  def appended(group, conversation) do
    SystemsRuntime.TaskSupervisor.start_child(SalixWeb.StationTasks.Supervisor, fn ->
      case StationTaskSessions.of_task(group, conversation) do
        # A coding Task whose sandbox's station never took it: the Message
        # asks for a sandbox that will.
        {:ok, []} ->
          SalixWeb.CodingSandboxes.appended(group, conversation)

        {:ok, rows} ->
          rows
          |> Enum.map(& &1.device_id)
          |> Enum.uniq()
          |> Enum.each(&give(group, conversation, &1))

        {:error, reason} ->
          Logger.warning("station task sessions not read: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc """
  Where the station taking part in the Task stands, for the Task's
  `SalixIM.StationTaskWatch`: one read of its participation, one of its device
  record and, for the Group's Cloud VM, one of the Group's Workload.
  `:not_station` when none takes part; `{:error, reason}` when one of the
  reads failed, to be asked again.
  """
  @impl SalixIM.Ports.TaskStations
  def standing(group, conversation) do
    with {:ok, [_ | _] = rows} <- StationTaskSessions.of_task(group, conversation) do
      # One station runs a Task; were there more, the one given the least is
      # the one the Task waits on.
      %{tenant_id: tenant, device_id: device, sent: sent} = Enum.min_by(rows, & &1.sent)

      place =
        cond do
          device == SalixStore.RuntimeIds.cloud_vm_device_id(group) -> :cloud_vm
          SalixStore.CodingSandboxes.device?(device) -> :sandbox
          true -> :device
        end

      with {:ok, vm_status} <- place_status(place, tenant, group, device) do
        {:ok,
         %{
           place: place,
           connected?: online_run(tenant, group, device) != nil,
           sent: sent,
           vm_status: vm_status
         }}
      end
    else
      {:ok, []} -> :not_station
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Where the station's Session of the Task stands, for the Task's
  `SalixIM.StationTaskWatch` once the station has the delegation: one
  `task.status` request, which starts nothing there. `:unknown` when no
  station takes part, the station is not connected, it does not answer in
  #{@status_timeout_ms} ms, or it does not know the request (a station from
  before it).
  """
  @impl SalixIM.Ports.TaskStations
  def session_status(group, conversation) do
    with {:ok, [_ | _] = rows} <- StationTaskSessions.of_task(group, conversation),
         %{tenant_id: tenant, device_id: device, session: session} = row <-
           Enum.min_by(rows, & &1.sent),
         false <- StationTaskSessions.awaited?(row),
         {:ok, run_id} <- admitted_run(tenant, group, device) do
      params = %{"task" => conversation, "session" => session}

      case connector().request(run_id, "task.status", params, timeout: @status_timeout_ms) do
        {:ok, %{"state" => state} = answer} when is_map_key(@session_states, state) ->
          {:ok,
           %{
             state: Map.fetch!(@session_states, state),
             pending:
               if(is_integer(answer["pending"]) and answer["pending"] >= 0,
                 do: answer["pending"],
                 else: 0
               ),
             for_ms:
               if(is_integer(answer["for_ms"]) and answer["for_ms"] >= 0, do: answer["for_ms"]),
             last_failure: last_failure(answer["last_failure"]),
             # A coding Task's worktree: uncommitted changes, commits not pushed.
             dirty: answer["dirty"] == true,
             unpushed: answer["unpushed"] == true
           }}

        {:ok, _answer} ->
          :unknown

        {:error, reason} ->
          Logger.info(
            "a station was not asked where its Session of a Task stands: group=#{group} task=#{conversation} device=#{device} #{inspect(reason)}"
          )

          :unknown
      end
    else
      _ -> :unknown
    end
  end

  defp last_failure(text) when is_binary(text) and text != "",
    do: text |> String.slice(0, @last_failure_chars) |> String.trim()

  defp last_failure(_text), do: nil

  defp place_status(:cloud_vm, _tenant, group, _device), do: vm_status(group)

  # A coding Task's sandbox state (`starting`, `ready`, `stopped`…).
  defp place_status(:sandbox, tenant, _group, device) do
    case SalixStore.CodingSandboxes.get_by_device(tenant, device) do
      {:ok, workload} -> {:ok, workload.spec["state"]}
      {:error, :not_found} -> {:ok, nil}
    end
  end

  defp place_status(:device, _tenant, _group, _device), do: {:ok, nil}

  # The Group's Cloud VM Workload status (`ready`, `waking`, `archived`…); nil
  # when the Group has no Cloud VM Workload at all. A Workload that cannot be
  # read now is an error, not a status.
  defp vm_status(group) do
    case SalixStore.Compute.group_workload(group) do
      {:ok, %{"status" => status}} when is_binary(status) and status != "" -> {:ok, status}
      {:ok, _workload} -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @doc "Salix started: every station taking part in a Task is given what it has not had."
  def give_all do
    case StationTaskSessions.all() do
      {:ok, rows} ->
        rows
        |> Enum.map(&{&1.group_id, &1.conversation_id, &1.device_id})
        |> Enum.uniq()
        |> Enum.each(fn {group, conversation, device} -> give(group, conversation, device) end)

      {:error, reason} ->
        Logger.warning("station task sessions not read: #{inspect(reason)}")
    end

    :ok
  end

  @doc "`task.hello` from the device of `view`: it is given what it missed of every Task it takes part in."
  def hello(%{tenant_id: tenant, group_id: group, device_id: device}, params) do
    with :ok <- give_device(tenant, group, device, had(params)), do: {:ok, %{}}
  end

  @doc """
  The Group's Cloud VM Workload became `ready` (`previous` to `committed`,
  as its provider committed it): its station is invited to the Tasks it is
  expected in and given what waits for it. Its hello came while the VM was
  still waking, when it was not asked (`invite/1`). Any other write is
  nothing to the stations.
  """
  def vm_ready(
        %{"status" => was},
        %{"status" => "ready", "tenant_id" => tenant, "group_id" => group, "device_id" => device}
      )
      when was != "ready" and is_binary(device) do
    _ = give_device(tenant, group, device, nil)
    :ok
  end

  def vm_ready(_previous, _committed), do: :ok

  # The station `device` is given what it missed of every Task it takes part
  # in; with `had` (how far it has each Task), from there.
  defp give_device(tenant, group, device, had) do
    case StationTaskSessions.of_device(tenant, group, device) do
      {:ok, rows} ->
        taking = rows |> Enum.map(& &1.conversation_id) |> MapSet.new()

        # A Task it names that runs elsewhere now (it was not connected when the
        # Task moved, `moved/1`): its Sessions there leave it. A station names
        # only Tasks its Sessions still take part in, so it is told once. One it
        # was given nothing of yet may be one it is being invited to, not yet
        # recorded here: it has nothing to run, and is left alone.
        for {task, fetched} <- had || %{},
            fetched > 0 and not MapSet.member?(taking, task) do
          SystemsRuntime.TaskSupervisor.start_child(SalixWeb.StationTasks.Supervisor, fn ->
            tell_left(tenant, group, task, device)
          end)
        end

        taking
        |> Enum.each(fn conversation ->
          if had,
            do:
              StationTaskSessions.fetched(
                group,
                conversation,
                device,
                Map.get(had, conversation, 0)
              )

          give(group, conversation, device)
        end)

        :ok

      {:error, reason} ->
        Logger.warning("station task sessions not read: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # How far the station has each Task it names; nil when it names none at all
  # (a station from before `tasks`).
  defp had(%{"tasks" => tasks}) when is_list(tasks) do
    for %{"task" => task, "fetched" => fetched} <- tasks,
        is_binary(task) and is_integer(fetched) and fetched >= 0,
        into: %{},
        do: {task, fetched}
  end

  defp had(_params), do: nil

  @doc """
  Gives `device` the Messages of the Task it has not had. One giver at a time
  for each Task and station on this node; asked meanwhile, it gives once more
  (or at once, while it waits to give again).
  """
  def give(group, conversation, device) do
    key = {group, conversation, device}

    case SystemsRuntime.Registry.lookup(SalixWeb.StationTasks.Registry, key) do
      [{pid, _}] ->
        SystemsRuntime.Proc.send(pid, :give)

      [] ->
        SystemsRuntime.TaskSupervisor.start_child(SalixWeb.StationTasks.Supervisor, fn ->
          giver(key)
        end)
    end

    :ok
  end

  defp giver(key) do
    case SystemsRuntime.Registry.register(SalixWeb.StationTasks.Registry, key, nil) do
      {:ok, _} ->
        giving(key, 0)
        SystemsRuntime.Registry.unregister(SalixWeb.StationTasks.Registry, key)

        # Asked between the last look and letting go: given once more.
        SystemsRuntime.Proc.receive do
          :give -> giver(key)
        after
          0 -> :ok
        end

      {:error, {:already_registered, pid}} ->
        SystemsRuntime.Proc.send(pid, :give)
    end
  end

  defp giving(key, failures) do
    {group, conversation, device} = key

    case give_now(group, conversation, device, false) do
      result when result in [:ok, :unreachable] ->
        # Not connected (:unreachable): it says hello when it is.
        if result == :unreachable, do: wake(group, conversation, device)

        SystemsRuntime.Proc.receive do
          :give -> giving(key, 0)
        after
          0 -> :ok
        end

      {:error, reason} ->
        wait = min(@put_again_max_ms, 1_000 * Integer.pow(2, failures))

        Logger.warning(
          "a station taking part in a Task did not take what it was given; given again in #{wait} ms: #{inspect(reason)}"
        )

        SystemsClock.vreceive do
          :give -> :ok
        after
          wait -> :ok
        end

        giving(key, failures + 1)
    end
  end

  # A person's station comes back by itself. The Group's Cloud VM, archived or
  # stopped, comes back only when Salix, its control plane, wakes it: the
  # station that has something to take is the work that wakes it, asked as
  # other work for the VM is. Which device that is, the Group's Workload says;
  # a Group whose VM was never made has none, and the Cloud VM's station with
  # a Task to take asks for the VM to be made, as its Worker running a command
  # there would (`SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning/1`).
  # The VM's station then says hello and is given the Task. A wake already on
  # its way is the same wake; one that cannot be made is said once, and asked
  # again only when the station is next given something.
  defp wake(group, conversation, device) do
    tenant = SalixStore.Ids.tenant_id_from_group!(group)

    case SalixStore.ComputeStation.device_owner(tenant, group, device) do
      {:workload, %{"owner" => "coding_task"}} -> SalixWeb.CodingSandboxes.wake(group, device)
      _ -> wake_cloud_vm(group, conversation, device)
    end
  end

  # The Group's Cloud VM (`group_default`) is woken; a Group whose VM was
  # never made (`:none`) has it made for the Task's Worker; a Group Station
  # Workload on the Host is started by `wake_device` itself.
  defp wake_cloud_vm(group, conversation, device) do
    tenant = SalixStore.Ids.tenant_id_from_group!(group)

    result =
      case SalixStore.ComputeGroupStation.wake_device(tenant, group, device) do
        :group_default ->
          SalixWeb.CloudVM.RuntimeLifecycle.wake(group)

        :none ->
          if device == SalixStore.RuntimeIds.cloud_vm_device_id(group),
            do: make_vm(group, conversation),
            else: :ok

        other ->
          other
      end

    with {:error, reason} when reason != :runtime_waking <- result do
      Logger.warning(
        "the Cloud VM of a station with a Task to take was not woken; asked again when it is next given something: group=#{group} device=#{device} #{inspect(reason)}"
      )
    end

    :ok
  end

  # The Group's VM is made for the Task's Worker, when the Group's Cloud VM
  # switch lets it (`SalixAgent.CloudVM.allowed?/1`); the Compute reconciler
  # carries the creation out.
  defp make_vm(group, conversation) do
    with {:ok, [%{agent_id: agent_id} | _]} <- StationTaskSessions.of_task(group, conversation),
         {:ok, %{"group_id" => ^group} = agent} <- SalixAgent.Control.get_record(agent_id),
         true <- SalixAgent.CloudVM.allowed?(agent) || {:error, :cloud_vm_disabled},
         {:ok, _record} <- SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent) do
      :ok
    else
      {:ok, _} -> {:error, :no_station_worker}
      {:error, _reason} = error -> error
    end
  end

  # `invited_again`: the station was invited again in this giving already.
  defp give_now(group, conversation, device, invited_again) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation),
         [_ | _] = rows <- Enum.filter(rows, &(&1.device_id == device)),
         false <- Enum.all?(rows, &StationTaskSessions.awaited?/1) do
      sent = rows |> Enum.map(& &1.sent) |> Enum.min()
      %{tenant_id: tenant} = hd(rows)

      with {:ok, answered} <- answered(rows, group, conversation, device),
           {:ok, messages} <-
             conversations().messages_after(group, conversation, sent, @put_limit) do
        put(rows, tenant, group, conversation, device, {sent, answered}, messages, invited_again)
      else
        # The Task is no more: there is nothing to give of it.
        {:error, reason}
        when reason == :not_found or (is_tuple(reason) and elem(reason, 0) == :bad_request) ->
          Logger.info(
            "a Task given to a station is no more: group=#{group} task=#{conversation} device=#{device} #{inspect(reason)}"
          )

          StationTaskSessions.leave(group, conversation, device)

        {:error, _} = error ->
          error
      end
    else
      [] ->
        :ok

      # Expected in the Task, with no Session of it yet: invited now that it
      # is connected, and given the Task from its start.
      true ->
        with :ok <- invite_expected(group, conversation, device),
             do: give_now(group, conversation, device, true)

      {:error, _} = error ->
        error
    end
  end

  # The station expected in the Task is invited with the `start` the Task was
  # made with (`SalixIM.TaskConversationInput.station_start/2`), and its
  # Session takes the expected row's place. Not connected after all, it is
  # invited when it says hello. One that refuses the Task runs no Session of
  # it: it is expected no more, and the Task's watch tells the Router
  # (`SalixIM.StationTaskWatch`, `station_left`).
  defp invite_expected(group, conversation, device) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation),
         %{} = row <- Enum.find(rows, &(&1.device_id == device)) do
      start = start_of(row)

      case invite(%{
             tenant_id: row.tenant_id,
             group_id: group,
             conversation_id: conversation,
             device_id: device,
             start: start
           }) do
        {:ok, session} when is_binary(session) ->
          Logger.info(
            "a station expected in a Task was invited to it: group=#{group} task=#{conversation} device=#{device} session=#{session}"
          )

          StationTaskSessions.rejoin(row, session, start, 0)

        {:ok, :when_connected} ->
          :unreachable

        {:error, :device_offline} ->
          :unreachable

        {:error, {:station_refused, why}} ->
          Logger.warning(
            "a station expected in a Task did not take it; it is expected no more: group=#{group} task=#{conversation} device=#{device} #{why}"
          )

          StationTaskSessions.leave(group, conversation, device)

        {:error, _} = error ->
          error
      end
    else
      nil -> :ok
      {:error, _} = error -> error
    end
  end

  defp put(_rows, _tenant, _group, _conversation, _device, _sent, [], _again), do: :ok

  defp put(rows, tenant, group, conversation, device, {sent, answered}, messages, invited_again) do
    through = Enum.reduce(messages, sent, &max(&1["seq"], &2))

    # `answered`: with all that the station is given, through which Message its
    # Sessions answered the Task already. It hands none of those to a Session.
    params =
      %{
        "task" => conversation,
        "messages" => Enum.map(messages, &message(&1, device)),
        "through" => through
      }
      |> put_answered(answered)

    case admitted_run(tenant, group, device) do
      {:error, :device_offline} ->
        :unreachable

      {:error, reason} ->
        {:error, reason}

      {:ok, run_id} ->
        case connector().request(run_id, "task.put", params, timeout: @put_timeout_ms) do
          # Still unknown once invited again: not answering as it should, given again later.
          {:ok, %{"unknown" => true}} when invited_again ->
            {:error, :unknown_after_invite}

          {:ok, %{"unknown" => true}} ->
            with :ok <- invite_again(Enum.find(rows, &is_map(&1.start)) || hd(rows), answered),
                 do: give_now(group, conversation, device, true)

          {:ok, %{"gone" => true}} ->
            # Its Sessions of the Task are no more: nothing is given to it again.
            Logger.info(
              "station no longer takes part in a Task, it said: group=#{group} task=#{conversation} device=#{device}"
            )

            StationTaskSessions.leave(group, conversation, device)

          {:ok, _answer} ->
            station_activity(group, device)

            with :ok <- StationTaskSessions.sent(group, conversation, device, through),
                 do: give_now(group, conversation, device, invited_again)

          {:error, :disconnected} ->
            :unreachable

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # The station has no thread of the Task (it lost it): it is invited again as
  # it was first, told through which Message its Sessions answered the Task
  # already, and its new Session takes the place of the old, given nothing
  # yet. Not connected, it says hello when it is.
  defp invite_again(row, answered) do
    start = start_of(row)

    invitation = %{
      tenant_id: row.tenant_id,
      group_id: row.group_id,
      conversation_id: row.conversation_id,
      device_id: row.device_id,
      start: start,
      answered: answered
    }

    case invite(invitation) do
      {:ok, session} ->
        Logger.info(
          "a station that lost a Task was invited to it again: group=#{row.group_id} task=#{row.conversation_id} device=#{row.device_id} session=#{session}"
        )

        StationTaskSessions.rejoin(row, session, start, answered)

      {:error, :device_offline} ->
        :unreachable

      {:error, _} = error ->
        error
    end
  end

  # What the station was first invited with (kept with its Session; for those
  # invited before it was kept, `SalixWeb.Migrations.StationTaskStarts` kept
  # it). None kept: the Task's Worker asks, and the station runs its default
  # runtime and model.
  defp start_of(%{start: %{} = start}), do: start

  defp start_of(%{agent_id: agent_id}),
    do: SalixIM.TaskConversationInput.station_start(agent_id, nil)

  # Through which Message the Sessions of the station `device` answered the
  # Task already. Kept with them as their posts arrive (`post/2`); for those
  # from before it was kept, the Task is read for it once, and it is kept.
  defp answered(rows, group, conversation, device) do
    kept = rows |> Enum.map(&(&1.answered || 0)) |> Enum.max()

    if Enum.any?(rows, &is_nil(&1.answered)) do
      with {:ok, read} <- read_answered(group, conversation, device, 0, 0),
           :ok <- StationTaskSessions.answered(group, conversation, device, max(read, kept)),
           do: {:ok, max(read, kept)}
    else
      {:ok, kept}
    end
  end

  # The seq of the last Message a Session of the station `device` ended a turn
  # with in the Task (it declared all_done or need_help); 0 when none did.
  # Messages are kept by seq alone, so the Task is read from its start, a part
  # at a time as it is given.
  defp read_answered(group, conversation, device, after_seq, last) do
    case conversations().messages_after(group, conversation, after_seq, @put_limit) do
      {:ok, []} ->
        {:ok, last}

      {:ok, messages} ->
        through = Enum.reduce(messages, after_seq, &max(&1["seq"], &2))

        last =
          Enum.reduce(messages, last, fn message, last ->
            metadata = message["metadata"] || %{}

            if message["actor_type"] == "agent" and metadata["device_id"] == device and
                 is_binary(metadata["session"]) and metadata["declared"] in @ended_turn,
               do: max(message["seq"], last),
               else: last
          end)

        read_answered(group, conversation, device, through, last)

      {:error, _} = error ->
        error
    end
  end

  # A Message as the station is given it. `author.session`: the Session of
  # that station that posted it, one taking part now or one a Session of it
  # took the place of since (it lost the Task and was invited again): the
  # station keeps it as its Session's own, with what it declared.
  defp message(message, device) do
    metadata = message["metadata"] || %{}

    author =
      case message do
        %{"actor_type" => "agent", "agent_id" => agent_id} ->
          own = metadata["device_id"] == device and is_binary(metadata["session"])

          if own,
            do: %{"kind" => "agent", "id" => agent_id, "session" => metadata["session"]},
            else: %{"kind" => "agent", "id" => agent_id}

        %{"actor_type" => "user", "user_id" => user_id} when is_binary(user_id) ->
          %{"kind" => "person", "id" => user_id}

        _ ->
          %{"kind" => "ember", "id" => message["actor_type"] || "salix"}
      end

    %{
      "seq" => message["seq"],
      "author" => author,
      "text" => message_text(message),
      "declared" => metadata["declared"],
      "at" => message["created_at"]
    }
    |> put_present("id", message["message_id"])
    |> put_files(message)
    |> put_milestones(message["content"])
  end

  # Both sources are owner-bound. User content and metadata alone grant no read.
  defp file_source(%{"actor_type" => "agent", "agent_id" => agent_id, "content" => content})
       when is_binary(agent_id) and agent_id != "" and is_list(content),
       do: {agent_id, content}

  defp file_source(%{
         "actor_type" => "user",
         "owner_uploads" => %{"agent_id" => agent_id, "files" => files}
       })
       when is_binary(agent_id) and agent_id != "" and is_list(files),
       do: {agent_id, files}

  defp file_source(_message), do: {nil, []}

  # The runtime receives its local paths with the downloaded attachments.
  # Do not tell it that the Router's upload paths exist in its sandbox.
  defp message_text(%{"actor_type" => "user"} = message) do
    {_source, files} = file_source(message)

    Enum.reduce(files, text(message["content"]), fn file, words ->
      String.replace(
        words,
        "(workspace file: #{file["path"]})",
        "(attached file: #{file["file_name"]})"
      )
    end)
  end

  defp message_text(message), do: text(message["content"])

  defp put_files(given, message) do
    {_source, content} = file_source(message)

    files =
      content
      |> Enum.with_index()
      |> Enum.flat_map(fn {block, index} ->
        case file_block(block) do
          {:ok, size} ->
            [
              %{
                "index" => index,
                "name" => SalixIM.ConversationAttachments.file_name(block),
                "size" => size
              }
            ]

          :error ->
            []
        end
      end)

    if files == [], do: given, else: Map.put(given, "files", files)
  end

  defp file_block(%{"type" => type, "blob_ref" => %{"size" => size}})
       when type in @file_types and is_integer(size) and size >= 0,
       do: {:ok, size}

  defp file_block(_block), do: :error

  @doc """
  `task.file` from the device of `view`: a part of a file of a Message of the
  Task its Session takes part in, at most #{@file_part} bytes from `offset`
  (base64), with the file's name and size; `missing` when the Message brings
  no such file.
  """
  def file(view, params) when is_map(params) do
    with {:ok, row} <- taking_part(view, params),
         id when is_binary(id) and id != "" <- params["id"],
         index when is_integer(index) and index >= 0 <- params["index"],
         offset when is_integer(offset) and offset >= 0 <- params["offset"] do
      case conversations().message(view.group_id, row.conversation_id, id) do
        {:ok, message} ->
          {agent_id, content} = file_source(message)
          block = Enum.at(content, index)

          with {:ok, size} <- file_block(block),
               {:ok, data} <-
                 conversations().read_part(agent_id, block["blob_ref"], offset, @file_part) do
            {:ok,
             %{
               "name" => SalixIM.ConversationAttachments.file_name(block),
               "size" => size,
               "offset" => offset,
               "data" => Base.encode64(data)
             }}
          else
            :error -> {:ok, %{"missing" => "no such file"}}
            {:error, _} = error -> error
          end

        {:error, reason}
        when reason == :not_found or
               (is_tuple(reason) and elem(reason, 0) in [:not_found, :bad_request]) ->
          {:ok, %{"missing" => "no such Message"}}

        {:error, _} = error ->
          error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_request}
    end
  end

  def file(_view, _params), do: {:error, :bad_request}

  defp put_milestones(given, content) when is_list(content) do
    case for(
           %{"type" => "milestone", "title" => title} when is_binary(title) <- content,
           do: title
         ) do
      [] -> given
      titles -> Map.put(given, "milestones", titles)
    end
  end

  defp put_milestones(given, _content), do: given

  @doc "`task.post` from the device of `view`: a Message of its Session, once per `key`; its seq."
  def post(view, params) when is_map(params) do
    milestones = milestones_given(params["milestones"])

    with {:ok, row} <- taking_part(view, params),
         {:ok, files} <- files_given(params["files"]),
         text when is_binary(text) and (text != "" or milestones != [] or files != []) <-
           params["text"],
         key when is_binary(key) and key != "" and byte_size(key) <= 128 <- params["key"],
         {:ok, participant_id} <- worker(view.group_id, row),
         {:ok, file_blocks} <- stage_files(view, row, key, files) do
      declared = if params["declared"] in @declared, do: params["declared"]

      attrs = %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => row.agent_id,
        "participant_id" => participant_id,
        "content" => content(text, milestones, file_blocks),
        "client_request_id" => "station-task:" <> digest([view.device_id, row.session, key]),
        "metadata" =>
          %{"kind" => "station_task", "device_id" => view.device_id, "session" => row.session}
          |> put_present("declared", declared)
          |> put_cannot_start(params["cannot_start"])
      }

      # A post that ends a turn: its Session answered what the station had been
      # given by then.
      with {:ok, _answered} <- answered([row], view.group_id, row.conversation_id, view.device_id),
           {:ok, %{"seq" => seq}} <-
             conversations().append(view.group_id, row.conversation_id, row.agent_id, attrs) do
        # Appended, the Message is the station's work whether or not its turn ends well.
        station_activity(view.group_id, view.device_id)
        with :ok <- ended_turn(view, row, declared, seq), do: {:ok, %{"seq" => seq}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_request}
    end
  end

  def post(_view, _params), do: {:error, :bad_request}

  # The station's word that its Session's turn did not start (`cannot_start`,
  # why): the Message is a `task_run_blocked` one, which clients show with a way
  # to run the Task on another model (`SalixIM.TaskRun`).
  defp put_cannot_start(metadata, %{"error" => error}) when is_binary(error) and error != "",
    do:
      Map.merge(metadata, %{
        "message_type" => "task_run_blocked",
        "task_run_blocked" => %{"error" => String.slice(error, 0, @last_failure_chars)}
      })

  defp put_cannot_start(metadata, _cannot_start), do: metadata

  # The files a post names (`index`, `name`, `size` each): at most
  # #{@max_post_files}, and #{@max_post_bytes} bytes together.
  defp files_given(nil), do: {:ok, []}

  defp files_given(files) when is_list(files) and length(files) <= @max_post_files do
    given =
      Enum.map(files, fn
        %{"index" => index, "name" => name, "size" => size}
        when is_integer(index) and index >= 0 and is_binary(name) and is_integer(size) and
               size >= 0 ->
          case Path.basename(name) do
            base when base in ["", ".", ".."] or byte_size(base) > 255 -> nil
            base -> %{index: index, name: base, size: size}
          end

        _file ->
          nil
      end)

    cond do
      Enum.any?(given, &is_nil/1) ->
        {:error, :bad_request}

      given |> Enum.map(& &1.size) |> Enum.sum() > @max_post_bytes ->
        {:error, {:bad_request, "the files of one post are at most 1 GiB together"}}

      true ->
        {:ok, given}
    end
  end

  defp files_given(_files), do: {:error, :bad_request}

  # Reads each file the post names from the station (`task.posted_file`), a
  # part at a time, into a blob of the Task's Worker, and places it in the
  # Worker's VFS: the Message names them by path, as a Worker inside Salix
  # attaches its files. One that cannot be read fails the post, and the
  # station's Session is told.
  defp stage_files(_view, _row, _key, []), do: {:ok, []}

  defp stage_files(view, row, key, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, blocks} ->
      case stage_file(view, row, key, file) do
        {:ok, block} -> {:cont, {:ok, blocks ++ [block]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp stage_file(view, row, key, file) do
    path =
      "/uploads/tasks/#{row.conversation_id}/#{digest([row.session, key])}/#{file.index}-#{file.name}"

    state = conversations().blob_init(row.agent_id)

    with {:ok, state} <- pull(view, row, key, file, 0, state),
         {:ok, ref} <- conversations().blob_finish(state),
         :ok <- conversations().place(row.agent_id, path, ref) do
      # String keys, as the Message is read back from the store.
      blob_ref = Map.new(ref, fn {key, value} -> {to_string(key), value} end)
      {:ok, %{"type" => "file", "path" => path, "file_name" => file.name, "blob_ref" => blob_ref}}
    else
      {:error, reason, state} ->
        conversations().blob_abort(state)
        {:error, reason}

      {:error, _} = error ->
        error
    end
  end

  defp pull(_view, _row, _key, %{size: size}, offset, state) when offset >= size,
    do: {:ok, state}

  defp pull(view, row, key, file, offset, state) do
    with {:ok, part} <- pull_part(view, row, key, file, offset),
         {:ok, state} <- conversations().blob_step(state, part) do
      pull(view, row, key, file, offset + byte_size(part), state)
    else
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # One part of a file the station's Session names, from `offset`
  # (`task.posted_file`).
  defp pull_part(view, row, key, file, offset) do
    asked = %{
      "task" => row.conversation_id,
      "session" => row.session,
      "key" => key,
      "index" => file.index,
      "offset" => offset
    }

    with {:ok, %{"data" => data}} when is_binary(data) <-
           connector().request(view.connector_run_id, "task.posted_file", asked,
             timeout: @status_timeout_ms
           ),
         {:ok, part} when part != "" and offset + byte_size(part) <= file.size <-
           Base.decode64(data) do
      {:ok, part}
    else
      {:ok, %{"missing" => why}} -> {:error, {:bad_request, "#{file.name}: #{why}"}}
      {:error, reason} -> {:error, reason}
      _other -> {:error, {:bad_request, "#{file.name} did not come as it was named"}}
    end
  end

  @doc """
  `task.app_deploy` from the device of `view`: its Session deploys a preview
  Version of the app its Task builds (`mini_app`). Only the station of the
  Task's current sandbox may, over that sandbox generation's connection.
  The files the request names (#{inspect(Map.keys(@app_files))}) are read
  from the station a part at a time into temp files on this node, each
  within its size, for the app's owner (`SalixWeb.MiniAppDeploys.deploy/2`).
  The Version is written into the Task as a `mini_app` Message of its
  Worker, once per `key`: a deploy asked again with its key makes no second
  Version and no second Message.

  Answers the Version (`app_id`, `version`, `state`, `name`, `summary`), or
  `{"error": "invalid", "errors": [...]}`, or `{"error": reason, "message"}`.
  A request from a station that has no such authority is an error.
  """
  def app_deploy(view, params) when is_map(params) do
    with {:ok, row} <- taking_part(view, params),
         :ok <- sandbox_authority(view, row),
         {:ok, task} <- conversations().task(view.group_id, row.conversation_id) do
      with {:ok, app_id} <- task_app(task, params["app_id"]),
           {:ok, deploy} <- deploy_given(params),
           {:ok, files} <- app_files_given(params["files"]) do
        deploy_app(view, row, task, app_id, deploy, files)
      else
        {:refused, result} -> {:ok, result}
      end
    end
  end

  def app_deploy(_view, _params), do: {:error, :bad_request}

  @doc """
  `task.app_logs` from the device of `view`: recent backend log lines of the
  app its Task builds (or of its Version `version`), with the authority of
  `app_deploy/2`.
  """
  def app_logs(view, params) when is_map(params) do
    version = params["version"]

    with true <- is_nil(version) or (is_integer(version) and version > 0),
         {:ok, row} <- taking_part(view, params),
         :ok <- sandbox_authority(view, row),
         {:ok, task} <- conversations().task(view.group_id, row.conversation_id) do
      case task_app(task, params["app_id"]) do
        {:ok, app_id} ->
          case SalixWeb.MiniAppDeploys.logs(%{group_id: view.group_id, app_id: app_id}, version) do
            {:ok, lines} when is_list(lines) -> {:ok, %{"lines" => lines}}
            {:error, reason} -> {:ok, app_error(reason)}
          end

        {:refused, result} ->
          {:ok, result}
      end
    else
      false -> {:error, :bad_request}
      {:error, _} = error -> error
    end
  end

  def app_logs(_view, _params), do: {:error, :bad_request}

  # The station of the Task's own sandbox, over the connection of its current
  # Workload generation: a sandbox that was replaced has no authority
  # (`SalixEnv.StationConnection`), nor has any other station.
  defp sandbox_authority(view, row) do
    if view[:device_id] == SalixStore.CodingSandboxes.device_id(row.conversation_id) do
      case SalixEnv.StationConnection.authorize(view) do
        {:ok, %{"owner" => "coding_task"}} -> :ok
        {:ok, _other} -> {:error, :not_a_sandbox}
        {:error, _} = error -> error
      end
    else
      {:error, :not_a_sandbox}
    end
  end

  # The app the Task builds, which must be the one the Session names.
  defp task_app(%{"mini_app" => %{"app_id" => app_id}}, app_id) when is_binary(app_id),
    do: {:ok, app_id}

  defp task_app(%{"mini_app" => %{"app_id" => _other}}, _app_id),
    do:
      {:refused, refusal("app_mismatch", "this Task builds another app; deploy its app_id only")}

  defp task_app(_task, _app_id),
    do: {:refused, refusal("not_an_app_task", "this Task builds no app, so it cannot deploy one")}

  defp deploy_given(params) do
    key = params["key"]
    commit = params["commit"]
    notes = params["notes"]

    cond do
      not (is_binary(key) and key != "" and byte_size(key) <= 128) ->
        {:refused, refusal("bad_request", "key must be 1 to 128 bytes")}

      not (is_binary(commit) and Regex.match?(~r/\A[0-9a-f]{40}\z/, commit)) ->
        {:refused, refusal("bad_request", "commit must be a full commit SHA")}

      not (is_nil(notes) or (is_binary(notes) and String.length(notes) <= @max_notes_chars)) ->
        {:refused, refusal("bad_request", "notes are at most #{@max_notes_chars} characters")}

      true ->
        {:ok, %{key: key, commit: commit, notes: notes}}
    end
  end

  # The files of a deploy, by name: each at most once, within its size; the
  # manifest, the bundle and the source archive are required. Checked before
  # a byte is read.
  defp app_files_given(files) do
    with {:ok, given} <- files_given(files) do
      roles =
        Enum.map(given, fn file ->
          case Map.fetch(@app_files, file.name) do
            {:ok, {role, max}} when file.size <= max -> {:ok, role, file}
            {:ok, {_role, max}} -> {:too_big, "#{file.name} is larger than #{max} bytes"}
            :error -> {:unknown, "#{file.name} is not a file of a deploy"}
          end
        end)

      names = Enum.map(given, & &1.name)
      problem = Enum.find(roles, &(elem(&1, 0) in [:too_big, :unknown]))

      cond do
        problem ->
          {:refused, refusal("invalid", elem(problem, 1))}

        length(names) != length(Enum.uniq(names)) ->
          {:refused, refusal("invalid", "each file of a deploy is named once")}

        not Enum.all?(~w(comma-app.json bundle.tar source.tar.gz), &(&1 in names)) ->
          {:refused,
           refusal("invalid", "a deploy needs comma-app.json, bundle.tar and source.tar.gz")}

        true ->
          {:ok, Map.new(roles, fn {:ok, role, file} -> {role, file} end)}
      end
    else
      {:error, {:bad_request, message}} -> {:refused, refusal("invalid", message)}
      {:error, _reason} -> {:refused, refusal("invalid", "files must be [{index, name, size}]")}
    end
  end

  defp deploy_app(view, row, task, app_id, deploy, files) do
    dir = Path.join(System.tmp_dir!(), "salix-app-deploy-" <> random_name())

    try do
      with :ok <- File.mkdir_p(dir),
           {:ok, staged} <- stage_app_files(view, row, deploy.key, files, dir),
           {:ok, manifest} <- File.read(staged.manifest),
           # The pull took a while: the sandbox is still the Task's current one.
           :ok <- sandbox_authority(view, row) do
        ctx = %{
          tenant_id: view.tenant_id,
          group_id: view.group_id,
          conversation_id: row.conversation_id,
          agent_id: row.agent_id,
          app_id: app_id,
          key: deploy.key,
          commit: deploy.commit,
          notes: deploy.notes,
          branch: get_in(task, ["repo", "branch"]),
          repo: Map.take(task["repo"] || %{}, ["owner", "name"])
        }

        given =
          staged
          |> Map.delete(:manifest)
          |> Map.new(fn {role, path} -> {role, %{path: path}} end)
          |> Map.put(:manifest, manifest)

        case SalixWeb.MiniAppDeploys.deploy(ctx, given) do
          {:ok, %{} = version} ->
            with {:ok, _message} <- append_app_message(view, row, deploy.key, version),
                 do: {:ok, Map.take(version, ~w(app_id version state name summary))}

          {:error, {:invalid, errors}} when is_list(errors) ->
            {:ok, %{"error" => "invalid", "errors" => errors}}

          {:error, reason} ->
            {:ok, app_error(reason)}
        end
      else
        {:error, {:bad_request, message}} -> {:ok, refusal("file_unreadable", message)}
        {:error, _} = error -> error
      end
    after
      File.rm_rf(dir)
    end
  end

  # Each file, read from the station into a temp file of its own: the path
  # by role (the manifest's too, read back once whole).
  defp stage_app_files(view, row, key, files, dir) do
    Enum.reduce_while(files, {:ok, %{}}, fn {role, file}, {:ok, staged} ->
      path = Path.join(dir, Atom.to_string(role))

      case stage_app_file(view, row, key, file, path) do
        :ok -> {:cont, {:ok, Map.put(staged, role, path)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp stage_app_file(view, row, key, file, path) do
    case File.open(path, [:write, :binary, :raw]) do
      {:ok, io} ->
        try do
          write_parts(view, row, key, file, 0, io)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:app_file_not_staged, reason}}
    end
  end

  defp write_parts(_view, _row, _key, %{size: size}, offset, _io) when offset >= size, do: :ok

  defp write_parts(view, row, key, file, offset, io) do
    with {:ok, part} <- pull_part(view, row, key, file, offset),
         :ok <- :file.write(io, part) do
      write_parts(view, row, key, file, offset + byte_size(part), io)
    end
  end

  # The Version in the Task, as its Worker wrote it, once per key: its summary
  # is the Message's text, and the `mini_app` block lets clients open it. The
  # Session it came from keeps it as its own (`message/2`).
  defp append_app_message(view, row, key, %{
         "app_id" => app_id,
         "version" => version,
         "name" => name,
         "summary" => summary
       }) do
    with {:ok, participant_id} <- worker(view.group_id, row) do
      conversations().append(view.group_id, row.conversation_id, row.agent_id, %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => row.agent_id,
        "participant_id" => participant_id,
        "content" => [
          %{"type" => "text", "text" => summary},
          %{
            "type" => "mini_app",
            "version" => 1,
            "app_id" => app_id,
            "app_version" => version,
            "name" => name,
            "summary" => summary
          }
        ],
        "client_request_id" =>
          "station-app-deploy:" <> digest([view.device_id, row.session, key]),
        "metadata" => %{
          "kind" => "mini_app_deploy",
          "device_id" => view.device_id,
          "session" => row.session
        }
      })
    end
  end

  defp append_app_message(_view, _row, _key, version),
    do: {:error, {:bad_app_version, Map.keys(version)}}

  defp refusal(error, message), do: %{"error" => error, "message" => message}

  defp app_error(:mini_apps_unavailable),
    do: refusal("mini_apps_unavailable", "apps are not set up here")

  defp app_error(reason) when is_atom(reason),
    do: refusal(Atom.to_string(reason), String.replace(Atom.to_string(reason), "_", " "))

  defp app_error({reason, message}) when is_atom(reason) and is_binary(message),
    do: refusal(Atom.to_string(reason), message)

  defp app_error(reason), do: refusal("failed", inspect(reason))

  defp random_name, do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(12), padding: false)

  # The titles a station gave (`chat_post` milestones); the Conversation checks them.
  defp milestones_given(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp milestones_given(_list), do: []

  defp content(text, [], []), do: truncate(text)

  defp content(text, milestones, files) do
    blocks = Enum.map(milestones, &%{"type" => "milestone", "title" => &1})
    text = if text == "", do: [], else: [%{"type" => "text", "text" => truncate(text)}]
    blocks ++ text ++ files
  end

  # A coding Task goes into review with it
  # (`SalixIM.ConversationServer.coding_turn_ended/3`), unless a Message for
  # its Session came after what the Session had been given (a follow-up the
  # next turn takes up).
  defp ended_turn(view, row, declared, seq) when declared in @ended_turn do
    with :ok <-
           StationTaskSessions.ended_turn(view.group_id, row.conversation_id, view.device_id, seq) do
      # What the turn left in a coding Task's sandbox is read now, for its panel.
      if SalixStore.CodingSandboxes.device?(view.device_id),
        do: SalixWeb.CodingSandboxes.turn_ended(view.group_id, row.conversation_id)

      with {:ok, false} <- unanswered?(view.group_id, row, seq),
           {:ok, _status} <- conversations().turn_ended(view.group_id, row.conversation_id, seq) do
        :ok
      else
        {:ok, true} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp ended_turn(_view, _row, _declared, _seq), do: :ok

  # Whether a Message for the Session (one not its Worker's) is in the Task
  # between what the Session had been given and the post `seq`. A page that
  # does not reach `seq` counts as one.
  defp unanswered?(group, row, seq) do
    with {:ok, messages} <-
           conversations().messages_after(group, row.conversation_id, row.sent, @put_limit) do
      before = Enum.filter(messages, &(&1["seq"] < seq))

      {:ok,
       (length(messages) == @put_limit and Enum.all?(messages, &(&1["seq"] < seq))) or
         Enum.any?(
           before,
           &(&1["kind"] == "message" and
               not (&1["actor_type"] == "agent" and &1["agent_id"] == row.agent_id))
         )}
    end
  end

  defp put_answered(params, answered) when answered > 0, do: Map.put(params, "answered", answered)
  defp put_answered(params, _answered), do: params

  # The Session of the asking device that takes part in the Task.
  defp taking_part(%{tenant_id: tenant, group_id: group, device_id: device}, %{
         "task" => task,
         "session" => session
       })
       when is_binary(task) and is_binary(session) do
    case StationTaskSessions.of_task(group, task) do
      {:ok, rows} ->
        Enum.find_value(rows, {:error, :not_taking_part}, fn row ->
          if row.tenant_id == tenant and row.device_id == device and row.session == session,
            do: {:ok, row}
        end)

      _ ->
        {:error, :not_taking_part}
    end
  end

  defp taking_part(_view, _params), do: {:error, :not_taking_part}

  # The Task's Worker, who authors what the station's Session writes.
  defp worker(group, row) do
    with {:ok, participants} <- conversations().participants(group, row.conversation_id) do
      case Enum.find(
             participants,
             &(&1["actor_type"] == "agent" and &1["agent_id"] == row.agent_id and
                 &1["role_label"] == "worker")
           ) do
        %{"participant_id" => id} -> {:ok, id}
        nil -> {:error, :not_taking_part}
      end
    end
  end

  defp admitted_run(tenant, group, device) do
    with {:ok, %{"status" => "connected", "connector_run_id" => run} = current}
         when is_binary(run) <-
           SalixEnv.Registry.get_device(tenant, group, device),
         {:ok, _owner} <-
           SalixEnv.StationConnection.authorize(
             SalixStore.ComputeStation.connection(tenant, group, current)
           ) do
      {:ok, run}
    else
      {:error, :not_found} -> {:error, :device_offline}
      {:error, _} = error -> error
      _ -> {:error, :device_offline}
    end
  end

  defp online_run(tenant, group, device) do
    case SalixEnv.Registry.get_device(tenant, group, device) do
      {:ok, %{"status" => "connected", "connector_run_id" => run_id}}
      when is_binary(run_id) and run_id != "" ->
        run_id

      _ ->
        nil
    end
  end

  defp reason(reason) when is_binary(reason), do: reason
  defp reason(reason), do: inspect(reason)

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp digest(parts) do
    :crypto.hash(:sha256, Enum.join(parts, "\n"))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp truncate(text) when byte_size(text) <= @max_text_bytes, do: text

  defp truncate(text) do
    text
    |> binary_part(0, @max_text_bytes)
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
  end

  defp text(content) when is_binary(content), do: content

  defp text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{type: "text", text: text} when is_binary(text) -> [text]
      text when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp text(_content), do: ""

  # A station that posts or takes a Task Message is at work: the Group's Cloud
  # VM, when the station is its, counts it toward its idle clock.
  defp station_activity(group, device),
    do: SalixWeb.ComputeProviders.Cloudflare.mark_station_activity(group, device)

  defp conversations, do: config(:conversations, __MODULE__.Conversations)
  defp connector, do: config(:connector, SalixEnv.Connector.Live)

  defp config(key, default),
    do: Keyword.get(SystemsRuntime.get_env(:salix_web, :station_tasks, []), key, default)

  defmodule Conversations do
    @moduledoc "The Task as `SalixWeb.StationTasks` reads and writes it."

    def append(group_id, conversation_id, agent_id, attrs),
      do:
        SalixIM.ConversationServer.append_group_conversation_agent_message(
          group_id,
          conversation_id,
          agent_id,
          attrs
        )

    def turn_ended(group_id, conversation_id, seq),
      do: SalixIM.ConversationServer.coding_turn_ended(group_id, conversation_id, seq)

    def messages_after(group_id, conversation_id, after_seq, limit),
      do:
        SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id,
          after_seq: after_seq,
          limit: limit
        )

    def message(group_id, conversation_id, message_id),
      do:
        SalixIM.Conversations.get_group_conversation_message(
          group_id,
          conversation_id,
          message_id
        )

    def read_part(agent_id, ref, offset, length),
      do: SalixStore.Blob.read_range(agent_id, ref, offset, length)

    def blob_init(agent_id), do: SalixStore.Blob.put_stream_init(agent_id)
    def blob_step(state, chunk), do: SalixStore.Blob.put_stream_step(state, chunk)
    def blob_finish(state), do: SalixStore.Blob.put_stream_finish(state)
    def blob_abort(state), do: SalixStore.Blob.put_stream_abort(state)

    def place(agent_id, path, ref) do
      case SalixIM.Ports.AgentWorkspace.put_ref(agent_id, path, ref) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end

    def owner(group_id, conversation_id) do
      case SalixIM.Conversations.get_group_conversation(group_id, conversation_id) do
        {:ok, %{"owner_user_id" => owner}} when is_binary(owner) and owner != "" -> {:ok, owner}
        {:ok, _conversation} -> {:error, :no_owner}
        error -> error
      end
    end

    def task(group_id, conversation_id),
      do: SalixIM.Conversations.get_group_conversation(group_id, conversation_id)

    def status(group_id, conversation_id) do
      with {:ok, %{"status" => status}} <-
             SalixIM.Conversations.get_group_conversation(group_id, conversation_id),
           do: {:ok, status}
    end

    def participants(group_id, conversation_id) do
      case SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id) do
        {:ok, %{"participants" => participants}} -> {:ok, participants}
        {:ok, participants} when is_list(participants) -> {:ok, participants}
        error -> error
      end
    end
  end
end
