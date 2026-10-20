defmodule SalixWeb.StationTasks do
  require SystemsRuntime.Proc

  @moduledoc """
  Salix as the Station a Task is kept on, for the Sessions of other stations
  taking part in it (`systems/station/docs/tasks.md`): the same requests
  as between any two stations, over the device's connector connection.

    * `invite/1` (`task.invite`): asks the station to start a Session for the
      Task, before the Task is made. Answered at once: the Session, or why not
      (not connected, cannot run the model). Nothing is written into the Task.
    * `joined/1`: the Session takes part (`SalixStore.StationTaskSessions`,
      `sent` 0) and is given the Task.
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
      Task's Worker (who is delivered nothing), once per `key`; its seq.
    * `session_status/2` (`task.status`): where the station's Session of the
      Task stands (running, waiting, idle, cannot start, gone), for the
      Task's `SalixIM.StationTaskWatch`; a read that starts nothing there.
    * `hello/2` (`task.hello`): the station connected; it is given what it
      missed. With `tasks` (`[{task, fetched}]`, how far it has each), from
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
  @max_text_bytes 64 * 1024
  @declared ~w(all_done need_help waiting)
  @ended_turn ~w(all_done need_help)

  @doc """
  Asks the station `device_id` to start a Session for Task `conversation_id`.
  `{:ok, session}`, or why not: `:device_offline`, or the station's refusal.
  """
  @impl SalixIM.Ports.TaskStations
  def invite(%{tenant_id: tenant, group_id: group, device_id: device} = invitation) do
    with {:ok, start} <- start(invitation) do
      ask_invite(
        tenant,
        group,
        device,
        invitation.conversation_id,
        start,
        invitation[:answered] || 0
      )
    end
  end

  # A Task on the Group's Cloud VM that names no model runs the platform's
  # worker model, which Salix lends that station for Codex
  # (`SalixWeb.StationLLM`), as a Worker inside Salix would. Another station
  # runs its own default.
  defp start(%{start: start, group_id: group, device_id: device}) do
    cloud_vm? = device == SalixStore.RuntimeIds.cloud_vm_device_id(group)

    case {cloud_vm? and blank?(start["model"]), start["runtime"], SalixWeb.StationLLM.tier()} do
      {false, _runtime, _tier} ->
        {:ok, start}

      {true, runtime, {:ok, tier}} when runtime in [nil, "", "codex"] ->
        {:ok, Map.merge(start, %{"runtime" => "codex", "model" => tier["model"]})}

      {true, "claude", {:ok, _tier}} ->
        {:error,
         {:station_refused,
          "the platform model runs with Codex only; name a Claude model the Cloud VM runs, or use Codex"}}

      {true, _runtime, _no_tier} ->
        {:ok, start}
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp ask_invite(tenant, group, device, conversation, start, answered) do
    case online_run(tenant, group, device) do
      nil ->
        {:error, :device_offline}

      run_id ->
        params = put_answered(%{"task" => conversation, "start" => start}, answered)

        case connector().request(run_id, "task.invite", params, timeout: @invite_timeout_ms) do
          {:ok, %{"session" => session}} when is_binary(session) and session != "" ->
            {:ok, session}

          {:ok, _answer} ->
            {:error, {:station_refused, "the station started no Session"}}

          {:error, :disconnected} ->
            {:error, :device_offline}

          {:error, reason} ->
            {:error, {:station_refused, reason(reason)}}
        end
    end
  end

  @doc "The station's Session takes part in the Task from now on, and is given it from its start."
  @impl SalixIM.Ports.TaskStations
  def joined(row) do
    with :ok <- StationTaskSessions.join(row) do
      give(row.group_id, row.conversation_id, row.device_id)
      :ok
    end
  end

  @doc "A Message was added to the Task: the stations taking part are given it. Never waits for them."
  @impl SalixIM.Ports.TaskStations
  def appended(group, conversation) do
    SystemsRuntime.TaskSupervisor.start_child(SalixWeb.StationTasks.Supervisor, fn ->
      case StationTaskSessions.of_task(group, conversation) do
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
      cloud_vm? = device == SalixStore.RuntimeIds.cloud_vm_device_id(group)

      with {:ok, vm_status} <- if(cloud_vm?, do: vm_status(group), else: {:ok, nil}) do
        {:ok,
         %{
           place: if(cloud_vm?, do: :cloud_vm, else: :device),
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
         %{tenant_id: tenant, device_id: device, session: session} <-
           Enum.min_by(rows, & &1.sent),
         run_id when is_binary(run_id) <- online_run(tenant, group, device) do
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
             last_failure: last_failure(answer["last_failure"])
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
    had = had(params)

    with {:ok, rows} <- StationTaskSessions.of_device(tenant, group, device) do
      rows
      |> Enum.map(& &1.conversation_id)
      |> Enum.uniq()
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

      {:ok, %{}}
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
        if result == :unreachable, do: wake(group, device)

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
  # other work for the VM is. Which device that is, the Group's Workload says.
  # The VM's station then says hello and is given the Task. A wake already on
  # its way is the same wake; one that cannot be made is said once, and asked
  # again only when the station is next given something.
  defp wake(group, device) do
    with {:ok, %{"device_id" => ^device}} <- SalixStore.Compute.group_workload(group),
         {:error, reason} when reason != :runtime_waking <-
           SalixWeb.CloudVM.RuntimeLifecycle.wake(group) do
      Logger.warning(
        "the Cloud VM of a station with a Task to take was not woken; asked again when it is next given something: group=#{group} device=#{device} #{inspect(reason)}"
      )
    end

    :ok
  end

  # `invited_again`: the station was invited again in this giving already.
  defp give_now(group, conversation, device, invited_again) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation),
         [_ | _] = rows <- Enum.filter(rows, &(&1.device_id == device)) do
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
      [] -> :ok
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

    case online_run(tenant, group, device) do
      nil ->
        :unreachable

      run_id ->
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
      "text" => text(message["content"]),
      "declared" => metadata["declared"],
      "at" => message["created_at"]
    }
  end

  @doc "`task.post` from the device of `view`: a Message of its Session, once per `key`; its seq."
  def post(view, params) when is_map(params) do
    with {:ok, row} <- taking_part(view, params),
         text when is_binary(text) and text != "" <- params["text"],
         key when is_binary(key) and key != "" and byte_size(key) <= 128 <- params["key"],
         {:ok, participant_id} <- worker(view.group_id, row) do
      declared = if params["declared"] in @declared, do: params["declared"]

      attrs = %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => row.agent_id,
        "participant_id" => participant_id,
        "content" => truncate(text),
        "client_request_id" => "station-task:" <> digest([view.device_id, row.session, key]),
        "metadata" =>
          %{"kind" => "station_task", "device_id" => view.device_id, "session" => row.session}
          |> put_present("declared", declared)
      }

      # A post that ends a turn: its Session answered what the station had been
      # given by then.
      with {:ok, _answered} <- answered([row], view.group_id, row.conversation_id, view.device_id),
           {:ok, %{"seq" => seq}} <-
             conversations().append(view.group_id, row.conversation_id, row.agent_id, attrs),
           :ok <- ended_turn(view, row, declared, seq) do
        {:ok, %{"seq" => seq}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_request}
    end
  end

  def post(_view, _params), do: {:error, :bad_request}

  defp ended_turn(view, row, declared, seq) when declared in @ended_turn,
    do: StationTaskSessions.ended_turn(view.group_id, row.conversation_id, view.device_id, seq)

  defp ended_turn(_view, _row, _declared, _seq), do: :ok

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

    def messages_after(group_id, conversation_id, after_seq, limit),
      do:
        SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id,
          after_seq: after_seq,
          limit: limit
        )

    def participants(group_id, conversation_id) do
      case SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id) do
        {:ok, %{"participants" => participants}} -> {:ok, participants}
        {:ok, participants} when is_list(participants) -> {:ok, participants}
        error -> error
      end
    end
  end
end
