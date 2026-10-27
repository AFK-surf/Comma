defmodule SalixWeb.StationTasksTest do
  @moduledoc """
  Salix as the Station a Task is kept on (`SalixWeb.StationTasks`), as between
  any two stations (`systems/station/docs/tasks.md`): the station is invited
  before the Task is made and answers at once; it is given every Message after
  what it had, however long that takes; it writes into the Task as the Worker,
  and only from its own device. The Task is a fake holding what the
  Conversation would; the station answers as the test says.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  import SystemsRuntime.Test, only: [capture_log: 1]

  alias SalixEnv.Registry
  alias SalixStore.Compute, as: GroupCompute
  alias SalixStore.StationTaskSessions
  alias SalixWeb.Migrations.StationTaskStarts
  alias SalixWeb.StationTasks

  defmodule FakeTask do
    @moduledoc false
    use Agent

    def start_link(state), do: SystemsRuntime.Agent.start_link(fn -> state end, name: __MODULE__)

    def messages, do: SystemsRuntime.Agent.get(__MODULE__, & &1.messages)

    def add(message) do
      message = Map.put_new(message, "kind", "message")

      SystemsRuntime.Agent.update(
        __MODULE__,
        &%{&1 | messages: &1.messages ++ [Map.put(message, "seq", length(&1.messages) + 1)]}
      )
    end

    def append(_group_id, _conversation_id, _agent_id, attrs) do
      SystemsRuntime.Agent.get_and_update(__MODULE__, fn state ->
        case Enum.find(state.messages, &(&1["client_request_id"] == attrs["client_request_id"])) do
          nil ->
            message = Map.put(attrs, "seq", length(state.messages) + 1)
            {{:ok, message}, %{state | messages: state.messages ++ [message]}}

          message ->
            {{:ok, message}, state}
        end
      end)
    end

    def messages_after(_group_id, _conversation_id, after_seq, limit),
      do: {:ok, messages() |> Enum.filter(&(&1["seq"] > after_seq)) |> Enum.take(limit)}

    # The turns that ended, by the Message that ended each.
    def turn_ended(_group_id, _conversation_id, seq) do
      SystemsRuntime.Agent.update(
        __MODULE__,
        &Map.update(&1, :turns, [seq], fn t -> t ++ [seq] end)
      )

      {:ok, "active"}
    end

    def turns, do: SystemsRuntime.Agent.get(__MODULE__, &Map.get(&1, :turns, []))

    def participants(_group_id, _conversation_id),
      do: {:ok, SystemsRuntime.Agent.get(__MODULE__, & &1.participants)}

    def message(_group_id, _conversation_id, message_id) do
      case Enum.find(messages(), &(&1["message_id"] == message_id)) do
        nil -> {:error, :not_found}
        message -> {:ok, message}
      end
    end

    # A blob's bytes are the test's `blob/1`, kept by its uuid.
    def blob(%{"uuid" => uuid}, bytes),
      do:
        SystemsRuntime.Agent.update(
          __MODULE__,
          &Map.update(&1, :blobs, %{uuid => bytes}, fn b -> Map.put(b, uuid, bytes) end)
        )

    # A file a station posts: its bytes kept as a blob, and placed in the Worker's VFS.
    def blob_init(agent_id), do: %{agent_id: agent_id, bytes: ""}
    def blob_step(state, chunk), do: {:ok, %{state | bytes: state.bytes <> chunk}}

    # A ref as `SalixStore.Blob` gives it: atom keys, a 32-hex uuid, the bytes' sha256.
    def blob_finish(state) do
      hash = SalixStore.Crypto.hex(state.bytes)

      ref = %{
        kind: "blob",
        uuid: binary_part(hash, 0, 32),
        size: byte_size(state.bytes),
        hash: hash
      }

      blob(%{"uuid" => ref.uuid}, state.bytes)
      {:ok, ref}
    end

    def blob_abort(state),
      do:
        SystemsRuntime.Agent.update(
          __MODULE__,
          &Map.update(&1, :aborted, [state], fn a -> a ++ [state] end)
        )

    def place(agent_id, path, %{uuid: uuid}),
      do:
        SystemsRuntime.Agent.update(
          __MODULE__,
          &Map.update(&1, :placed, %{path => {agent_id, uuid}}, fn p ->
            Map.put(p, path, {agent_id, uuid})
          end)
        )

    def placed, do: SystemsRuntime.Agent.get(__MODULE__, &Map.get(&1, :placed, %{}))
    def aborted, do: SystemsRuntime.Agent.get(__MODULE__, &Map.get(&1, :aborted, []))
    def bytes(uuid), do: SystemsRuntime.Agent.get(__MODULE__, &get_in(&1, [:blobs, uuid]))

    def read_part(_agent_id, %{"uuid" => uuid}, offset, length) do
      bytes = SystemsRuntime.Agent.get(__MODULE__, &get_in(&1, [:blobs, uuid]))

      {:ok,
       binary_part(
         bytes,
         min(offset, byte_size(bytes)),
         max(0, min(length, byte_size(bytes) - offset))
       )}
    end
  end

  defmodule Station do
    @moduledoc "The station on the other end: what it is asked, and how it answers (`answer/1`)."
    use Agent

    def start_link(_), do: SystemsRuntime.Agent.start_link(fn -> :ok end, name: __MODULE__)
    def answer(how), do: SystemsRuntime.Agent.update(__MODULE__, fn _ -> how end)

    def request(run_id, method, params, _opts) do
      # How it answers is set before the test hears it was asked: an answer the
      # test changes once it hears of a request is for the requests after it.
      how = SystemsRuntime.Agent.get(__MODULE__, & &1)

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :station_tasks_test_pid),
        {:asked, run_id, method, params}
      )

      case {how, method} do
        # The files of the post it is making, as the test set them (by index).
        {_how, "task.posted_file"} ->
          files = SystemsRuntime.get_env(:salix_web, :station_tasks_posted_files, %{})

          case files[params["index"]] do
            nil ->
              {:ok, %{"missing" => "no longer on its station"}}

            bytes ->
              offset = params["offset"]
              part = binary_part(bytes, offset, min(256 * 1024, byte_size(bytes) - offset))
              {:ok, %{"offset" => offset, "data" => Base.encode64(part)}}
          end

        # It lost the Task: it knows nothing of it until invited again.
        {:lost, "task.put"} ->
          {:ok, %{"unknown" => true, "gone" => true}}

        {:lost, "task.invite"} ->
          SystemsRuntime.Agent.update(__MODULE__, fn _ -> :ok end)
          {:ok, %{"session" => "ember:c-2"}}

        {:ok, "task.invite"} ->
          {:ok, %{"session" => "ember:c-1"}}

        {:ok, "task.put"} ->
          {:ok, %{"through" => params["through"]}}

        {:ok, "task.leave"} ->
          {:ok, %{}}

        {:gone, "task.put"} ->
          {:ok, %{"gone" => true}}

        {:ok, "task.status"} ->
          {:ok,
           %{
             "state" => "cannot_start",
             "pending" => 2,
             "for_ms" => 12_000,
             "last_failure" => String.duplicate("x", 300)
           }}

        # A station from before task.status.
        {:old, "task.status"} ->
          {:error, "unsupported task method: task.status"}

        {:old, "task.put"} ->
          {:ok, %{"through" => params["through"]}}

        {:refuse, _} ->
          {:error, "no profile runs gpt-5.4-mini"}

        {:silent, _} ->
          {:error, :timeout}
      end
    end
  end

  defmodule Billing do
    @moduledoc "What a wake of a Cloudflare Cloud VM asks billing: each time it is asked, and its answer (`answer/1`)."
    @behaviour SalixWeb.ComputeProviders.Cloudflare.VMAuthorization
    use Agent

    def start_link(_), do: SystemsRuntime.Agent.start_link(fn -> :ok end, name: __MODULE__)
    def answer(how), do: SystemsRuntime.Agent.update(__MODULE__, fn _ -> how end)

    @impl true
    def authorize_vm(%{group_id: group}) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :station_tasks_test_pid),
        {:billing_asked, group}
      )

      SystemsRuntime.Agent.get(__MODULE__, & &1)
    end
  end

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Station tasks"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Station tasks"}, tenant["tenant_id"])

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Worker", "role" => "worker"},
        tenant["tenant_id"]
      )

    device_id = "device-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    start_supervised!(
      {FakeTask,
       %{
         participants: [
           %{
             "participant_id" => "ptp_worker",
             "actor_type" => "agent",
             "agent_id" => worker["agent_id"],
             "role_label" => "worker",
             "state" => "active",
             "notification_filter" => %{"messages" => "none", "statuses" => "none"}
           }
         ],
         messages: [
           %{
             "seq" => 1,
             "actor_type" => "agent",
             "agent_id" => "agt_router",
             "content" => "build it",
             "created_at" => 1
           },
           %{
             "seq" => 2,
             "actor_type" => "user",
             "user_id" => "usr_ann",
             "content" => [%{"type" => "text", "text" => "and test it"}],
             "created_at" => 2
           }
         ]
       }}
    )

    start_supervised!(Station)

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      conversations: FakeTask,
      connector: Station
    )

    SystemsRuntime.put_env(:salix_web, :station_tasks_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_web, :station_tasks)
      SystemsRuntime.delete_env(:salix_web, :station_tasks_test_pid)
    end)

    view = %{tenant_id: tenant["tenant_id"], group_id: group["group_id"], device_id: device_id}

    row = %{
      tenant_id: tenant["tenant_id"],
      group_id: group["group_id"],
      conversation_id: "cnv_task",
      device_id: device_id,
      session: "ember:c-1",
      agent_id: worker["agent_id"]
    }

    {:ok, view: view, row: row, worker: worker}
  end

  test "a station is invited at once: its Session, or why not", context do
    invitation = %{
      tenant_id: context.view.tenant_id,
      group_id: context.view.group_id,
      conversation_id: "cnv_task",
      device_id: context.view.device_id,
      start: %{"requester" => "ann", "runtime" => "codex", "model" => "gpt-5.4-mini"}
    }

    assert {:error, :device_offline} = StationTasks.invite(invitation)
    refute_received {:asked, _, _, _}

    run_id = connect!(context.view)
    assert {:ok, "ember:c-1"} = StationTasks.invite(invitation)

    assert_received {:asked, ^run_id, "task.invite",
                     %{"task" => "cnv_task", "start" => %{"model" => "gpt-5.4-mini"}}}

    Station.answer(:refuse)

    assert {:error, {:station_refused, "no profile runs gpt-5.4-mini"}} =
             StationTasks.invite(invitation)
  end

  test "a station taking part is given the Task from its start, then each Message added",
       context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)

    settle_receive(
      {:asked, ^run_id, "task.put",
       %{"task" => "cnv_task", "messages" => [first, second], "through" => 2}}
    )

    assert first["author"] == %{"kind" => "agent", "id" => "agt_router"}

    assert {second["author"], second["text"]} ==
             {%{"kind" => "person", "id" => "usr_ann"}, "and test it"}

    assert_sent(context.row, 2)

    FakeTask.add(%{
      "actor_type" => "user",
      "user_id" => "usr_ann",
      "content" => "ship it",
      "created_at" => 3
    })

    StationTasks.appended(context.row.group_id, "cnv_task")

    settle_receive(
      {:asked, ^run_id, "task.put", %{"messages" => [%{"text" => "ship it"}], "through" => 3}}
    )

    assert_sent(context.row, 3)
  end

  test "where the station stands, for the Task's stall watch", context do
    group = context.row.group_id
    assert :not_station = StationTasks.standing(group, "cnv_task")

    assert :ok = StationTasks.joined(context.row)

    # Not connected: it was given nothing yet.
    assert {:ok, %{place: :device, connected?: false, sent: 0, vm_status: nil}} =
             StationTasks.standing(group, "cnv_task")

    run_id = connect!(context.view)
    assert {:ok, %{}} = StationTasks.hello(context.view, %{})
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})
    assert_sent(context.row, 2)

    assert {:ok, %{place: :device, connected?: true, sent: 2, vm_status: nil}} =
             StationTasks.standing(group, "cnv_task")
  end

  test "where the station's Session stands, asked of the station; unknown when it cannot say",
       context do
    group = context.row.group_id
    assert :unknown = StationTasks.session_status(group, "cnv_task")

    assert :ok = StationTasks.joined(context.row)
    # Not connected: not asked.
    assert :unknown = StationTasks.session_status(group, "cnv_task")
    refute_received {:asked, _, "task.status", _}

    run_id = connect!(context.view)

    assert {:ok, %{state: :cannot_start, pending: 2, for_ms: 12_000, last_failure: why}} =
             StationTasks.session_status(group, "cnv_task")

    assert String.length(why) == 200

    settle_receive(
      {:asked, ^run_id, "task.status", %{"task" => "cnv_task", "session" => "ember:c-1"}}
    )

    # A station from before task.status, and one that does not answer in time.
    Station.answer(:old)
    assert :unknown = StationTasks.session_status(group, "cnv_task")
    Station.answer(:silent)
    assert :unknown = StationTasks.session_status(group, "cnv_task")
  end

  test "a station not connected is not asked again; once it says hello it is given what it missed",
       context do
    assert :ok = StationTasks.joined(context.row)

    FakeTask.add(%{
      "actor_type" => "user",
      "user_id" => "usr_ann",
      "content" => "said while away",
      "created_at" => 3
    })

    StationTasks.appended(context.row.group_id, "cnv_task")
    settle_refute_receive({:asked, _, _, _}, 300)

    run_id = connect!(context.view)
    assert {:ok, %{}} = StationTasks.hello(context.view, %{})

    settle_receive(
      {:asked, ^run_id, "task.put", %{"messages" => [_, _, %{"text" => "said while away"}]}}
    )

    assert_sent(context.row, 3)
  end

  test "a connected station that does not answer is given it again, backing off, until it has it",
       context do
    run_id = connect!(context.view)
    Station.answer(:silent)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", _})
    # Not before a second, then again; then not before two more.
    settle_refute_receive({:asked, _, _, _}, 999)
    settle_receive({:asked, ^run_id, "task.put", _})
    Station.answer(:ok)
    settle_refute_receive({:asked, _, _, _}, 1_999)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})
    assert_sent(context.row, 2)
    settle_refute_receive({:asked, _, _, _}, 120_000)
  end

  test "a station whose Session is gone is given nothing more", context do
    run_id = connect!(context.view)
    Station.answer(:gone)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", _})

    settle_until(fn ->
      StationTaskSessions.of_task(context.row.group_id, "cnv_task") == {:ok, []}
    end)

    StationTasks.appended(context.row.group_id, "cnv_task")
    settle_refute_receive({:asked, _, _, _}, 300)
  end

  test "a station restored from before is given again what it lost", context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})
    assert_sent(context.row, 2)

    # It has the Task only through the first Message now.
    hello = %{"tasks" => [%{"task" => "cnv_task", "fetched" => 1}]}
    assert {:ok, %{}} = StationTasks.hello(context.view, hello)

    settle_receive(
      {:asked, ^run_id, "task.put",
       %{"messages" => [%{"seq" => 2, "text" => "and test it"}], "through" => 2}}
    )

    assert_sent(context.row, 2)
  end

  test "a station that lost the Task is invited again as it was first, and given it from its start",
       context do
    start = %{"requester" => "worker@agents.salix", "runtime" => "codex", "model" => "gpt-5.4"}
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(Map.put(context.row, :start, start))
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})
    # The giver keeps what the station took only after the test hears it was
    # asked: a hello before that would be overtaken by it, and given nothing.
    assert_sent(context.row, 2)

    # It lost everything: its hello names no Task.
    Station.answer(:lost)
    assert {:ok, %{}} = StationTasks.hello(context.view, %{"tasks" => []})
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})

    settle_receive(
      {:asked, ^run_id, "task.invite", %{"task" => "cnv_task", "start" => ^start} = invite}
    )

    # None of its Sessions had answered: the invite says nothing of it.
    refute Map.has_key?(invite, "answered")
    settle_receive({:asked, ^run_id, "task.put", %{"messages" => [_, _], "through" => 2}})

    # Its new Session takes the old one's place, still taking part.
    settle_until(fn ->
      match?(
        {:ok, [%{session: "ember:c-2", sent: 2, start: ^start}]},
        StationTaskSessions.of_task(context.row.group_id, "cnv_task")
      )
    end)
  end

  test "a station that lost a Task it had answered in is given its answer as its own, and writes no second one",
       context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})
    # A post that ends a turn answers what Salix had kept as given by then:
    # the station is asked before its answer is kept, and the giver, still
    # running, would give the post itself. It posts once the giving is done.
    assert_sent(context.row, 2)

    post = %{
      "task" => "cnv_task",
      "session" => "ember:c-1",
      "text" => "built and tested",
      "key" => "k1",
      "declared" => "all_done"
    }

    assert {:ok, %{"seq" => 3}} = StationTasks.post(context.view, post)
    StationTasks.appended(context.row.group_id, "cnv_task")
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 3}})
    assert_sent(context.row, 3)

    # It lost everything: invited again, its new Session is given the Task from
    # its start.
    Station.answer(:lost)
    assert {:ok, %{}} = StationTasks.hello(context.view, %{"tasks" => []})
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 3}})
    # The invite says through which Message its Session answered already (what
    # it had been given when the Session ended its turn), as each put does: the
    # station hands its new Session nothing through it (station
    # `test/tasks.test.ts`).
    settle_receive({:asked, ^run_id, "task.invite", %{"task" => "cnv_task", "answered" => 2}})

    settle_receive(
      {:asked, ^run_id, "task.put",
       %{"messages" => [asked, also, answer], "through" => 3, "answered" => 2}}
    )

    # What the Session it had before answered is given as this station's own,
    # with what it declared.
    refute Map.has_key?(asked["author"], "session")
    refute Map.has_key?(also["author"], "session")

    assert %{
             "seq" => 3,
             "author" => %{"kind" => "agent", "session" => "ember:c-1"},
             "declared" => "all_done"
           } = answer

    settle_until(fn ->
      match?(
        {:ok, [%{session: "ember:c-2", sent: 3}]},
        StationTaskSessions.of_task(context.row.group_id, "cnv_task")
      )
    end)

    # Nothing more is written into the Task: only the new Session writes in it.
    settle_refute_receive({:asked, _, _, _}, 300)
    assert length(FakeTask.messages()) == 3
    assert {:error, :not_taking_part} = StationTasks.post(context.view, %{post | "key" => "k2"})
  end

  test "a station restored from before an exchange it answered is given it again, told it was answered",
       context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2} = first})
    # Nothing answered yet: the put says nothing of it.
    refute Map.has_key?(first, "answered")
    assert_sent(context.row, 2)

    post = %{"task" => "cnv_task", "session" => "ember:c-1", "text" => "built", "key" => "k1"}
    done = Map.put(post, "declared", "all_done")
    assert {:ok, %{"seq" => 3}} = StationTasks.post(context.view, done)
    FakeTask.add(%{"actor_type" => "user", "user_id" => "usr_ann", "content" => "follow up"})
    StationTasks.appended(context.row.group_id, "cnv_task")
    assert_sent(context.row, 4)
    # A post that ends no turn answers nothing.
    assert {:ok, %{"seq" => 5}} = StationTasks.post(context.view, %{post | "key" => "k2"})
    assert_answered(context.row, 2)
    assert {:ok, %{"seq" => 6}} = StationTasks.post(context.view, %{done | "key" => "k3"})
    # Answered through what it had been given, not through what it had not.
    assert_answered(context.row, 4)
    # The Task hears of each turn that ended, with the Message that ended it.
    assert FakeTask.turns() == [3, 6]
    StationTasks.appended(context.row.group_id, "cnv_task")
    assert_sent(context.row, 6)

    # The station comes back as it was before the follow-up: it has the Task
    # (no invite), through its first answer only.
    hello = %{"tasks" => [%{"task" => "cnv_task", "fetched" => 3}]}
    assert {:ok, %{}} = StationTasks.hello(context.view, hello)

    settle_receive(
      {:asked, ^run_id, "task.put",
       %{"messages" => [%{"seq" => 4}, %{"seq" => 5}, %{"seq" => 6}], "answered" => 4}}
    )

    assert_sent(context.row, 6)
    settle_refute_receive({:asked, _, "task.invite", _}, 300)
    assert length(FakeTask.messages()) == 6
  end

  test "a turn that ends before its Session was given a follow-up is no end of the work",
       context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})
    assert_sent(context.row, 2)

    # The follow-up is in the Task; the station has not been given it yet.
    FakeTask.add(%{"actor_type" => "user", "user_id" => "usr_ann", "content" => "follow up"})

    done = %{
      "task" => "cnv_task",
      "session" => "ember:c-1",
      "text" => "built",
      "key" => "k1",
      "declared" => "all_done"
    }

    assert {:ok, %{"seq" => 4}} = StationTasks.post(context.view, done)
    assert FakeTask.turns() == []

    # Given it, the Session's next turn that ends answers it.
    StationTasks.appended(context.row.group_id, "cnv_task")
    assert_sent(context.row, 4)
    assert {:ok, %{"seq" => 5}} = StationTasks.post(context.view, %{done | "key" => "k2"})
    assert FakeTask.turns() == [5]
  end

  test "Sessions taking part from before `answered` was kept: the Task is read for it once, wherever its last answer is",
       context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})

    post = %{"task" => "cnv_task", "session" => "ember:c-1", "text" => "built", "key" => "k1"}
    done = Map.put(post, "declared", "all_done")
    assert {:ok, %{"seq" => 3}} = StationTasks.post(context.view, done)

    for i <- 1..150 do
      FakeTask.add(%{"actor_type" => "user", "user_id" => "usr_ann", "content" => "more #{i}"})
    end

    StationTasks.appended(context.row.group_id, "cnv_task")
    assert_sent(context.row, 153)
    assert {:ok, %{"seq" => 154}} = StationTasks.post(context.view, %{done | "key" => "k2"})
    # A post that ends no turn is no answer; another device's is not this one's.
    assert {:ok, %{"seq" => 155}} = StationTasks.post(context.view, %{post | "key" => "k3"})

    FakeTask.add(%{
      "actor_type" => "agent",
      "agent_id" => context.worker["agent_id"],
      "content" => "done elsewhere",
      "metadata" => %{"device_id" => "device-other", "session" => "s", "declared" => "all_done"}
    })

    StationTasks.appended(context.row.group_id, "cnv_task")
    assert_sent(context.row, 156)
    SalixStore.Repo.query!("UPDATE station_task_sessions SET answered = NULL")

    # It lost the Task: what it answered is read from the Task (its last post
    # that ended a turn, past the first part read), told, and kept.
    Station.answer(:lost)
    assert {:ok, %{}} = StationTasks.hello(context.view, %{"tasks" => []})
    settle_receive({:asked, ^run_id, "task.invite", %{"answered" => 154}})
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 100, "answered" => 154}})
    assert_sent(%{context.row | session: "ember:c-2"}, 156)
    assert_answered(context.row, 154)
  end

  test "a station invited before its start was kept is invited again as its Worker was bound when the start was kept",
       context do
    worker = bound_worker!(context, "codex")
    row = %{context.row | agent_id: worker}
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})

    # The release keeps the start it would be invited again with now; the
    # Worker is bound elsewhere after that.
    assert {:ok, %{kept: kept}} = StationTaskStarts.run()
    assert kept >= 1
    start = %{"requester" => worker <> "@agents.salix", "title" => worker, "runtime" => "codex"}

    assert {:ok, %{result: :applied}} =
             SalixAgent.AgentControl.rebind_station_worker(
               worker,
               context.view.tenant_id,
               %{
                 "runs_on" => %{"kind" => "cloud_vm"},
                 "model" => %{"kind" => "runtime", "provider" => "claude"}
               },
               1
             )

    # It lost the Task; it learns of it with the next Message.
    Station.answer(:lost)

    FakeTask.add(%{
      "actor_type" => "user",
      "user_id" => "usr_ann",
      "content" => "after the loss",
      "created_at" => 3
    })

    StationTasks.appended(row.group_id, "cnv_task")
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 3}})
    settle_receive({:asked, ^run_id, "task.invite", %{"start" => ^start}})
    settle_receive({:asked, ^run_id, "task.put", %{"messages" => [_, _, _], "through" => 3}})
    assert_sent(row, 3)
  end

  test "the release keeps a start once for each Session without one, a page at a time",
       context do
    # Only this test's Sessions: those earlier tests left are not counted.
    SalixStore.Repo.query!("DELETE FROM station_task_sessions")
    bound = bound_worker!(context, "codex")

    {:ok, gone} =
      SalixAgent.Control.create(
        %{"group_id" => context.view.group_id, "name" => "Gone", "role" => "worker"},
        context.view.tenant_id
      )

    gone = gone["agent_id"]
    :ok = SalixStore.S3.delete(SalixStore.Keys.ctl_agent(gone))
    kept = %{"requester" => "ann", "runtime" => "claude"}

    rows =
      for {device, agent, start} <- [
            {"device-a", bound, nil},
            {"device-b", gone, nil},
            {"device-c", context.worker["agent_id"], nil},
            {"device-d", bound, kept}
          ] do
        row = Map.merge(context.row, %{device_id: device, agent_id: agent, start: start})
        assert :ok = StationTaskSessions.join(row)
        row
      end

    # Three without a start, read two at a time.
    assert {:ok, %{kept: 3, pages: 2}} = StationTaskStarts.run(page: 2)

    starts =
      for row <- rows, into: %{} do
        {:ok, sessions} =
          StationTaskSessions.of_device(row.tenant_id, row.group_id, row.device_id)

        [%{start: start}] = sessions
        {row.device_id, start}
      end

    asks = fn agent -> %{"requester" => agent <> "@agents.salix", "title" => agent} end
    worker = context.worker["agent_id"]

    # As the Worker is bound; one no longer there, and one not bound, name no
    # runtime or model; a start kept already stays.
    assert starts == %{
             "device-a" => Map.put(asks.(bound), "runtime", "codex"),
             "device-b" => asks.(gone),
             "device-c" => asks.(worker),
             "device-d" => kept
           }

    # Run again, it finds nothing to keep.
    assert {:ok, %{kept: 0, pages: 0}} = StationTaskStarts.run(page: 2)
  end

  test "a hello from a station from before `tasks` gives from what it was given, as before",
       context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})
    assert_sent(context.row, 2)
    assert {:ok, %{}} = StationTasks.hello(context.view, %{})
    settle_refute_receive({:asked, _, _, _}, 300)
  end

  test "the station's Session writes into the Task as the Worker, once per key; another device writes nothing",
       context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})

    post = %{
      "task" => "cnv_task",
      "session" => "ember:c-1",
      "text" => "built",
      "key" => "k1",
      "declared" => "all_done"
    }

    assert {:ok, %{"seq" => 3}} = StationTasks.post(context.view, post)
    assert {:ok, %{"seq" => 3}} = StationTasks.post(context.view, post)

    assert %{
             "participant_id" => "ptp_worker",
             "metadata" => %{"session" => "ember:c-1", "declared" => "all_done"}
           } =
             List.last(FakeTask.messages())

    # Given back as its own Session's.
    StationTasks.appended(context.row.group_id, "cnv_task")
    settle_receive({:asked, ^run_id, "task.put", %{"messages" => [own]}})

    assert own["author"] == %{
             "kind" => "agent",
             "id" => context.worker["agent_id"],
             "session" => "ember:c-1"
           }

    other = %{context.view | device_id: "device-other"}
    assert {:error, :not_taking_part} = StationTasks.post(other, %{post | "key" => "k2"})

    assert {:error, :not_taking_part} =
             StationTasks.post(context.view, %{post | "session" => "ember:c-2", "key" => "k3"})

    assert length(FakeTask.messages()) == 3
  end

  test "a Session whose turn cannot start says so: a task_run_blocked Message, with why",
       context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})

    assert {:ok, %{"seq" => 3}} =
             StationTasks.post(context.view, %{
               "task" => "cnv_task",
               "session" => "ember:c-1",
               "text" => "⚠️ cannot start: no account",
               "key" => "k1",
               "cannot_start" => %{"error" => "no account is chosen to run Codex"}
             })

    assert %{
             "metadata" => %{
               "message_type" => "task_run_blocked",
               "task_run_blocked" => %{"error" => "no account is chosen to run Codex"},
               "session" => "ember:c-1"
             }
           } = List.last(FakeTask.messages())
  end

  test "the Task moves: the station that ran it is told to leave, and the one that runs it now is given it from its start",
       context do
    run_a = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_a, "task.put", %{"through" => 2}})
    assert {:ok, %{}} = sessions = StationTasks.sessions(context.row.group_id, "cnv_task")
    assert sessions == {:ok, %{context.view.device_id => "ember:c-1"}}

    # Another station, asked to replace what it had, says so in its invite.
    other = %{context.view | device_id: "device-other"}
    run_b = connect!(other)

    assert {:ok, "ember:c-1"} =
             StationTasks.invite(%{
               tenant_id: other.tenant_id,
               group_id: other.group_id,
               conversation_id: "cnv_task",
               device_id: other.device_id,
               start: %{"requester" => "ann", "runtime" => "claude"},
               replace: true
             })

    assert_received {:asked, ^run_b, "task.invite",
                     %{"replace" => true, "start" => %{"runtime" => "claude"}}}

    to = %{context.row | device_id: other.device_id, session: "ember:c-9"}
    assert :ok = StationTasks.moved(%{group_id: to.group_id, conversation_id: "cnv_task", to: to})
    assert_received {:asked, ^run_a, "task.leave", %{"task" => "cnv_task"}}
    settle_receive({:asked, ^run_b, "task.put", %{"through" => 2}})
    assert_sent(to, 2)

    assert StationTasks.sessions(to.group_id, "cnv_task") ==
             {:ok, %{other.device_id => "ember:c-9"}}

    # What the old Session still posts (a step it was in the middle of) is refused.
    assert {:error, :not_taking_part} =
             StationTasks.post(context.view, %{
               "task" => "cnv_task",
               "session" => "ember:c-1",
               "text" => "late",
               "key" => "late"
             })

    # Into Salix: no station takes part any more.
    assert :ok =
             StationTasks.moved(%{group_id: to.group_id, conversation_id: "cnv_task", to: nil})

    assert_received {:asked, ^run_b, "task.leave", %{"task" => "cnv_task"}}
    assert :not_station = StationTasks.standing(to.group_id, "cnv_task")
  end

  test "a station that was not connected when its Task moved is told to leave it when it says hello",
       context do
    run_id = connect!(context.view)

    # It names a Task it was given, which it no longer takes part in, and one
    # it was given nothing of yet (an invite not yet recorded).
    assert {:ok, %{}} =
             StationTasks.hello(context.view, %{
               "tasks" => [
                 %{"task" => "cnv_moved", "fetched" => 2},
                 %{"task" => "cnv_new", "fetched" => 0}
               ]
             })

    settle_receive({:asked, ^run_id, "task.leave", %{"task" => "cnv_moved"}})
    settle_refute_receive({:asked, ^run_id, "task.leave", %{"task" => "cnv_new"}}, 300)
  end

  test "the station's Session records milestones: blocks of its Message, alone without text, given back with it",
       context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})
    post = %{"task" => "cnv_task", "session" => "ember:c-1", "key" => "k1"}

    assert {:ok, %{"seq" => 3}} =
             StationTasks.post(
               context.view,
               Map.merge(post, %{"text" => "", "milestones" => ["Built it"]})
             )

    # The giver may read between posts. Confirm the first delivery before
    # adding the next Message, rather than requiring both in one batch.
    StationTasks.appended(context.row.group_id, "cnv_task")
    assert_sent(context.row, 3)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 3, "messages" => [alone]}})

    assert {:ok, %{"seq" => 4}} =
             StationTasks.post(
               context.view,
               Map.merge(post, %{"key" => "k2", "text" => "built", "milestones" => ["Tested it"]})
             )

    assert [
             %{"content" => [%{"type" => "milestone", "title" => "Built it"}]},
             %{
               "content" => [
                 %{"type" => "milestone", "title" => "Tested it"},
                 %{"type" => "text", "text" => "built"}
               ]
             }
           ] = Enum.drop(FakeTask.messages(), 2)

    # Nothing at all is no Message.
    assert {:error, :bad_request} =
             StationTasks.post(context.view, Map.merge(post, %{"key" => "k3", "text" => ""}))

    # Given back as its own Session's, with their milestones.
    StationTasks.appended(context.row.group_id, "cnv_task")
    assert_sent(context.row, 4)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 4, "messages" => [built]}})
    assert %{"text" => "", "milestones" => ["Built it"]} = alone
    assert %{"text" => "built", "milestones" => ["Tested it"]} = built
    settle()
    refute_received {:asked, ^run_id, "task.put", _}
  end

  # Past the first steps of the giver's backoff (1 s, then 2 s): a wake asked
  # again on it would show. The clock walks through every timer of the running
  # applications, so a span of minutes costs tens of real seconds.
  @no_retry_ms 5_000

  describe "a station that is the Group's Cloud VM" do
    setup context do
      {:ok, group} =
        Salix.Control.Groups.create(
          %{
            "name" => "Station tasks, with a Cloud VM",
            "billing_owner" => %{
              "billing_account_id" => "ba-station-tasks",
              "surface" => "bridge"
            }
          },
          context.view.tenant_id
        )

      group = group["group_id"]
      device = SalixStore.RuntimeIds.cloud_vm_device_id(group)

      {:ok, _vm, :created} =
        GroupCompute.ensure_group_workload(%{
          "tenant_id" => context.view.tenant_id,
          "group_id" => group,
          "provider" => "cloudflare",
          "provider_resource_name" =>
            SalixStore.RuntimeIds.cloud_vm_provider_resource_name(group),
          "env_id" => SalixStore.RuntimeIds.cloud_vm_env_id(group),
          "device_id" => device,
          "connector_id" => SalixStore.RuntimeIds.cloud_vm_connector_id(group),
          "alias" => "cloud-vm",
          "status" => "creating",
          "created_at" => SystemsClock.system_time(:millisecond)
        })

      vm!(group, &Map.merge(&1, %{"status" => "archived", "archived_at" => 1}))

      start_supervised!(Billing)
      previous = SystemsRuntime.get_env(:salix_web, :vm_authorization_mod)
      SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, Billing)

      on_exit(fn ->
        if previous,
          do: SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, previous),
          else: SystemsRuntime.delete_env(:salix_web, :vm_authorization_mod)
      end)

      {:ok,
       group: group,
       view: %{context.view | group_id: group, device_id: device},
       row: %{context.row | group_id: group, device_id: device}}
    end

    test "where the Cloud VM's station stands: its Workload status", context do
      assert :ok = StationTasks.joined(context.row)

      assert {:ok, %{place: :cloud_vm, connected?: false, sent: 0, vm_status: "archived"}} =
               StationTasks.standing(context.group, "cnv_task")

      vm!(context.group, &Map.put(&1, "status", "ready"))

      assert {:ok, %{place: :cloud_vm, vm_status: "ready"}} =
               StationTasks.standing(context.group, "cnv_task")
    end

    test "a Message for it while its VM is archived asks for the VM's wake once, and is given when its station says hello",
         context do
      assert :ok = StationTasks.joined(context.row)

      # Not connected, so nothing is asked of it: its VM's wake is asked for.
      settle_receive({:billing_asked, group})
      assert group == context.group
      assert_wake_requested(context.group)

      # Asked once: nothing asks again while the VM is on its way.
      settle_refute_receive({:billing_asked, _}, @no_retry_ms)
      refute_received {:asked, _, _, _}
      assert_sent(context.row, 0)

      # The VM is up; its station connects and says hello.
      vm!(context.group, &(&1 |> Map.put("status", "ready") |> Map.delete("wake_requested_at")))
      run_id = connect!(context.view)
      assert {:ok, %{}} = StationTasks.hello(context.view, %{})

      settle_receive({:asked, ^run_id, "task.put", %{"messages" => [_, _], "through" => 2}})
      assert_sent(context.row, 2)
      refute_received {:billing_asked, _}
    end

    test "a second Message while the VM wakes is part of the same wake", context do
      assert :ok = StationTasks.joined(context.row)
      settle_receive({:billing_asked, _})
      assert_wake_requested(context.group)

      # The wake is under way, as the Compute reconciler leaves it.
      vm!(context.group, fn vm ->
        vm
        |> Map.merge(%{
          "status" => "waking",
          "wake_operation_id" => "wake-1",
          "last_wake_at" => 2
        })
        |> Map.delete("wake_requested_at")
      end)

      waking = vm(context.group)

      FakeTask.add(%{
        "actor_type" => "user",
        "user_id" => "usr_ann",
        "content" => "said while it wakes",
        "created_at" => 3
      })

      StationTasks.appended(context.group, "cnv_task")
      settle_receive({:billing_asked, _})
      settle_refute_receive({:billing_asked, _}, @no_retry_ms)

      # The same wake: no second one was asked for.
      keys = ~w(status wake_operation_id last_wake_at wake_requested_at generation)
      assert Map.take(vm(context.group), keys) == Map.take(waking, keys)
      refute_received {:asked, _, _, _}

      vm!(context.group, &(&1 |> Map.put("status", "ready") |> Map.delete("wake_operation_id")))
      run_id = connect!(context.view)
      assert {:ok, %{}} = StationTasks.hello(context.view, %{})

      settle_receive(
        {:asked, ^run_id, "task.put", %{"messages" => [_, _, %{"text" => "said while it wakes"}]}}
      )

      assert_sent(context.row, 3)
    end

    test "a Task made while the VM is archived: its station is expected, the VM woken, and it is invited and given the Task when it says hello",
         context do
      invitation = %{
        tenant_id: context.view.tenant_id,
        group_id: context.group,
        conversation_id: "cnv_task",
        device_id: context.view.device_id,
        agent_id: context.worker["agent_id"],
        start: %{"requester" => "ann", "runtime" => "codex", "model" => "gpt-5.4-mini"}
      }

      # Not connected, the Cloud VM's station is not asked: the Task is made for it.
      assert {:ok, :when_connected} = StationTasks.invite(invitation)
      refute_received {:asked, _, _, _}
      assert :ok = StationTasks.joined(Map.put(invitation, :session, nil))

      # Expected in the Task, given nothing, with what it will be invited with;
      # the VM's wake is asked for.
      assert {:ok, [row]} = StationTaskSessions.of_task(context.group, "cnv_task")
      assert StationTaskSessions.awaited?(row)
      assert %{sent: 0, start: %{"model" => "gpt-5.4-mini"}} = row
      settle_receive({:billing_asked, _})
      assert_wake_requested(context.group)

      assert {:ok, %{place: :cloud_vm, connected?: false, sent: 0, vm_status: "archived"}} =
               StationTasks.standing(context.group, "cnv_task")

      assert :unknown = StationTasks.session_status(context.group, "cnv_task")

      # The create asked again: expected once, the same wake.
      waking = vm(context.group)
      assert {:ok, :when_connected} = StationTasks.invite(invitation)
      assert :ok = StationTasks.joined(Map.put(invitation, :session, nil))
      settle_receive({:billing_asked, _})
      assert {:ok, [^row]} = StationTaskSessions.of_task(context.group, "cnv_task")

      assert Map.take(vm(context.group), ~w(status wake_requested_at)) ==
               Map.take(waking, ~w(status wake_requested_at))

      refute_received {:asked, _, _, _}

      # The VM is up; its station connects and says hello: invited as the Task
      # was made, then given the Task from its start, once each.
      vm!(context.group, &(&1 |> Map.put("status", "ready") |> Map.delete("wake_requested_at")))
      run_id = connect!(context.view)
      assert {:ok, %{}} = StationTasks.hello(context.view, %{"tasks" => []})

      settle_receive(
        {:asked, ^run_id, "task.invite",
         %{"task" => "cnv_task", "start" => %{"model" => "gpt-5.4-mini", "requester" => "ann"}}}
      )

      settle_receive({:asked, ^run_id, "task.put", %{"messages" => [_, _], "through" => 2}})
      assert_sent(context.row, 2)

      assert {:ok, [%{session: "ember:c-1", sent: 2, answered: 0}]} =
               StationTaskSessions.of_task(context.group, "cnv_task")

      refute_received {:asked, _, "task.invite", _}
      refute_received {:asked, _, "task.put", _}

      # The station's Session takes part as any does: its status is asked of it.
      assert {:ok, %{state: :cannot_start}} =
               StationTasks.session_status(context.group, "cnv_task")

      # A person's station of the Group that is not connected is refused as before.
      laptop = "device-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      assert {:error, :device_offline} = StationTasks.invite(%{invitation | device_id: laptop})
    end

    test "the Cloud VM's station connected while the VM wakes is not invited: it is once the VM is ready",
         context do
      invitation = %{
        tenant_id: context.view.tenant_id,
        group_id: context.group,
        conversation_id: "cnv_task",
        device_id: context.view.device_id,
        agent_id: context.worker["agent_id"],
        start: %{"requester" => "ann", "runtime" => "codex", "model" => "gpt-5.4-mini"}
      }

      assert {:ok, :when_connected} = StationTasks.invite(invitation)
      assert :ok = StationTasks.joined(Map.put(invitation, :session, nil))
      settle_receive({:billing_asked, _})
      assert_wake_requested(context.group)

      # The wake is under way. A station connects and says hello (the Container
      # before, still shown connected; or the woken one, before Salix has its
      # restore receipt): not asked, the VM is not ready.
      waking =
        vm!(context.group, fn vm ->
          vm
          |> Map.merge(%{
            "status" => "waking",
            "wake_operation_id" => "wake-1",
            "last_wake_at" => 2
          })
          |> Map.delete("wake_requested_at")
        end)

      run_id = connect!(context.view)
      assert {:ok, %{}} = StationTasks.hello(context.view, %{"tasks" => []})
      settle_refute_receive({:asked, _, _, _}, @no_retry_ms)

      # A Task made now is made for it the same way, nothing asked of it.
      assert {:ok, :when_connected} = StationTasks.invite(invitation)
      refute_received {:asked, _, _, _}
      assert {:ok, [row]} = StationTaskSessions.of_task(context.group, "cnv_task")
      assert StationTaskSessions.awaited?(row)

      # The VM's provider commits ready: the station is invited and given the Task.
      ready =
        vm!(context.group, &(&1 |> Map.put("status", "ready") |> Map.delete("wake_operation_id")))

      assert :ok = StationTasks.vm_ready(waking, ready)
      settle_receive({:asked, ^run_id, "task.invite", %{"task" => "cnv_task"}})
      settle_receive({:asked, ^run_id, "task.put", %{"messages" => [_, _], "through" => 2}})
      assert_sent(context.row, 2)

      # A ready record written again is nothing to the station.
      assert :ok = StationTasks.vm_ready(ready, ready)
      settle_refute_receive({:asked, _, _, _}, @no_retry_ms)
    end

    test "a station expected in a Task that refuses it when invited is expected no more",
         context do
      invitation = %{
        tenant_id: context.view.tenant_id,
        group_id: context.group,
        conversation_id: "cnv_task",
        device_id: context.view.device_id,
        agent_id: context.worker["agent_id"],
        start: %{"requester" => "ann", "runtime" => "codex", "model" => "gpt-5.4-mini"}
      }

      assert {:ok, :when_connected} = StationTasks.invite(invitation)
      assert :ok = StationTasks.joined(Map.put(invitation, :session, nil))
      settle_receive({:billing_asked, _})

      vm!(context.group, &(&1 |> Map.put("status", "ready") |> Map.delete("wake_requested_at")))
      run_id = connect!(context.view)
      Station.answer(:refuse)

      log =
        capture_log(fn ->
          assert {:ok, %{}} = StationTasks.hello(context.view, %{"tasks" => []})
          settle_receive({:asked, ^run_id, "task.invite", %{"task" => "cnv_task"}})

          settle_until(fn ->
            StationTaskSessions.of_task(context.group, "cnv_task") == {:ok, []}
          end)
        end)

      assert log =~ "did not take it; it is expected no more"
      assert log =~ "no profile runs gpt-5.4-mini"
      refute_received {:asked, _, "task.put", _}
      assert :not_station = StationTasks.standing(context.group, "cnv_task")
    end

    test "a Task made for a Group whose VM cannot be made says so once, and leaves the station expected",
         context do
      {:ok, group} =
        Salix.Control.Groups.create(%{"name" => "Station tasks, no VM"}, context.view.tenant_id)

      group = group["group_id"]
      device = SalixStore.RuntimeIds.cloud_vm_device_id(group)

      invitation = %{
        tenant_id: context.view.tenant_id,
        group_id: group,
        conversation_id: "cnv_task",
        device_id: device,
        agent_id: context.worker["agent_id"],
        start: %{"requester" => "ann"}
      }

      assert {:ok, :when_connected} = StationTasks.invite(invitation)

      # The Task's Worker is of another Group: no VM is made for it.
      log =
        capture_log(fn ->
          assert :ok = StationTasks.joined(Map.put(invitation, :session, nil))
          settle_refute_receive({:billing_asked, _}, @no_retry_ms)
        end)

      assert log =~ "was not woken"
      assert {:error, :not_found} = GroupCompute.group_workload(group)
      assert {:ok, [row]} = StationTaskSessions.of_task(group, "cnv_task")
      assert StationTaskSessions.awaited?(row)
    end

    test "another station of the Group that is not connected wakes no VM", context do
      row = %{
        context.row
        | device_id: "device-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      }

      assert :ok = StationTasks.joined(row)

      settle_refute_receive({:billing_asked, _}, @no_retry_ms)
      refute_received {:asked, _, _, _}
      refute Map.has_key?(vm(context.group), "wake_requested_at")
    end

    test "a wake that cannot be made is said once and leaves the Message to give; the next Message asks again",
         context do
      Billing.answer({:error, :billing_ledger_down})

      log =
        capture_log(fn ->
          assert :ok = StationTasks.joined(context.row)
          settle_receive({:billing_asked, _})
          # Not asked again by itself.
          settle_refute_receive({:billing_asked, _}, @no_retry_ms)
        end)

      assert [_, said] = String.split(log, "was not woken")
      assert said =~ "billing_ledger_down"
      assert %{"status" => "archived"} = vm = vm(context.group)
      refute Map.has_key?(vm, "wake_requested_at")
      refute_received {:asked, _, _, _}
      assert_sent(context.row, 0)

      # Billing answers again: the next Message for the station wakes its VM.
      Billing.answer(:ok)

      FakeTask.add(%{
        "actor_type" => "user",
        "user_id" => "usr_ann",
        "content" => "said later",
        "created_at" => 3
      })

      StationTasks.appended(context.group, "cnv_task")
      settle_receive({:billing_asked, _})
      assert_wake_requested(context.group)
    end
  end

  # As `SalixWeb.CloudVM.RuntimeLifecycle.wake/1` leaves an archived VM for the Compute reconciler.
  defp assert_wake_requested(group) do
    settle_until(fn ->
      match?(%{"status" => "archived", "wake_requested_at" => at} when is_integer(at), vm(group))
    end)
  end

  defp vm(group) do
    {:ok, vm} = GroupCompute.group_workload(group)
    vm
  end

  defp vm!(group, change) do
    {:ok, vm, _previous} = GroupCompute.update_group_workload(group, change)
    vm
  end

  defp assert_answered(row, seq) do
    assert {:ok, [%{answered: ^seq}]} =
             StationTaskSessions.of_task(row.group_id, row.conversation_id)
  end

  defp bound_worker!(context, provider) do
    {:ok, worker} =
      SalixAgent.Control.create(
        %{
          "group_id" => context.view.group_id,
          "name" => "Bound",
          "role" => "worker",
          "station_binding" => %{
            "runs_on" => %{"kind" => "cloud_vm"},
            "model" => %{"kind" => "runtime", "provider" => provider}
          }
        },
        context.view.tenant_id
      )

    worker["agent_id"]
  end

  defp assert_sent(row, seq) do
    settle_until(fn ->
      match?(
        {:ok, [%{sent: ^seq}]},
        StationTaskSessions.of_task(row.group_id, row.conversation_id)
      )
    end)
  end

  test "a station is told the files an Agent's Message brings and reads them a part at a time; nothing else",
       context do
    run_id = connect!(context.view)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})

    part = 256 * 1024
    bytes = :binary.copy(<<7>>, part + 10)
    ref = %{"kind" => "blob", "uuid" => "b1", "size" => byte_size(bytes)}
    FakeTask.blob(ref, bytes)

    FakeTask.add(%{
      "message_id" => "msg_file",
      "actor_type" => "agent",
      "agent_id" => "agt_router",
      "content" => [
        %{"type" => "text", "text" => "Source file for this Task:"},
        %{
          "type" => "file",
          "path" => "/uploads/demo.mp4",
          "file_name" => "demo.mp4",
          "blob_ref" => ref
        },
        # Not bound to a blob: not a file it can be given.
        %{"type" => "file", "path" => "/uploads/other.mp4"}
      ],
      "created_at" => 3
    })

    StationTasks.appended(context.row.group_id, "cnv_task")
    settle_receive({:asked, ^run_id, "task.put", %{"messages" => [given]}})

    assert given["id"] == "msg_file"
    assert given["text"] == "Source file for this Task:"
    assert given["files"] == [%{"index" => 1, "name" => "demo.mp4", "size" => byte_size(bytes)}]

    ask = %{"task" => "cnv_task", "session" => "ember:c-1", "id" => "msg_file", "index" => 1}

    assert {:ok, %{"name" => "demo.mp4", "size" => size, "offset" => 0, "data" => first}} =
             StationTasks.file(context.view, Map.put(ask, "offset", 0))

    assert {:ok, %{"offset" => ^part, "data" => rest}} =
             StationTasks.file(context.view, Map.put(ask, "offset", part))

    assert size == byte_size(bytes)
    assert Base.decode64!(first) <> Base.decode64!(rest) == bytes

    for missing <- [%{ask | "index" => 2}, %{ask | "index" => 0}, %{ask | "id" => "msg_none"}] do
      assert {:ok, %{"missing" => _}} =
               StationTasks.file(context.view, Map.put(missing, "offset", 0))
    end

    # A person's unbound file metadata grants no read, whatever its parts say.
    FakeTask.add(%{
      "message_id" => "msg_person",
      "actor_type" => "user",
      "user_id" => "usr_ann",
      "content" => [%{"type" => "file", "path" => "/x", "blob_ref" => ref}],
      "created_at" => 4
    })

    StationTasks.appended(context.row.group_id, "cnv_task")
    settle_receive({:asked, ^run_id, "task.put", %{"messages" => [person]}})
    refute Map.has_key?(person, "files")

    assert {:ok, %{"missing" => _}} =
             StationTasks.file(
               context.view,
               Map.merge(ask, %{"id" => "msg_person", "index" => 0, "offset" => 0})
             )

    other = %{context.view | device_id: "device-other"}
    assert {:error, :not_taking_part} = StationTasks.file(other, Map.put(ask, "offset", 0))
  end

  test "a Group Cloud VM's station at work in a Task restarts the VM's idle clock: given a Message, and posting one",
       context do
    group = context.view.group_id
    device = SalixStore.RuntimeIds.cloud_vm_device_id(group)
    view = %{context.view | device_id: device}
    row = %{context.row | device_id: device}

    {:ok, _rec, :created} =
      SalixStore.Compute.ensure_group_workload(%{
        "tenant_id" => view.tenant_id,
        "group_id" => group,
        "provider" => "cloudflare",
        "provider_resource_id" => "sandbox-" <> group,
        "provider_resource_name" => SalixStore.RuntimeIds.cloud_vm_provider_resource_name(group),
        "provider_spec" => %{"profile_key" => "cf-standard-2"},
        "env_id" => SalixStore.RuntimeIds.cloud_vm_env_id(group),
        "device_id" => device,
        "connector_id" => SalixStore.RuntimeIds.cloud_vm_connector_id(group),
        "alias" => "cloud-vm",
        "status" => "ready",
        "ready_at" => 1,
        "archive_retry_at" => 4_000_000_000_000,
        "archive_refusals" => 2,
        "created_at" => 1
      })

    run_id = connect!(view)
    assert :ok = StationTasks.joined(row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})

    # Given the Task: the wait after a refused idle archive is over.
    active =
      settle_until(fn ->
        case SalixStore.Compute.group_workload(group) do
          {:ok, %{"last_station_activity_at" => at} = rec} when is_integer(at) -> rec
          _ -> nil
        end
      end)

    given = active["last_station_activity_at"]
    refute Map.has_key?(active, "archive_retry_at")
    refute Map.has_key?(active, "archive_refusals")

    # A while later, its Session posts: the clock restarts at the post.
    {:ok, _, _} =
      SalixStore.Compute.update_group_workload(group, fn rec ->
        rec
        |> Map.put("last_station_activity_at", given - 60_000)
        |> Map.put("archive_retry_at", 4_000_000_000_000)
      end)

    assert {:ok, %{"seq" => 3}} =
             StationTasks.post(view, %{
               "task" => "cnv_task",
               "session" => "ember:c-1",
               "text" => "built",
               "key" => "k1"
             })

    assert {:ok, %{"last_station_activity_at" => posted} = rec} =
             SalixStore.Compute.group_workload(group)

    assert posted >= given
    refute Map.has_key?(rec, "archive_retry_at")
  end

  defp connect!(view) do
    transport_id = "station-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    proof =
      case GroupCompute.group_workload(view.group_id) do
        {:ok, %{"device_id" => device, "workload_id" => id, "generation" => generation}}
        when device == view.device_id ->
          %{"workload_id" => id, "workload_generation" => generation}

        _ ->
          %{}
      end

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => view.tenant_id,
          "group_id" => view.group_id,
          "device_id" => view.device_id,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Laptop"
        }
        |> Map.merge(proof),
        transport_id: transport_id
      )

    record["connector_run_id"]
  end

  test "a post's files are read from its station, part by part, and the Message brings them after its text",
       context do
    run_id = connect!(context.view)
    view = Map.put(context.view, :connector_run_id, run_id)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})
    big = SystemsRuntime.Proc.random_bytes(600 * 1024)
    small = "a short note\n"
    SystemsRuntime.put_env(:salix_web, :station_tasks_posted_files, %{0 => big, 1 => small})
    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :station_tasks_posted_files) end)

    post = %{
      "task" => "cnv_task",
      "session" => "ember:c-1",
      "text" => "the report and its notes",
      "key" => "k1",
      "files" => [
        %{"index" => 0, "name" => "report.bin", "size" => byte_size(big)},
        %{"index" => 1, "name" => "../notes.txt", "size" => byte_size(small)}
      ]
    }

    assert {:ok, %{"seq" => seq}} = StationTasks.post(view, post)

    # Asked over the post's own connection, 256 KiB at a time.
    for offset <- [0, 256 * 1024, 512 * 1024],
        do:
          assert_received(
            {:asked, ^run_id, "task.posted_file",
             %{"key" => "k1", "index" => 0, "offset" => ^offset}}
          )

    assert_received {:asked, ^run_id, "task.posted_file", %{"index" => 1, "offset" => 0}}

    message = Enum.find(FakeTask.messages(), &(&1["seq"] == seq))

    assert [
             %{"type" => "text", "text" => "the report and its notes"},
             %{"type" => "file", "path" => report, "file_name" => "report.bin"} = report_block,
             %{"type" => "file", "path" => notes, "file_name" => "notes.txt"} = notes_block
           ] = message["content"]

    # Each read back byte for byte, in the Worker's VFS under the Task.
    placed = FakeTask.placed()
    assert {agent, uuid} = placed[report]
    # The block names the blob it placed, with string keys as the Message is
    # read back, so a client reads it as an agent-sent file.
    assert report_block["blob_ref"] == %{
             "kind" => "blob",
             "uuid" => uuid,
             "size" => byte_size(big),
             "hash" => SalixStore.Crypto.hex(big)
           }

    assert notes_block["blob_ref"]["uuid"] == elem(placed[notes], 1)
    assert notes_block["blob_ref"]["size"] == byte_size(small)
    assert agent == context.row.agent_id
    assert FakeTask.bytes(uuid) == big
    assert FakeTask.bytes(elem(placed[notes], 1)) == small
    assert String.starts_with?(report, "/uploads/tasks/cnv_task/")
    assert String.ends_with?(notes, "/1-notes.txt")
  end

  test "a post whose file cannot be read fails, and nothing is written into the Task", context do
    run_id = connect!(context.view)
    view = Map.put(context.view, :connector_run_id, run_id)
    assert :ok = StationTasks.joined(context.row)
    settle_receive({:asked, ^run_id, "task.put", %{"through" => 2}})
    SystemsRuntime.put_env(:salix_web, :station_tasks_posted_files, %{})
    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :station_tasks_posted_files) end)
    before = length(FakeTask.messages())

    post = %{
      "task" => "cnv_task",
      "session" => "ember:c-1",
      "text" => "see the log",
      "key" => "k1",
      "files" => [%{"index" => 0, "name" => "run.log", "size" => 10}]
    }

    assert {:error, {:bad_request, why}} = StationTasks.post(view, post)
    assert why =~ "run.log"
    assert length(FakeTask.messages()) == before
    assert [_aborted] = FakeTask.aborted()
  end
end
