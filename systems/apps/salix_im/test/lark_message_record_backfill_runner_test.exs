defmodule SalixIM.LarkMessageRecordBackfillRunnerTest do
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:lark_mirror_backfill]
  use SalixAgent.TestSupport.Settle

  @moduletag :capture_log

  alias SalixIM.LarkMessageRecord.BackfillRunner
  alias SalixStore.{LarkMirrorBackfillLedger, Repo, ULID}

  defmodule Script do
    use Agent

    def start_link(_opts),
      do:
        Agent.start_link(
          fn -> %{connects: [], claims: 0, claim: :normal, pass: :idle, rows: [], pages: []} end,
          name: __MODULE__
        )

    def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
    def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))

    def claim do
      Agent.get_and_update(__MODULE__, fn state ->
        {state.claim, %{state | claims: state.claims + 1}}
      end)
    end

    def page do
      Agent.get_and_update(__MODULE__, fn %{pages: [page | rest]} = state ->
        {page, %{state | pages: rest}}
      end)
    end

    def write(rows), do: Agent.update(__MODULE__, &%{&1 | rows: &1.rows ++ rows})
  end

  defmodule Connects do
    def list_lark_message_record_backfill_connects(_limit, _cursor),
      do: {:ok, %{candidates: Script.get(:connects), next_cursor: nil, scan_complete: true}}

    def get_active_connect_by_id(_group, id, "lark") do
      case Enum.find(Script.get(:connects), &(&1["connect_id"] == id)) do
        nil -> {:error, :not_found}
        connect -> {:ok, connect}
      end
    end
  end

  defmodule Ledger do
    require SystemsRuntime.Proc

    def claim_due_connect(ttl) do
      case Script.claim() do
        :normal ->
          LarkMirrorBackfillLedger.claim_due_connect(ttl)

        :crash ->
          raise "claim unavailable"

        :park ->
          park()
          LarkMirrorBackfillLedger.claim_due_connect(ttl)

        # Reads the ledger first, then holds the answer.
        :read_then_park ->
          result = LarkMirrorBackfillLedger.claim_due_connect(ttl)
          park()
          result
      end
    end

    defp park do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :lark_runner_parent),
        {:claim, SystemsRuntime.Proc.self()}
      )

      SystemsRuntime.Proc.receive do
        :continue -> :ok
      end
    end

    defdelegate discovery(scope), to: LarkMirrorBackfillLedger
    defdelegate commit_discovery(scope, token), to: LarkMirrorBackfillLedger
    defdelegate upsert_connects(connects), to: LarkMirrorBackfillLedger
    defdelegate finish_connect(id, delay, error), to: LarkMirrorBackfillLedger
    defdelegate delete_connect(id), to: LarkMirrorBackfillLedger
    defdelegate next_containers(scope, budget), to: LarkMirrorBackfillLedger
    defdelegate upsert_containers(scope, containers), to: LarkMirrorBackfillLedger
    defdelegate commit_page(scope, container, page), to: LarkMirrorBackfillLedger
    defdelegate fail_container(scope, container, reason), to: LarkMirrorBackfillLedger
    defdelegate close_refused_container(scope, container, refusal), to: LarkMirrorBackfillLedger
  end

  defmodule Reader do
    require SystemsRuntime.Proc

    def list_chats(connect, _token) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :lark_runner_parent),
        {:pass, SystemsRuntime.Proc.self(), connect["connect_id"]}
      )

      case Script.get(:pass) do
        :idle ->
          :ok

        :crash ->
          raise "pass unavailable"

        :park ->
          SystemsRuntime.Proc.receive do
            :continue -> :ok
          end
      end

      {:ok, %{"items" => [], "has_more" => false}}
    end

    def list_messages(_connect, _container, _token, _end_time), do: Script.page()
  end

  defmodule Writer do
    def record_batch(_rows), do: :ok
    def write_batch(rows), do: Script.write(rows)
  end

  setup do
    Repo.query!("TRUNCATE lark_mirror_containers")
    start_supervised!(Script)
    SystemsRuntime.Test.put_env(:salix_im, :lark_message_record_mod, Writer)
    SystemsRuntime.Test.put_env(:salix_im, :lark_runner_parent, SystemsRuntime.Proc.self())
    :ok
  end

  test "repeated discovery and pass completions leave one idle claim per interval" do
    runner = runner()
    settle()

    for _round <- 1..5 do
      Script.put(:connects, [connect()])
      send(runner, :discover_tick)
      settle()
      assert_received {:pass, _, _}
      count = Script.get(:claims)

      for interval <- 1..4 do
        settle_after(30_000)
        assert Script.get(:claims) == count + interval
      end
    end
  end

  test "canceled work timer deliveries do not make another claim" do
    runner = runner()
    settle()
    {old_ref, _due} = :sys.get_state(runner).work_timer
    send(runner, :discover_tick)
    settle()
    count = Script.get(:claims)
    send(runner, {:timeout, old_ref, :work_tick})
    settle()
    assert Script.get(:claims) == count
    settle_after(30_000)
    assert Script.get(:claims) == count + 1
  end

  test "one claim fills bounded pass slots and completion fills the next slot" do
    connects = for _ <- 1..3, do: connect()
    Script.put(:connects, connects)
    Script.put(:claim, :park)
    Script.put(:pass, :park)
    runner = runner()
    settle_receive({:claim, claim})

    for _ <- 1..20, do: send(runner, :work_tick)
    send(runner, :discover_tick)
    settle()
    refute_received {:claim, _}
    assert Script.get(:claims) == 1
    Script.put(:claim, :normal)
    send(claim, :continue)
    settle_receive({:pass, first, first_id})
    settle_receive({:pass, second, second_id})
    refute first_id == second_id
    refute_received {:pass, _, _}
    assert Script.get(:claims) == 2
    send(first, :continue)
    settle_receive({:pass, third, third_id})
    assert third_id not in [first_id, second_id]
    send(second, :continue)
    send(third, :continue)
    settle()
  end

  test "discovery that lands while a claim runs is claimed without waiting for the idle timer" do
    Script.put(:claim, :read_then_park)
    runner = runner()
    # The claim read an empty ledger and holds its empty answer.
    settle_receive({:claim, claim})
    connect = connect()
    Script.put(:connects, [connect])
    send(runner, :discover_tick)
    settle()
    Script.put(:claim, :normal)
    send(claim, :continue)
    settle()
    id = connect["connect_id"]
    assert_received {:pass, _, ^id}
  end

  test "claim failures keep one backoff and recover due work" do
    Script.put(:claim, :crash)
    runner = runner()
    settled(runner)
    assert Process.alive?(runner)
    count = Script.get(:claims)

    for interval <- 1..4 do
      settle_after(60_000)
      settled(runner)
      assert Script.get(:claims) == count + interval
    end

    Script.put(:claim, :normal)
    Script.put(:connects, [connect()])
    send(runner, :discover_tick)
    settle()
    assert_received {:pass, _, _}
  end

  test "repeated crashed passes recover after their durable leases expire" do
    runner = runner(lease_ttl_ms: 60_000)
    settled(runner)

    for _round <- 1..3 do
      Script.put(:connects, [connect()])
      Script.put(:pass, :crash)
      send(runner, :discover_tick)
      settled(runner)
      assert_received {:pass, _, id}
      Script.put(:pass, :idle)
      count = Script.get(:claims)
      settle_after(30_000)
      settled(runner)
      assert Script.get(:claims) == count + 1
      refute_received {:pass, _, _}
      settle_after(30_000)
      settled(runner)
      refute_received {:pass, _, _}
      settle_after(30_000)
      settled(runner)
      assert_received {:pass, _, ^id}
      count = Script.get(:claims)
      settle_after(30_000)
      settled(runner)
      assert Script.get(:claims) == count + 1
    end
  end

  test "the pump drains real pages and retries a failed page from its watermark" do
    connect = connect()
    scope = Map.take(connect, ~w(tenant_id app_id))
    container = %{"container_type" => "chat", "container_id" => "oc_chat", "chat_id" => "oc_chat"}
    Script.put(:connects, [connect])
    :ok = LarkMirrorBackfillLedger.upsert_containers(scope, [container])
    :ok = LarkMirrorBackfillLedger.commit_discovery(scope, nil)

    Script.put(:pages, [
      page("om_new", "2000", "older"),
      {:error, :unavailable},
      page("om_new", "2000", "older"),
      page("om_old", "1000", nil)
    ])

    _runner = runner(page_budget: 1)
    settle()
    assert {:ok, {:incomplete, 2_000_000}} = LarkMirrorBackfillLedger.coverage(scope, nil, 0)
    assert Enum.map(Script.get(:rows), & &1["message_id"]) == ["om_new"]
    settle_after(60_000)
    assert {:ok, :complete} = LarkMirrorBackfillLedger.coverage(scope, nil, 0)
    assert Enum.map(Script.get(:rows), & &1["message_id"]) == ~w(om_new om_new om_old)
    assert Script.get(:pages) == []
  end

  test "a chat refused as external waits for the next listing and leaves the rest walking" do
    connect = connect()
    scope = Map.take(connect, ~w(tenant_id app_id))

    container = %{
      "container_type" => "chat",
      "container_id" => "oc_external",
      "chat_id" => "oc_external"
    }

    Script.put(:connects, [connect])
    :ok = LarkMirrorBackfillLedger.upsert_containers(scope, [container])

    Script.put(:pages, [
      {:error,
       "Lark API error 230027 (HTTP 400): Lack of necessary permissions, ext=no permission to operate external chats."}
    ])

    _runner = runner()
    settle()
    settle_after(60_000)

    # One refused request: the chat is out of the walk, not retried each minute.
    assert Script.get(:pages) == []
    assert {:ok, []} = LarkMirrorBackfillLedger.next_containers(scope, 1)
    assert {:ok, {:incomplete, nil}} = LarkMirrorBackfillLedger.coverage(scope, "oc_external", 0)

    # The next listing puts it back.
    :ok = LarkMirrorBackfillLedger.upsert_containers(scope, [container])

    assert {:ok, [%{"container_id" => "oc_external"}]} =
             LarkMirrorBackfillLedger.next_containers(scope, 1)
  end

  test "a chat refused for want of a scope waits for the next listing and leaves the rest walking" do
    connect = connect()
    scope = Map.take(connect, ~w(tenant_id app_id))

    container = %{
      "container_type" => "chat",
      "container_id" => "oc_scope",
      "chat_id" => "oc_scope"
    }

    Script.put(:connects, [connect])
    :ok = LarkMirrorBackfillLedger.upsert_containers(scope, [container])

    Script.put(:pages, [
      {:error,
       "Lark API error 230027 (HTTP 400): Lack of necessary permissions, ext=need scope: im:message.group_msg."}
    ])

    _runner = runner()
    settle()
    settle_after(60_000)

    # Asking again cannot succeed until a person gives the app the scope.
    assert Script.get(:pages) == []
    assert {:ok, []} = LarkMirrorBackfillLedger.next_containers(scope, 1)
    assert {:ok, {:incomplete, nil}} = LarkMirrorBackfillLedger.coverage(scope, "oc_scope", 0)

    # The next listing puts it back.
    :ok = LarkMirrorBackfillLedger.upsert_containers(scope, [container])

    assert {:ok, [%{"container_id" => "oc_scope"}]} =
             LarkMirrorBackfillLedger.next_containers(scope, 1)
  end

  # settle/0 can return between a task's crash and the runner handling its DOWN,
  # and a count read then misses the claim that DOWN wakes. These tasks never
  # park, so the runner's state says when it rests: no task, and its next tick
  # still ahead on the clock.
  defp settled(runner) do
    settle()

    case :sys.get_state(runner) do
      %{passes: passes, claim_task: nil, discover_task: nil, work_timer: {_ref, due}}
      when passes == %{} ->
        unless due > SystemsClock.monotonic_time(:millisecond), do: settled_again(runner)

      _busy ->
        settled_again(runner)
    end
  end

  defp settled_again(runner) do
    :erlang.yield()
    settled(runner)
  end

  defp runner(opts \\ []) do
    supervisor = start_supervised!({SystemsRuntime.TaskSupervisor, name: __MODULE__.Tasks})

    start_supervised!(
      {BackfillRunner,
       Keyword.merge(
         [
           name: nil,
           task_supervisor: supervisor,
           ledger: Ledger,
           connects: Connects,
           reader: Reader,
           writer: Writer,
           pace_ms: 0,
           start_delay_ms: 0,
           max_concurrent_passes: 2,
           discover_interval_ms: 10_000_000
         ],
         opts
       )}
    )
  end

  defp connect do
    id = ULID.generate()

    %{
      "connect_id" => "imc_" <> id,
      "tenant_id" => "tenant_runner",
      "group_id" => "group_runner",
      "app_id" => "app_" <> id,
      "app_secret" => "secret",
      "status" => "connected"
    }
  end

  defp page(id, time, token) do
    {:ok,
     %{
       "items" => [
         %{
           "message_id" => id,
           "chat_id" => "oc_chat",
           "msg_type" => "text",
           "create_time" => time,
           "body" => %{"content" => Jason.encode!(%{"text" => id})},
           "sender" => %{"id" => "ou_sender", "sender_type" => "user"}
         }
       ],
       "has_more" => token != nil,
       "page_token" => token
     }}
  end
end
