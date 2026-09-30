defmodule SalixWeb.ConnectorExternalEventCoordinatorTest do
  use ExUnit.Case, async: false

  alias SalixWeb.ConnectorExternalEventCoordinator, as: Coordinator

  test "a different socket must advance the connector generation" do
    test_pid = self()
    lane = unique_lane("strict-generation")
    id = unique_id("strict-generation")
    first_socket = sleeping_process()
    replacement_socket = sleeping_process()

    on_exit(fn ->
      stop_process(first_socket)
      stop_process(replacement_socket)
    end)

    execute = fn _params ->
      send(test_pid, {:strict_generation_started, self()})

      receive do
        :release_strict_generation -> {:error, :test_transient}
      end
    end

    assert {:wait, _waiter_ref} =
             Coordinator.submit(
               first_socket,
               lane,
               7,
               id,
               %{"event_id" => id},
               execute
             )

    assert_receive {:strict_generation_started, worker}

    assert :ok = Coordinator.refresh_lane(replacement_socket, lane, 7, execute)
    assert coordinator_state().lanes[lane].executor.socket == first_socket

    assert :ok = Coordinator.refresh_lane(replacement_socket, lane, 8, execute)
    assert coordinator_state().lanes[lane].executor.socket == replacement_socket

    send(worker, :release_strict_generation)
    assert eventually(fn -> not Map.has_key?(coordinator_state().events, {lane, id}) end)
  end

  test "socket death detaches an unarmed waiter and authorizes its task" do
    test_pid = self()
    lane = unique_lane("unarmed-disconnect")
    id = unique_id("unarmed-disconnect")
    key = {lane, id}
    socket = sleeping_process()
    waiter_token = make_ref()
    waiter_ref = make_ref()

    execute = fn _params ->
      send(test_pid, {:unarmed_disconnect_started, self()})

      receive do
        :release_unarmed_disconnect -> {:error, :test_transient}
      end
    end

    assert {:wait_unarmed, ^key, ^waiter_token, ^waiter_ref} =
             GenServer.call(
               Coordinator,
               {:submit, socket, lane, 1, id, %{"event_id" => id}, execute, waiter_token,
                waiter_ref}
             )

    refute_receive {:unarmed_disconnect_started, _worker}, 25
    Process.exit(socket, :kill)

    assert_receive {:unarmed_disconnect_started, worker}, 300
    assert coordinator_state().events[key].waiter == nil

    send(worker, :release_unarmed_disconnect)
    assert eventually(fn -> not Map.has_key?(coordinator_state().events, key) end)
  end

  test "an event larger than the retained-entry bound is terminal and never retained" do
    configure_limits(
      connector_external_event_retained_bytes_limit: 128,
      connector_external_event_global_retained_bytes_limit: 16_384,
      connector_external_event_tenant_retained_bytes_limit: 16_384
    )

    lane = unique_lane("oversized")
    id = unique_id("oversized")
    key = {lane, id}
    params = %{"event_id" => id, "payload" => String.duplicate("x", 512)}
    test_pid = self()

    assert event_size(lane, id, params) > 128

    assert {:reply,
            %{
              "id" => ^id,
              "type" => "response",
              "result" => %{
                "accepted" => false,
                "error_code" => "external_runtime_event_too_large"
              }
            }} =
             Coordinator.submit(self(), lane, 1, id, params, fn ->
               send(test_pid, :oversized_event_executed)
               {:ok, %{}}
             end)

    refute Map.has_key?(coordinator_state().events, key)
    refute_receive :oversized_event_executed, 25
  end

  test "global retained-byte saturation is retryable and releases exactly" do
    lane_a = unique_lane("global-a")
    lane_b = unique_lane("global-b")
    id_a = unique_id("global-a")
    id_b = unique_id("global-b")
    params_a = %{"event_id" => id_a, "payload" => String.duplicate("a", 1_024)}
    params_b = %{"event_id" => id_b, "payload" => String.duplicate("b", 1_024)}
    size_a = event_size(lane_a, id_a, params_a)
    size_b = event_size(lane_b, id_b, params_b)
    baseline = coordinator_state().retained_bytes
    per_entry_limit = max(size_a, size_b) + 128

    configure_limits(
      connector_external_event_retained_bytes_limit: per_entry_limit,
      connector_external_event_global_retained_bytes_limit: baseline + max(size_a, size_b),
      connector_external_event_tenant_retained_bytes_limit: per_entry_limit * 2
    )

    execute = blocking_transient_executor(self(), :global_bytes)

    assert {:wait, ref_a} = Coordinator.submit(self(), lane_a, 1, id_a, params_a, execute)
    assert_receive {:global_bytes, ^id_a, worker_a}
    assert coordinator_state().retained_bytes == baseline + size_a

    assert {:reply, %{"id" => ^id_b, "type" => "error"}} =
             Coordinator.submit(self(), lane_b, 1, id_b, params_b, execute)

    send(worker_a, :release_test_dependency)
    assert_receive {:connector_external_event_reply, ^ref_a, %{"type" => "error"}}
    assert eventually(fn -> coordinator_state().retained_bytes == baseline end)

    assert {:wait, ref_b} = Coordinator.submit(self(), lane_b, 1, id_b, params_b, execute)
    assert_receive {:global_bytes, ^id_b, worker_b}
    send(worker_b, :release_test_dependency)
    assert_receive {:connector_external_event_reply, ^ref_b, %{"type" => "error"}}
    assert eventually(fn -> coordinator_state().retained_bytes == baseline end)
  end

  test "tenant retained-byte saturation does not consume the global reserve" do
    tenant = "tenant-byte-test-#{System.unique_integer([:positive])}"
    lane_a = {tenant, "group-a", unique_id("device-a")}
    lane_b = {tenant, "group-b", unique_id("device-b")}
    id_a = unique_id("tenant-a")
    id_b = unique_id("tenant-b")
    params_a = %{"event_id" => id_a, "payload" => String.duplicate("a", 768)}
    params_b = %{"event_id" => id_b, "payload" => String.duplicate("b", 768)}
    size_a = event_size(lane_a, id_a, params_a)
    size_b = event_size(lane_b, id_b, params_b)
    baseline = coordinator_state().retained_bytes
    per_entry_limit = max(size_a, size_b) + 128

    configure_limits(
      connector_external_event_retained_bytes_limit: per_entry_limit,
      connector_external_event_global_retained_bytes_limit: baseline + size_a + size_b + 128,
      connector_external_event_tenant_retained_bytes_limit: max(size_a, size_b)
    )

    execute = blocking_transient_executor(self(), :tenant_bytes)

    assert {:wait, ref_a} = Coordinator.submit(self(), lane_a, 1, id_a, params_a, execute)
    assert_receive {:tenant_bytes, ^id_a, worker_a}
    assert coordinator_state().tenant_retained_bytes[tenant] == size_a

    assert {:reply, %{"id" => ^id_b, "type" => "error"}} =
             Coordinator.submit(self(), lane_b, 1, id_b, params_b, execute)

    send(worker_a, :release_test_dependency)
    assert_receive {:connector_external_event_reply, ^ref_a, %{"type" => "error"}}

    assert eventually(fn ->
             not Map.has_key?(coordinator_state().tenant_retained_bytes, tenant)
           end)

    assert {:wait, ref_b} = Coordinator.submit(self(), lane_b, 1, id_b, params_b, execute)
    assert_receive {:tenant_bytes, ^id_b, worker_b}
    send(worker_b, :release_test_dependency)
    assert_receive {:connector_external_event_reply, ^ref_b, %{"type" => "error"}}

    assert eventually(fn ->
             not Map.has_key?(coordinator_state().tenant_retained_bytes, tenant)
           end)
  end

  test "completion cache expiry releases its retained-byte accounting" do
    lane = unique_lane("cache-bytes")
    id = unique_id("cache-bytes")
    key = {lane, id}
    params = %{"event_id" => id, "payload" => "cached"}
    result = %{"event_id" => id}

    reply = %{"id" => id, "type" => "response", "result" => result}
    cache_size = :erlang.external_size({key, params, reply})
    baseline = coordinator_state().retained_bytes

    configure_limits(
      connector_external_event_retained_bytes_limit: cache_size + 128,
      connector_external_event_global_retained_bytes_limit: baseline + cache_size + 128,
      connector_external_event_tenant_retained_bytes_limit: cache_size + 128,
      connector_external_event_completion_cache_ttl_ms: 5
    )

    assert {:wait, waiter_ref} =
             Coordinator.submit(self(), lane, 1, id, params, fn -> {:ok, result} end)

    assert_receive {:connector_external_event_reply, ^waiter_ref, ^reply}

    assert eventually(fn ->
             state = coordinator_state()

             state.completed[key].retained_bytes == cache_size and
               state.retained_bytes == baseline + cache_size
           end)

    Process.sleep(10)
    Application.put_env(:salix_web, :connector_external_event_retained_bytes_limit, 1)

    trigger_lane = unique_lane("cache-prune-trigger")
    trigger_id = unique_id("cache-prune-trigger")

    assert {:reply, %{"type" => "response"}} =
             Coordinator.submit(
               self(),
               trigger_lane,
               1,
               trigger_id,
               %{"event_id" => trigger_id},
               fn -> {:ok, %{}} end
             )

    state = coordinator_state()
    refute Map.has_key?(state.completed, key)
    assert state.retained_bytes == baseline
  end

  test "the response budget plus the maximum owner call stays below five seconds" do
    configure_limits(
      connector_external_event_owner_call_timeout_ms: 1_000,
      connector_external_event_response_timeout_ms: 4_500
    )

    lane = unique_lane("legacy-response-budget")
    id = unique_id("legacy-response-budget")
    key = {lane, id}
    waiter_token = make_ref()
    waiter_ref = make_ref()

    assert {:wait_unarmed, ^key, ^waiter_token, ^waiter_ref} =
             GenServer.call(
               Coordinator,
               {:submit, self(), lane, 1, id, %{"event_id" => id},
                fn ->
                  {:error, :test_transient}
                end, waiter_token, waiter_ref}
             )

    remaining = coordinator_state().events[key].response_deadline_at - monotonic_ms()
    assert remaining > 0
    assert remaining + 1_000 < 5_000

    GenServer.cast(Coordinator, {:detach_waiter, key, waiter_token})
    assert eventually(fn -> not Map.has_key?(coordinator_state().events, key) end)
  end

  test "arming consumes the response budget already spent after admission" do
    configure_limits(connector_external_event_response_timeout_ms: 500)

    test_pid = self()
    lane = unique_lane("arm-budget")
    id = unique_id("arm-budget")
    key = {lane, id}
    waiter_token = make_ref()
    waiter_ref = make_ref()

    execute = fn ->
      send(test_pid, {:arm_budget_started, self()})

      receive do
        :release_arm_budget -> {:error, :test_transient}
      end
    end

    assert {:wait_unarmed, ^key, ^waiter_token, ^waiter_ref} =
             GenServer.call(
               Coordinator,
               {:submit, self(), lane, 1, id, %{"event_id" => id}, execute, waiter_token,
                waiter_ref}
             )

    Process.sleep(100)
    GenServer.cast(Coordinator, {:arm_waiter, key, waiter_token})
    assert_receive {:arm_budget_started, worker}, 300

    assert eventually(fn -> is_reference(coordinator_state().events[key].response_timer) end)
    remaining = Process.read_timer(coordinator_state().events[key].response_timer)
    assert is_integer(remaining)
    assert remaining < 450

    send(worker, :release_arm_budget)
    assert_receive {:connector_external_event_reply, ^waiter_ref, %{"type" => "error"}}, 300
    assert eventually(fn -> not Map.has_key?(coordinator_state().events, key) end)
  end

  defp blocking_transient_executor(test_pid, tag) do
    fn params ->
      send(test_pid, {tag, params["event_id"], self()})

      receive do
        :release_test_dependency -> {:error, :test_transient}
      end
    end
  end

  defp event_size(lane, id, params), do: :erlang.external_size({{lane, id}, params})

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp coordinator_state, do: :sys.get_state(Coordinator)

  defp unique_lane(prefix) do
    suffix = System.unique_integer([:positive])
    {"tenant-#{prefix}-#{suffix}", "group-#{suffix}", "device-#{suffix}"}
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp sleeping_process, do: spawn(fn -> Process.sleep(:infinity) end)

  defp stop_process(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp configure_limits(values) do
    previous =
      Map.new(values, fn {key, _value} -> {key, Application.get_env(:salix_web, key)} end)

    Enum.each(values, fn {key, value} -> Application.put_env(:salix_web, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:salix_web, key)
        {key, value} -> Application.put_env(:salix_web, key, value)
      end)
    end)
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end
end
