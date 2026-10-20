defmodule SalixMeet.CalendarAutojoinEnrollmentTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet"]
  alias SalixMeet.CalendarAutojoin
  alias SalixStore.Ids

  defmodule StubEnrollment do
    @behaviour SalixMeet.Ports.CalendarEnrollment

    @impl true
    def resolve_identities(entries) do
      if listener = SystemsRuntime.get_env(:salix_meet, :test_enrollment_listener) do
        SystemsRuntime.Proc.send(
          listener,
          {:calendar_enrollment_identity_resolved, SystemsRuntime.Proc.self()}
        )
      end

      case SystemsRuntime.get_env(:salix_meet, :test_enrollment_identity_result) do
        nil ->
          case SystemsRuntime.get_env(:salix_meet, :test_enrollment_identity_error) do
            nil ->
              identities =
                Map.new(entries, fn %{"connect_id" => connect_id} ->
                  result =
                    case SystemsRuntime.get_env(:salix_meet, :test_enrollment_map, %{})[
                           connect_id
                         ] do
                      nil ->
                        {:error, :not_found}

                      group ->
                        {:ok,
                         %{
                           "connect_id" => connect_id,
                           "tenant_id" => group["tenant_id"],
                           "group_id" => group["group_id"]
                         }}
                    end

                  {connect_id, result}
                end)

              {:ok, identities}

            reason ->
              {:error, reason}
          end

        result ->
          result
      end
    end

    @impl true
    def resolve(%{"connect_id" => connect_id}, _identity) do
      if listener = SystemsRuntime.get_env(:salix_meet, :test_enrollment_listener) do
        SystemsRuntime.Proc.send(listener, {:calendar_enrollment_target_resolved, connect_id})
      end

      block_target = SystemsRuntime.get_env(:salix_meet, :test_enrollment_block_target, false)

      if block_target == true or block_target == connect_id do
        listener = SystemsRuntime.fetch_env!(:salix_meet, :test_enrollment_listener)

        SystemsRuntime.Proc.send(
          listener,
          {:calendar_enrollment_target_waiting, SystemsRuntime.Proc.self(), connect_id}
        )

        SystemsRuntime.Proc.receive do
          {:continue_calendar_enrollment_target, ^connect_id} -> :ok
        end
      end

      if SystemsRuntime.get_env(:salix_meet, :test_enrollment_fail, false) do
        {:error, :transient}
      else
        errors = SystemsRuntime.get_env(:salix_meet, :test_enrollment_resolution_errors, %{})

        case errors[connect_id] do
          nil -> resolve_from_map(connect_id)
          reason -> {:error, reason}
        end
      end
    end

    @impl true
    def resolve(%{"connect_id" => connect_id}) do
      if SystemsRuntime.get_env(:salix_meet, :test_enrollment_fail, false) do
        {:error, :transient}
      else
        resolve_from_map(connect_id)
      end
    end

    defp resolve_from_map(connect_id) do
      case SystemsRuntime.get_env(:salix_meet, :test_enrollment_map, %{})[connect_id] do
        nil -> {:error, :not_found}
        group -> {:ok, group}
      end
    end
  end

  setup do
    previous = %{
      mod: SystemsRuntime.get_env(:salix_meet, :calendar_enrollment_mod),
      channels: SystemsRuntime.get_env(:salix_meet, :calendar_autojoin_channels),
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend)
    }

    SystemsRuntime.put_env(:salix_meet, :calendar_enrollment_mod, StubEnrollment)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _ -> :ok
    end

    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      restore(:calendar_enrollment_mod, previous.mod)
      restore(:calendar_autojoin_channels, previous.channels)
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous.s3)
      SystemsRuntime.delete_env(:salix_meet, :test_enrollment_map)
      SystemsRuntime.delete_env(:salix_meet, :test_enrollment_fail)
      SystemsRuntime.delete_env(:salix_meet, :test_enrollment_resolution_errors)
      SystemsRuntime.delete_env(:salix_meet, :test_enrollment_listener)
      SystemsRuntime.delete_env(:salix_meet, :test_enrollment_block_target)
      SystemsRuntime.delete_env(:salix_meet, :test_enrollment_identity_error)
      SystemsRuntime.delete_env(:salix_meet, :test_enrollment_identity_result)
    end)

    :ok
  end

  test "fails closed on a group with conflicting channel targets, keeps clean groups" do
    SystemsRuntime.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => resolved_group("slack-a", "grp1_x", "C1"),
      "slack-b" => resolved_group("slack-b", "grp1_x", "C2"),
      "slack-c" => resolved_group("slack-c", "grp1_y", "C3")
    })

    SystemsRuntime.put_env(:salix_meet, :calendar_autojoin_channels, [
      channel("slack-a"),
      channel("slack-b"),
      channel("slack-c")
    ])

    group_ids = CalendarAutojoin.enabled_groups() |> Enum.map(& &1["group_id"]) |> Enum.sort()
    assert group_ids == ["grp1_y"]
  end

  test "a node that loses the global lease does not resolve enrollment" do
    SystemsRuntime.put_env(:salix_meet, :test_enrollment_listener, SystemsRuntime.Proc.self())

    SystemsRuntime.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => resolved_group("slack-a", "grp1_x", "C1")
    })

    assert {:ok, lease} =
             SalixStore.Lease.acquire(
               "ctl/meet/calendar_autojoin/lease.json",
               "leader-node",
               ttl_ms: 300_000
             )

    on_exit(fn -> SalixStore.Lease.release(lease) end)

    {:ok, pid} =
      CalendarAutojoin.start_link(
        name: :"caj_loser_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        channels: [channel("slack-a")],
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "loser-node"
      )

    on_exit(fn -> stop_server(pid) end)
    assert %{groups: []} = :sys.get_state(pid, :infinity)
    settle_refute_receive({:calendar_enrollment_identity_resolved, _pid}, 50)
  end

  test "lease loss during target resolution discards stale cache writes" do
    put_entry = channel("slack-a")
    delete_entry = channel("slack-b")
    put_group = resolved_group("slack-a", "grp1_x", "C1")
    put_replacement = resolved_group("slack-a", "grp1_x", "C2")
    delete_group = resolved_group("slack-b", "grp1_y", "C3")
    delete_replacement = resolved_group("slack-b", "grp1_y", "C4")

    put_identity = Map.take(put_group, ["connect_id", "tenant_id", "group_id"])
    delete_identity = Map.take(delete_group, ["connect_id", "tenant_id", "group_id"])

    SystemsRuntime.put_env(:salix_meet, :test_enrollment_listener, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_meet, :test_enrollment_block_target, "slack-a")

    SystemsRuntime.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => put_group,
      "slack-b" => delete_group
    })

    SystemsRuntime.put_env(:salix_meet, :test_enrollment_resolution_errors, %{
      "slack-b" => :inactive
    })

    {:ok, pid} =
      CalendarAutojoin.start_link(
        name: :"caj_stale_cache_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        channels: [put_entry, delete_entry],
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "stale-node"
      )

    on_exit(fn -> stop_server(pid) end)

    settle_receive({:calendar_enrollment_target_waiting, ^pid, "slack-a"})

    assert {:ok, %{epoch: 2} = replacement_lease} =
             SalixStore.Lease.acquire(
               "ctl/meet/calendar_autojoin/lease.json",
               "replacement-node",
               now: SystemsClock.system_time(:millisecond) + 300_001,
               ttl_ms: 300_000
             )

    on_exit(fn -> SalixStore.Lease.release(replacement_lease) end)

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               put_entry,
               put_identity,
               put_replacement,
               SystemsClock.system_time(:millisecond)
             )

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               delete_entry,
               delete_identity,
               delete_replacement,
               SystemsClock.system_time(:millisecond)
             )

    SystemsRuntime.Proc.send(pid, {:continue_calendar_enrollment_target, "slack-a"})
    assert %{lease: nil, groups: [], resolved: %{}} = :sys.get_state(pid, :infinity)

    assert {:ok, %{group: %{"channel_id" => "C2"}}} =
             SalixMeet.CalendarEnrollmentCache.load(put_entry, put_identity)

    assert {:ok, %{group: %{"channel_id" => "C4"}}} =
             SalixMeet.CalendarEnrollmentCache.load(delete_entry, delete_identity)
  end

  test "loads persisted ids after restart when configured resource names no longer resolve" do
    SystemsRuntime.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => resolved_group("slack-a", "grp1_x", "C1")
    })

    opts = [
      channels: [channel("slack-a")],
      scan_interval_ms: 3_600_000,
      join_interval_ms: 3_600_000,
      node: "restart-node"
    ]

    {:ok, first} =
      CalendarAutojoin.start_link(
        Keyword.put(opts, :name, :"caj_first_#{SystemsRuntime.Proc.unique_integer([:positive])}")
      )

    assert %{groups: [%{"group_id" => "grp1_x", "channel_id" => "C1"}]} =
             :sys.get_state(first, :infinity)

    [persisted] =
      SalixStore.S3.Fake.dump()
      |> Enum.filter(fn {key, _} ->
        String.starts_with?(key, SalixStore.Keys.ctl_meet_calendar_enrollments_prefix())
      end)

    {_key, %{body: body}} = persisted
    refute body =~ "bot_token"
    refute body =~ "never-persist"

    GenServer.stop(first)

    SystemsRuntime.put_env(:salix_meet, :test_enrollment_resolution_errors, %{
      "slack-a" => {:calendar_not_found, "Cal"}
    })

    {:ok, restarted} =
      CalendarAutojoin.start_link(
        Keyword.put(
          opts,
          :name,
          :"caj_restart_#{SystemsRuntime.Proc.unique_integer([:positive])}"
        )
      )

    on_exit(fn -> stop_server(restarted) end)

    assert %{groups: [%{"group_id" => "grp1_x", "channel_id" => "C1"}]} =
             :sys.get_state(restarted, :infinity)
  end

  test "invalidates a persisted enrollment when its Slack connect becomes inactive" do
    SystemsRuntime.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => resolved_group("slack-a", "grp1_x", "C1")
    })

    opts = [
      channels: [channel("slack-a")],
      scan_interval_ms: 3_600_000,
      join_interval_ms: 3_600_000,
      node: "inactive-node"
    ]

    {:ok, first} =
      CalendarAutojoin.start_link(
        Keyword.put(opts, :name, :"caj_active_#{SystemsRuntime.Proc.unique_integer([:positive])}")
      )

    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(first, :infinity)
    GenServer.stop(first)

    SystemsRuntime.put_env(:salix_meet, :test_enrollment_map, %{})

    {:ok, restarted} =
      CalendarAutojoin.start_link(
        Keyword.put(
          opts,
          :name,
          :"caj_inactive_#{SystemsRuntime.Proc.unique_integer([:positive])}"
        )
      )

    on_exit(fn -> stop_server(restarted) end)

    assert %{groups: []} = :sys.get_state(restarted, :infinity)

    refute Enum.any?(SalixStore.S3.Fake.dump(), fn {key, _} ->
             String.starts_with?(key, SalixStore.Keys.ctl_meet_calendar_enrollments_prefix())
           end)
  end

  defp channel(connect_id),
    do: %{"connect_id" => connect_id, "channel" => "#c", "calendars" => ["Cal"]}

  defp resolved_group(connect_id, group_id, channel_id) do
    %{
      "tenant_id" => "ten1",
      "group_id" => group_id,
      "connect_id" => connect_id,
      "workspace_id" => "T1",
      "channel_id" => channel_id,
      "bot_token" => "never-persist",
      "calendar_id" => Ids.new_calendar_id(),
      "calendars" => [
        %{
          "account_id" => "ca-1",
          "calendar_id" => "cal-1",
          "source_id" => Ids.new_calendar_source_id()
        }
      ]
    }
  end

  # Teardown only. The worker traps exits (it releases its lease in
  # terminate/2), so by the time on_exit runs it is usually already going
  # down with the test process's :shutdown; GenServer.stop then exits with a
  # nested {shutdown, {GenServer, :stop, _}} reason. Any exit here means the
  # server is gone, which is all teardown needs.
  defp stop_server(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp restore(key, nil), do: SystemsRuntime.delete_env(:salix_meet, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:salix_meet, key, value)
end
