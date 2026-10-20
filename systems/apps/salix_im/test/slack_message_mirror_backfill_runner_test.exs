defmodule SalixIM.SlackMessageMirrorBackfillRunnerTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The scheduler around backfill passes: discovery records installations, a
  work tick claims the one due the longest, and the pass's answer decides when
  it is due again. The pass itself is scripted; its rules are tested in
  `SalixIM.SlackMessageMirrorBackfillTest`.
  """
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:slack_mirror_backfill]

  use SalixAgent.TestSupport.Settle
  alias SalixIM.SlackMessageMirror.BackfillRunner
  alias SalixStore.{Repo, SlackMirrorBackfillLedger, ULID}

  defmodule FakeConnects do
    @moduledoc false
    def list_slack_mirror_backfill_connects(_limit, cursor) do
      case {SystemsRuntime.get_env(:salix_im, :runner_test_connects, []), cursor} do
        {[], _cursor} ->
          {:ok, %{candidates: [], next_cursor: nil, scan_complete: true}}

        {[first | rest], nil} ->
          {:ok, %{candidates: [first], next_cursor: {:rest, rest}, scan_complete: rest == []}}

        {_all, {:rest, [next | rest]}} ->
          {:ok, %{candidates: [next], next_cursor: {:rest, rest}, scan_complete: rest == []}}

        {_all, {:rest, []}} ->
          {:ok, %{candidates: [], next_cursor: nil, scan_complete: true}}
      end
    end

    def get_active_connect_by_id(_group_id, connect_id, "slack") do
      case Enum.find(
             SystemsRuntime.get_env(:salix_im, :runner_test_connects, []),
             &(&1["connect_id"] == connect_id)
           ) do
        nil -> {:error, :not_found}
        connect -> {:ok, connect}
      end
    end
  end

  # The scripted Slack: every installation's bot is in no channel at all, so a
  # real pass answers `:idle` after one listing. Tests that need another
  # answer script the reader per connect.
  defmodule Reader do
    @moduledoc false
    def conversations(credential, _opts) do
      case SystemsRuntime.get_env(:salix_im, :runner_test_answers, %{})[credential] do
        nil -> {:ok, [], nil}
        answer -> answer
      end
    end

    def history(_credential, _channel_id, _opts), do: {:ok, []}
    def replies(_credential, _channel_id, _root_ts, _opts), do: {:ok, [], ""}
  end

  defmodule EnabledMirror do
    @moduledoc false
    def record_batch(_rows), do: :ok
    def record_reaction_batch(_rows), do: :ok
    def record_pin_batch(_rows), do: :ok
    def record_metadata_batch(_rows), do: :ok
  end

  setup do
    Repo.query!("TRUNCATE slack_mirror_channel_watermarks")
    previous_mirror = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_mod)
    SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, EnabledMirror)

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_im, :runner_test_connects)
      SystemsRuntime.delete_env(:salix_im, :runner_test_answers)
      restore_env(:salix_im, :slack_message_mirror_mod, previous_mirror)
    end)

    :ok
  end

  describe "discovery" do
    test "records every page of installations and reports when the scan is complete" do
      connects = [connect(), connect(), connect()]
      SystemsRuntime.put_env(:salix_im, :runner_test_connects, connects)

      assert {:ok, %{next_cursor: cursor, scan_complete: false}} = discover(nil)
      assert {:ok, %{next_cursor: cursor, scan_complete: false}} = discover(cursor)
      assert {:ok, %{scan_complete: true}} = discover(cursor)

      for connect <- connects do
        assert {:ok, %{"group_id" => group}} =
                 SlackMirrorBackfillLedger.connect(connect["connect_id"])

        assert group == connect["group_id"]
      end
    end
  end

  describe "a work tick" do
    test "claims the installation due the longest, runs a pass, and defers it when idle" do
      connect = connect()
      SystemsRuntime.put_env(:salix_im, :runner_test_connects, [connect])
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])

      assert {:ok, :idle} = run_once()
      assert :empty = run_once()

      assert {:ok, %{"leased_until" => nil, "due_at" => due, "updated_at" => updated}} =
               SlackMirrorBackfillLedger.connect(connect["connect_id"])

      assert NaiveDateTime.compare(due, updated) == :gt
    end

    test "an installation with history left is due again at once" do
      connect = connect()
      SystemsRuntime.put_env(:salix_im, :runner_test_connects, [connect])
      # A channel whose walk can never finish, because the page budget is
      # zero, is the cheapest way to make a real pass answer `:more`.
      SystemsRuntime.put_env(:salix_im, :runner_test_answers, %{
        connect["bot_token"] => {:ok, [%{"id" => "C1"}], nil}
      })

      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])

      assert {:ok, :more} = run_once(page_budget: 0)
      assert {:ok, :more} = run_once(page_budget: 0)
    end

    test "an installation whose connect is gone is forgotten" do
      connect = connect()
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])

      assert {:ok, :idle} = run_once()
      assert {:error, :not_found} = SlackMirrorBackfillLedger.connect(connect["connect_id"])
    end

    test "a token Slack refuses is recorded and the installation backs off" do
      connect = connect()
      SystemsRuntime.put_env(:salix_im, :runner_test_connects, [connect])

      SystemsRuntime.put_env(:salix_im, :runner_test_answers, %{
        connect["bot_token"] => {:error, {:slack, "invalid_auth"}}
      })

      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])

      assert {:error, {:slack, "invalid_auth"}} = run_once()

      assert {:ok, %{"leased_until" => nil, "last_error" => error}} =
               SlackMirrorBackfillLedger.connect(connect["connect_id"])

      assert error =~ "invalid_auth"
      assert :empty = run_once()
    end

    test "each pass outcome reaches the counter" do
      connect = connect()
      SystemsRuntime.put_env(:salix_im, :runner_test_connects, [connect])
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])

      handler = "backfill-pass-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      parent = SystemsRuntime.Proc.self()

      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix, :slack_mirror, :backfill, :pass],
        fn _event, _measurements, metadata, _config ->
          SystemsRuntime.Proc.send(parent, {:pass, metadata.outcome})
        end,
        nil
      )

      on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

      assert {:ok, :idle} = run_once()
      assert_received {:pass, :idle}
    end
  end

  describe "the scheduler process" do
    test "a crashing pass does not take the scheduler down and backs off" do
      defmodule CrashingLedger do
        def claim_due_connect(_ttl) do
          SystemsRuntime.Proc.send(
            SystemsRuntime.fetch_env!(:salix_im, :runner_test_parent),
            :backfill_claimed
          )

          raise("ledger unavailable")
        end

        def upsert_connects(_connects), do: :ok
      end

      SystemsRuntime.put_env(:salix_im, :runner_test_parent, SystemsRuntime.Proc.self())
      on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :runner_test_parent) end)

      supervisor = start_supervised!({SystemsRuntime.TaskSupervisor, name: __MODULE__.Tasks})

      runner =
        start_supervised!(
          {BackfillRunner,
           name: nil,
           ledger: CrashingLedger,
           connects: FakeConnects,
           task_supervisor: supervisor,
           start_delay_ms: 0}
        )

      SystemsClock.sleep(200)
      assert SystemsRuntime.Proc.alive?(runner)
      assert_received :backfill_claimed
      # The passes the start and the first discovery began have all crashed;
      # each waits out the backoff, so nothing claims again before it ends.
      drain_claims()
      SystemsClock.sleep(200)
      refute_received :backfill_claimed
    end

    test "one tick fills every free slot and does not tick again" do
      defmodule EmptyLedger do
        def claim_due_connect(_ttl), do: :empty
      end

      supervisor = start_supervised!({SystemsRuntime.TaskSupervisor, name: __MODULE__.Tasks})

      state = %{
        opts: [ledger: EmptyLedger, task_supervisor: supervisor, max_concurrent_passes: 3],
        passes: %{},
        discover_task: nil,
        discover_cursor: nil
      }

      assert {:noreply, %{passes: passes}} = BackfillRunner.handle_info(:work_tick, state)
      assert map_size(passes) == 3
      # A tick it sent itself would start another pass whenever one had ended.
      refute_received :work_tick
    end

    test "runs no more passes at once than it is allowed" do
      connects = [connect(), connect(), connect()]
      SystemsRuntime.put_env(:salix_im, :runner_test_connects, connects)
      :ok = SlackMirrorBackfillLedger.upsert_connects(connects)

      parent = SystemsRuntime.Proc.self()

      # A reader that parks every pass until told to continue, so the number
      # in flight can be observed.
      defmodule ParkingReader do
        def conversations(_credential, _opts) do
          SystemsRuntime.Proc.send(
            SystemsRuntime.fetch_env!(:salix_im, :runner_test_parent),
            {:parked, SystemsRuntime.Proc.self()}
          )

          SystemsRuntime.Proc.receive do
            :continue -> {:ok, [], nil}
          end
        end

        def history(_credential, _channel_id, _opts), do: {:ok, []}
        def replies(_credential, _channel_id, _root_ts, _opts), do: {:ok, [], ""}
      end

      SystemsRuntime.put_env(:salix_im, :runner_test_parent, parent)
      on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :runner_test_parent) end)

      supervisor = start_supervised!({SystemsRuntime.TaskSupervisor, name: __MODULE__.Tasks})

      _runner =
        start_supervised!(
          {BackfillRunner,
           name: nil,
           connects: FakeConnects,
           reader: ParkingReader,
           task_supervisor: supervisor,
           max_concurrent_passes: 2,
           start_delay_ms: 0,
           work_idle_ms: 20,
           pace_ms: 0}
        )

      # Two passes park; a third tick has no slot and so no third pass parks
      # while they are held.
      settle_receive({:parked, first})
      settle_receive({:parked, second})
      settle_refute_receive({:parked, _third}, 200)
      SystemsRuntime.Proc.send(first, :continue)
      SystemsRuntime.Proc.send(second, :continue)
      settle_receive({:parked, third})
      SystemsRuntime.Proc.send(third, :continue)
    end
  end

  defp drain_claims do
    receive do
      :backfill_claimed -> drain_claims()
    after
      0 -> :ok
    end
  end

  defp discover(cursor), do: BackfillRunner.discover_once(cursor, connects: FakeConnects)

  defp run_once(opts \\ []) do
    BackfillRunner.run_once(
      Keyword.merge(
        [connects: FakeConnects, reader: Reader, pace_ms: 0, sleep: fn _ms -> :ok end],
        opts
      )
    )
  end

  test "a disabled mirror does not claim installations or discover connects" do
    SystemsRuntime.delete_env(:salix_im, :slack_message_mirror_mod)
    candidate = connect()
    SystemsRuntime.put_env(:salix_im, :runner_test_connects, [candidate])

    assert :empty = run_once()
    assert {:ok, %{scan_complete: true}} = discover(nil)
    assert {:error, :not_found} = SlackMirrorBackfillLedger.connect(candidate["connect_id"])
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)

  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp connect do
    id = ULID.generate()

    %{
      "connect_id" => "imc_" <> id,
      "tenant_id" => "ten1_runner",
      "group_id" => "grp1_runner",
      "workspace_id" => "T_RUNNER",
      "bot_token" => "xoxb-runner-" <> id,
      "provider" => "slack"
    }
  end
end
