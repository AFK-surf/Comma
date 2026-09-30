defmodule SalixMeet.CalendarAutojoinEnrollmentTest do
  use ExUnit.Case, async: false

  alias SalixMeet.CalendarAutojoin
  alias SalixStore.Ids

  defmodule StubEnrollment do
    @behaviour SalixMeet.Ports.CalendarEnrollment

    @impl true
    def resolve_identities(entries) do
      if listener = Application.get_env(:salix_meet, :test_enrollment_listener) do
        send(listener, {:calendar_enrollment_identity_resolved, self()})
      end

      case Application.get_env(:salix_meet, :test_enrollment_identity_result) do
        nil ->
          case Application.get_env(:salix_meet, :test_enrollment_identity_error) do
            nil ->
              identities =
                Map.new(entries, fn %{"connect_id" => connect_id} ->
                  result =
                    case Application.get_env(:salix_meet, :test_enrollment_map, %{})[connect_id] do
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
      if listener = Application.get_env(:salix_meet, :test_enrollment_listener) do
        send(listener, {:calendar_enrollment_target_resolved, connect_id})
      end

      block_target = Application.get_env(:salix_meet, :test_enrollment_block_target, false)

      if block_target == true or block_target == connect_id do
        listener = Application.fetch_env!(:salix_meet, :test_enrollment_listener)
        send(listener, {:calendar_enrollment_target_waiting, self(), connect_id})

        receive do
          {:continue_calendar_enrollment_target, ^connect_id} -> :ok
        end
      end

      if Application.get_env(:salix_meet, :test_enrollment_fail, false) do
        {:error, :transient}
      else
        errors = Application.get_env(:salix_meet, :test_enrollment_resolution_errors, %{})

        case errors[connect_id] do
          nil -> resolve_from_map(connect_id)
          reason -> {:error, reason}
        end
      end
    end

    @impl true
    def resolve(%{"connect_id" => connect_id}) do
      if Application.get_env(:salix_meet, :test_enrollment_fail, false) do
        {:error, :transient}
      else
        resolve_from_map(connect_id)
      end
    end

    defp resolve_from_map(connect_id) do
      case Application.get_env(:salix_meet, :test_enrollment_map, %{})[connect_id] do
        nil -> {:error, :not_found}
        group -> {:ok, group}
      end
    end
  end

  setup do
    previous = %{
      mod: Application.get_env(:salix_meet, :calendar_enrollment_mod),
      channels: Application.get_env(:salix_meet, :calendar_autojoin_channels),
      s3: Application.get_env(:salix_store, :s3_backend)
    }

    Application.put_env(:salix_meet, :calendar_enrollment_mod, StubEnrollment)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _ -> :ok
    end

    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      restore(:calendar_enrollment_mod, previous.mod)
      restore(:calendar_autojoin_channels, previous.channels)
      Application.put_env(:salix_store, :s3_backend, previous.s3)
      Application.delete_env(:salix_meet, :test_enrollment_map)
      Application.delete_env(:salix_meet, :test_enrollment_fail)
      Application.delete_env(:salix_meet, :test_enrollment_resolution_errors)
      Application.delete_env(:salix_meet, :test_enrollment_listener)
      Application.delete_env(:salix_meet, :test_enrollment_block_target)
      Application.delete_env(:salix_meet, :test_enrollment_identity_error)
      Application.delete_env(:salix_meet, :test_enrollment_identity_result)
    end)

    :ok
  end

  test "fails closed on a group with conflicting channel targets, keeps clean groups" do
    Application.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => resolved_group("slack-a", "grp1_x", "C1"),
      "slack-b" => resolved_group("slack-b", "grp1_x", "C2"),
      "slack-c" => resolved_group("slack-c", "grp1_y", "C3")
    })

    Application.put_env(:salix_meet, :calendar_autojoin_channels, [
      channel("slack-a"),
      channel("slack-b"),
      channel("slack-c")
    ])

    group_ids = CalendarAutojoin.enabled_groups() |> Enum.map(& &1["group_id"]) |> Enum.sort()
    assert group_ids == ["grp1_y"]
  end

  test "drops channel entries that fail to resolve" do
    Application.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => resolved_group("slack-a", "grp1_x", "C1")
    })

    Application.put_env(:salix_meet, :calendar_autojoin_channels, [
      channel("slack-a"),
      channel("slack-missing")
    ])

    assert [%{"group_id" => "grp1_x"}] = CalendarAutojoin.enabled_groups()
  end

  test "fails the whole duplicate group closed before a sibling target resolution can fail" do
    Application.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => resolved_group("slack-a", "grp1_x", "C1"),
      "slack-b" => resolved_group("slack-b", "grp1_x", "C2")
    })

    Application.put_env(:salix_meet, :test_enrollment_resolution_errors, %{
      "slack-b" => {:calendar_not_found, "Cal"}
    })

    Application.put_env(:salix_meet, :calendar_autojoin_channels, [
      channel("slack-a"),
      channel("slack-b")
    ])

    assert CalendarAutojoin.enabled_groups() == []
  end

  test "a transient enrollment failure is retried on the next pass, not permanently dropped" do
    Application.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => resolved_group("slack-a", "grp1_x", "C1")
    })

    Application.put_env(:salix_meet, :test_enrollment_fail, true)

    {:ok, pid} =
      CalendarAutojoin.start_link(
        name: :"caj_#{System.unique_integer([:positive])}",
        channels: [channel("slack-a")],
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "test-node"
      )

    on_exit(fn -> stop_server(pid) end)

    assert %{groups: []} = :sys.get_state(pid)

    Application.put_env(:salix_meet, :test_enrollment_fail, false)
    send(pid, :scan_tick)

    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(pid)
  end

  test "emits finite enrollment telemetry from the lease-owned refresh boundary" do
    handler_id = "calendar-enrollment-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :operation, :stop],
        fn event, measurements, metadata, listener ->
          send(listener, {event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => resolved_group("slack-a", "grp1_x", "C1")
    })

    {:ok, pid} =
      CalendarAutojoin.start_link(
        name: :"caj_telemetry_#{System.unique_integer([:positive])}",
        channels: [channel("slack-a")],
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "telemetry-node"
      )

    on_exit(fn -> stop_server(pid) end)

    assert_receive {
      [:salix, :operation, :stop],
      %{duration: duration},
      %{
        component: "salix_meet",
        operation: "calendar_enrollment",
        surface: "system",
        outcome: "ok"
      }
    }

    assert is_integer(duration) and duration >= 0

    Application.put_env(:salix_meet, :test_enrollment_identity_error, :transient)
    send(pid, :scan_tick)

    assert_receive {
      [:salix, :operation, :stop],
      %{duration: unavailable_duration},
      %{
        component: "salix_meet",
        operation: "calendar_enrollment",
        surface: "system",
        outcome: "unavailable"
      }
    }

    assert is_integer(unavailable_duration) and unavailable_duration >= 0
  end

  test "a node that loses the global lease does not resolve enrollment" do
    Application.put_env(:salix_meet, :test_enrollment_listener, self())

    Application.put_env(:salix_meet, :test_enrollment_map, %{
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
        name: :"caj_loser_#{System.unique_integer([:positive])}",
        channels: [channel("slack-a")],
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "loser-node"
      )

    on_exit(fn -> stop_server(pid) end)
    assert %{groups: []} = :sys.get_state(pid)
    refute_receive {:calendar_enrollment_identity_resolved, _pid}, 50
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

    Application.put_env(:salix_meet, :test_enrollment_listener, self())
    Application.put_env(:salix_meet, :test_enrollment_block_target, "slack-a")

    Application.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => put_group,
      "slack-b" => delete_group
    })

    Application.put_env(:salix_meet, :test_enrollment_resolution_errors, %{
      "slack-b" => :inactive
    })

    {:ok, pid} =
      CalendarAutojoin.start_link(
        name: :"caj_stale_cache_#{System.unique_integer([:positive])}",
        channels: [put_entry, delete_entry],
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "stale-node"
      )

    on_exit(fn -> stop_server(pid) end)

    assert_receive {:calendar_enrollment_target_waiting, ^pid, "slack-a"}, 1_000

    assert {:ok, %{epoch: 2} = replacement_lease} =
             SalixStore.Lease.acquire(
               "ctl/meet/calendar_autojoin/lease.json",
               "replacement-node",
               now: System.system_time(:millisecond) + 300_001,
               ttl_ms: 300_000
             )

    on_exit(fn -> SalixStore.Lease.release(replacement_lease) end)

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               put_entry,
               put_identity,
               put_replacement,
               System.system_time(:millisecond)
             )

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               delete_entry,
               delete_identity,
               delete_replacement,
               System.system_time(:millisecond)
             )

    send(pid, {:continue_calendar_enrollment_target, "slack-a"})
    assert %{lease: nil, groups: [], resolved: %{}} = :sys.get_state(pid)

    assert {:ok, %{group: %{"channel_id" => "C2"}}} =
             SalixMeet.CalendarEnrollmentCache.load(put_entry, put_identity)

    assert {:ok, %{group: %{"channel_id" => "C4"}}} =
             SalixMeet.CalendarEnrollmentCache.load(delete_entry, delete_identity)
  end

  test "loads persisted ids after restart when configured resource names no longer resolve" do
    Application.put_env(:salix_meet, :test_enrollment_map, %{
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
        Keyword.put(opts, :name, :"caj_first_#{System.unique_integer([:positive])}")
      )

    assert %{groups: [%{"group_id" => "grp1_x", "channel_id" => "C1"}]} =
             :sys.get_state(first)

    [persisted] =
      SalixStore.S3.Fake.dump()
      |> Enum.filter(fn {key, _} ->
        String.starts_with?(key, SalixStore.Keys.ctl_meet_calendar_enrollments_prefix())
      end)

    {_key, %{body: body}} = persisted
    refute body =~ "bot_token"
    refute body =~ "never-persist"

    GenServer.stop(first)

    Application.put_env(:salix_meet, :test_enrollment_resolution_errors, %{
      "slack-a" => {:calendar_not_found, "Cal"}
    })

    {:ok, restarted} =
      CalendarAutojoin.start_link(
        Keyword.put(opts, :name, :"caj_restart_#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> stop_server(restarted) end)

    assert %{groups: [%{"group_id" => "grp1_x", "channel_id" => "C1"}]} =
             :sys.get_state(restarted)
  end

  test "a legacy cache cannot bypass source bootstrap after restart" do
    entry = channel("slack-a")
    group = resolved_group("slack-a", "grp1_x", "C1")
    now = System.system_time(:millisecond)
    fingerprint = SalixMeet.CalendarEnrollmentCache.fingerprint(entry)

    legacy_document = %{
      "version" => 2,
      "connect_id" => "slack-a",
      "fingerprint" => fingerprint,
      "identity" => %{
        "connect_id" => "slack-a",
        "tenant_id" => "ten1",
        "group_id" => "grp1_x",
        "provider" => "slack"
      },
      "group" => SalixMeet.CalendarEnrollmentCache.sanitize_group(group),
      "resolved_at_ms" => now
    }

    cache_key = SalixStore.Keys.ctl_meet_calendar_enrollment("slack-a", fingerprint)

    assert {:ok, _} =
             SalixStore.S3.put(cache_key, Jason.encode!(legacy_document), if_none_match: "*")

    Application.put_env(:salix_meet, :test_enrollment_listener, self())
    Application.put_env(:salix_meet, :test_enrollment_map, %{"slack-a" => group})

    Application.put_env(:salix_meet, :test_enrollment_resolution_errors, %{
      "slack-a" =>
        {:calendar_source_maintenance, {:calendar_source_bootstrap_pending, now + 60_000}}
    })

    {:ok, pid} =
      CalendarAutojoin.start_link(
        name: :"caj_legacy_bootstrap_#{System.unique_integer([:positive])}",
        channels: [entry],
        enrollment_ttl_ms: 3_600_000,
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "legacy-bootstrap-node"
      )

    on_exit(fn -> stop_server(pid) end)

    assert_receive {:calendar_enrollment_target_resolved, "slack-a"}
    assert %{groups: [], resolved: %{}} = :sys.get_state(pid)
    assert {:error, :not_found} = SalixStore.S3.head(cache_key)

    Application.delete_env(:salix_meet, :test_enrollment_resolution_errors)
    send(pid, :scan_tick)

    assert_receive {:calendar_enrollment_target_resolved, "slack-a"}
    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(pid)

    assert {:ok, %{body: body}} = SalixStore.S3.get(cache_key)

    assert %{
             "version" => 5,
             "source_activation" => %{"status" => "ready", "version" => 1}
           } = Jason.decode!(body)
  end

  test "a v4 cache cannot retain a superseded calendar normalization source" do
    entry = channel("slack-a")
    group = resolved_group("slack-a", "grp1_x", "C1")

    identity = %{
      "connect_id" => "slack-a",
      "tenant_id" => "ten1",
      "group_id" => "grp1_x",
      "provider" => "slack"
    }

    fingerprint = SalixMeet.CalendarEnrollmentCache.fingerprint(entry)

    document = %{
      "version" => 4,
      "connect_id" => "slack-a",
      "fingerprint" => fingerprint,
      "identity" => identity,
      "group" => SalixMeet.CalendarEnrollmentCache.sanitize_group(group),
      "source_activation" => %{"status" => "ready", "version" => 1},
      "resolved_at_ms" => System.system_time(:millisecond)
    }

    cache_key = SalixStore.Keys.ctl_meet_calendar_enrollment("slack-a", fingerprint)

    assert {:ok, _} =
             SalixStore.S3.put(cache_key, Jason.encode!(document), if_none_match: "*")

    assert {:error, :invalid_calendar_enrollment_cache} =
             SalixMeet.CalendarEnrollmentCache.load(entry, identity)
  end

  test "invalidates a persisted enrollment when its Slack connect becomes inactive" do
    Application.put_env(:salix_meet, :test_enrollment_map, %{
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
        Keyword.put(opts, :name, :"caj_active_#{System.unique_integer([:positive])}")
      )

    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(first)
    GenServer.stop(first)

    Application.put_env(:salix_meet, :test_enrollment_map, %{})

    {:ok, restarted} =
      CalendarAutojoin.start_link(
        Keyword.put(opts, :name, :"caj_inactive_#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> stop_server(restarted) end)

    assert %{groups: []} = :sys.get_state(restarted)

    refute Enum.any?(SalixStore.S3.Fake.dump(), fn {key, _} ->
             String.starts_with?(key, SalixStore.Keys.ctl_meet_calendar_enrollments_prefix())
           end)
  end

  test "fails closed instead of retaining a cache when bounded connect reconciliation is incomplete" do
    Application.put_env(:salix_meet, :test_enrollment_map, %{
      "slack-a" => resolved_group("slack-a", "grp1_x", "C1")
    })

    opts = [
      channels: [channel("slack-a")],
      scan_interval_ms: 3_600_000,
      join_interval_ms: 3_600_000,
      node: "lookup-budget-node"
    ]

    {:ok, pid} =
      CalendarAutojoin.start_link(
        Keyword.put(opts, :name, :"caj_lookup_budget_#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> stop_server(pid) end)
    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(pid)

    Application.put_env(
      :salix_meet,
      :test_enrollment_identity_error,
      {:calendar_enrollment_connect_lookup, :active_connect_lookup_limit_exceeded}
    )

    send(pid, :scan_tick)
    assert %{groups: []} = :sys.get_state(pid)
  end

  test "an identity-store outage never activates durable-only cache but retains validated memory" do
    entry = channel("slack-a")
    group = resolved_group("slack-a", "grp1_x", "C1")
    identity = Map.take(group, ["connect_id", "tenant_id", "group_id"])

    Application.put_env(:salix_meet, :test_enrollment_map, %{"slack-a" => group})
    Application.put_env(:salix_meet, :test_enrollment_identity_error, :transient)

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               entry,
               identity,
               group,
               System.system_time(:millisecond)
             )

    {:ok, pid} =
      CalendarAutojoin.start_link(
        name: :"caj_identity_outage_#{System.unique_integer([:positive])}",
        channels: [entry],
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "identity-outage-node"
      )

    on_exit(fn -> stop_server(pid) end)
    assert %{groups: [], resolved: resolved} = :sys.get_state(pid)
    assert resolved == %{}

    Application.delete_env(:salix_meet, :test_enrollment_identity_error)
    send(pid, :scan_tick)
    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(pid)

    Application.put_env(:salix_meet, :test_enrollment_identity_error, :transient)
    send(pid, :scan_tick)
    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(pid)

    Application.delete_env(:salix_meet, :test_enrollment_identity_error)
    Application.put_env(:salix_meet, :test_enrollment_identity_result, :malformed)
    send(pid, :scan_tick)
    assert %{groups: []} = :sys.get_state(pid)
  end

  test "a stale cache refresh failure is memory-backed off across subsequent ticks" do
    entry = channel("slack-a")
    group = resolved_group("slack-a", "grp1_x", "C1")
    identity = Map.take(group, ["connect_id", "tenant_id", "group_id"])

    Application.put_env(:salix_meet, :test_enrollment_listener, self())
    Application.put_env(:salix_meet, :test_enrollment_map, %{"slack-a" => group})

    Application.put_env(:salix_meet, :test_enrollment_resolution_errors, %{
      "slack-a" => {:calendar_not_found, "Cal"}
    })

    resolved_at = System.system_time(:millisecond) - 10_000

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               entry,
               identity,
               group,
               resolved_at
             )

    {:ok, pid} =
      CalendarAutojoin.start_link(
        name: :"caj_backoff_#{System.unique_integer([:positive])}",
        channels: [entry],
        enrollment_ttl_ms: 1_000,
        enrollment_retry_backoff_ms: 60_000,
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "backoff-node"
      )

    on_exit(fn -> stop_server(pid) end)
    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(pid)
    assert_receive {:calendar_enrollment_target_resolved, "slack-a"}
    refute_receive {:calendar_enrollment_target_resolved, "slack-a"}, 50

    send(pid, :scan_tick)
    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(pid)
    refute_receive {:calendar_enrollment_target_resolved, "slack-a"}, 50

    [{_key, %{body: body}}] =
      SalixStore.S3.Fake.dump()
      |> Enum.filter(fn {key, _} ->
        String.starts_with?(key, SalixStore.Keys.ctl_meet_calendar_enrollments_prefix())
      end)

    assert %{"resolved_at_ms" => ^resolved_at} = Jason.decode!(body)
  end

  test "a provider repair timeout retains enrollment and does not retry on the two-minute pass" do
    entry = channel("slack-a")
    group = resolved_group("slack-a", "grp1_x", "C1")
    identity = Map.take(group, ["connect_id", "tenant_id", "group_id"])

    Application.put_env(:salix_meet, :test_enrollment_listener, self())
    Application.put_env(:salix_meet, :test_enrollment_map, %{"slack-a" => group})

    Application.put_env(:salix_meet, :test_enrollment_resolution_errors, %{
      "slack-a" => :source_operation_timeout
    })

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               entry,
               identity,
               group,
               System.system_time(:millisecond) - 10_000
             )

    {:ok, pid} =
      CalendarAutojoin.start_link(
        name: :"caj_provider_repair_#{System.unique_integer([:positive])}",
        channels: [entry],
        enrollment_ttl_ms: 1_000,
        enrollment_retry_backoff_ms: 10,
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "provider-repair-node"
      )

    on_exit(fn -> stop_server(pid) end)

    assert_receive {:calendar_enrollment_target_resolved, "slack-a"}
    Process.sleep(20)
    send(pid, :scan_tick)

    refute_receive {:calendar_enrollment_target_resolved, "slack-a"}, 100
    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(pid)
  end

  test "zero enrollment TTL keeps immediate retry semantics" do
    entry = channel("slack-a")
    group = resolved_group("slack-a", "grp1_x", "C1")
    identity = Map.take(group, ["connect_id", "tenant_id", "group_id"])

    Application.put_env(:salix_meet, :test_enrollment_listener, self())
    Application.put_env(:salix_meet, :test_enrollment_map, %{"slack-a" => group})

    Application.put_env(:salix_meet, :test_enrollment_resolution_errors, %{
      "slack-a" => {:calendar_not_found, "Cal"}
    })

    assert :ok =
             SalixMeet.CalendarEnrollmentCache.put(
               entry,
               identity,
               group,
               System.system_time(:millisecond) - 10_000
             )

    {:ok, pid} =
      CalendarAutojoin.start_link(
        name: :"caj_no_backoff_#{System.unique_integer([:positive])}",
        channels: [entry],
        enrollment_ttl_ms: 0,
        enrollment_retry_backoff_ms: 60_000,
        scan_interval_ms: 3_600_000,
        join_interval_ms: 3_600_000,
        node: "no-backoff-node"
      )

    on_exit(fn -> stop_server(pid) end)
    assert %{groups: [%{"group_id" => "grp1_x"}]} = :sys.get_state(pid)
    assert_receive {:calendar_enrollment_target_resolved, "slack-a"}
    assert_receive {:calendar_enrollment_target_resolved, "slack-a"}
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

  defp restore(key, nil), do: Application.delete_env(:salix_meet, key)
  defp restore(key, value), do: Application.put_env(:salix_meet, key, value)
end
