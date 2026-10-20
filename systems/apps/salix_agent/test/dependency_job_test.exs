defmodule SalixAgent.DependencyJobTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.DependencyAdmission
  alias SalixAgent.DependencyJob

  setup do
    previous_global = SystemsRuntime.get_env(:salix_agent, :dependency_max_children)
    previous_tenant = SystemsRuntime.get_env(:salix_agent, :dependency_max_children_per_tenant)
    previous_timeout = SystemsRuntime.get_env(:salix_agent, :dependency_job_timeout_ms)

    SystemsRuntime.put_env(:salix_agent, :dependency_max_children, 1)
    SystemsRuntime.put_env(:salix_agent, :dependency_max_children_per_tenant, 1)
    SystemsRuntime.put_env(:salix_agent, :dependency_job_timeout_ms, %{llm: 5_000})

    on_exit(fn ->
      restore_env(:dependency_max_children, previous_global)
      restore_env(:dependency_max_children_per_tenant, previous_tenant)
      restore_env(:dependency_job_timeout_ms, previous_timeout)
    end)

    :ok
  end

  test "a Tenant profile override replaces the per-Tenant admission limit" do
    SystemsRuntime.put_env(:salix_agent, :dependency_max_children, 3)

    SystemsRuntime.Proc.send(
      SalixAgent.DependencyAdmission,
      {:tenant_limits, %{"guest-tenant" => 2}}
    )

    on_exit(fn ->
      SystemsRuntime.Proc.send(SalixAgent.DependencyAdmission, {:tenant_limits, %{}})
    end)

    blocker = fn -> SystemsClock.sleep(:infinity) end
    assert {:ok, first} = DependencyJob.start(:llm, "guest-tenant", blocker)
    assert {:ok, second} = DependencyJob.start(:llm, "guest-tenant", blocker)
    assert {:error, :dependency_saturated} = DependencyJob.start(:llm, "guest-tenant", blocker)

    assert {:ok, other} = DependencyJob.start(:llm, "other-tenant", blocker)
    assert {:error, :dependency_saturated} = DependencyJob.start(:llm, "other-tenant", blocker)

    Enum.each([first, second, other], &DependencyJob.cancel/1)
  end

  test "owner death cancels its task and releases global and tenant admission" do
    test_pid = SystemsRuntime.Proc.self()

    owner =
      SystemsRuntime.Proc.spawn(fn ->
        {:ok, job} =
          DependencyJob.start(:llm, "owner-death-tenant", fn ->
            SystemsRuntime.Proc.send(test_pid, {:dependency_started, SystemsRuntime.Proc.self()})
            SystemsClock.sleep(:infinity)
          end)

        SystemsRuntime.Proc.send(test_pid, {:owner_job, job})
        SystemsClock.sleep(:infinity)
      end)

    settle_receive({:owner_job, _job})
    settle_receive({:dependency_started, dependency_pid})

    assert {:error, :dependency_saturated} =
             DependencyJob.start(:llm, "owner-death-tenant", fn -> :unreachable end)

    watch = SystemsRuntime.Proc.make_ref()
    assert :ok = DependencyAdmission.watch_capacity("owner-death-tenant", :llm, watch)

    SystemsRuntime.Proc.exit(owner, :kill)
    settle_receive({:dependency_capacity_available, ^watch})
    assert eventually(fn -> not SystemsRuntime.Proc.alive?(dependency_pid) end)

    assert {:ok, replacement} = eventually_start("owner-death-tenant")
    :ok = DependencyJob.cancel(replacement)
  end

  test "registering after a release wakes immediately without reserving admission" do
    tenant = "release-before-watch"
    {:ok, held} = DependencyJob.start(:llm, tenant, fn -> SystemsClock.sleep(:infinity) end)
    assert {:error, :dependency_saturated} = DependencyJob.start(:llm, tenant, fn -> :never end)
    :ok = DependencyJob.cancel(held)

    token = SystemsRuntime.Proc.make_ref()
    assert :ok = DependencyAdmission.watch_capacity(tenant, :llm, token)
    settle_receive({:dependency_capacity_available, ^token})

    assert {:ok, replacement} =
             DependencyJob.start(:llm, tenant, fn -> SystemsClock.sleep(:infinity) end)

    :ok = DependencyJob.cancel(replacement)
    settle_refute_receive({:dependency_capacity_available, ^token})
  end

  test "a metered release wakes only the oldest eligible bounded watch across Tenants" do
    SystemsRuntime.put_env(:salix_agent, :dependency_max_children, 3)
    blocker = fn -> SystemsClock.sleep(:infinity) end
    {:ok, held_a} = DependencyJob.start(:llm, "watch-a", blocker)
    {:ok, held_b} = DependencyJob.start(:llm, "watch-b", blocker)
    {:ok, held_e} = DependencyJob.start(:llm, "watch-e", blocker)

    token_a = SystemsRuntime.Proc.make_ref()
    token_c = SystemsRuntime.Proc.make_ref()
    token_d = SystemsRuntime.Proc.make_ref()
    {owner_a, :ok} = start_capacity_watch("watch-a", token_a)
    {owner_c, :ok} = start_capacity_watch("watch-c", token_c)
    {owner_d, :ok} = start_capacity_watch("watch-d", token_d)

    assert {:error, :saturated} =
             DependencyAdmission.watch_capacity("watch-f", :llm, SystemsRuntime.Proc.make_ref())

    :ok = DependencyJob.cancel(held_b)
    settle_receive({:capacity_available, ^owner_c, ^token_c})
    settle_refute_receive({:capacity_available, _, _})

    # A free slot remains because a wake does not reserve it. Releasing an
    # unmetered send must not produce an extra wake for the next eligible owner.
    {:ok, unmetered} = DependencyJob.start(:loop_control, "watch-c", blocker)
    :ok = DependencyJob.cancel(unmetered)
    settle_refute_receive({:capacity_available, _, _})

    :ok = DependencyJob.cancel(held_a)
    settle_receive({:capacity_available, ^owner_a, ^token_a})
    settle_refute_receive({:capacity_available, _, _})

    :ok = DependencyJob.cancel(held_e)
    settle_receive({:capacity_available, ^owner_d, ^token_d})
    settle_refute_receive({:capacity_available, _, _})
  end

  test "replacement and cancellation are owner and token fenced, and dead owners free watches" do
    {:ok, held} =
      DependencyJob.start(:llm, "watch-cleanup", fn -> SystemsClock.sleep(:infinity) end)

    old_token = SystemsRuntime.Proc.make_ref()
    token = SystemsRuntime.Proc.make_ref()
    {owner, :ok} = start_capacity_watch("watch-cleanup", old_token)
    SystemsRuntime.Proc.send(owner, {:watch, "watch-cleanup", token})
    settle_receive({:watch_registered, ^owner, :ok})
    SystemsRuntime.Proc.send(owner, {:cancel_watch, old_token})
    settle_receive({:watch_cancelled, ^owner, ^old_token})
    assert :ok = DependencyAdmission.cancel_capacity_watch(token)

    assert {:error, :saturated} =
             DependencyAdmission.watch_capacity("watch-cleanup", :llm, old_token)

    SystemsRuntime.Proc.send(owner, {:cancel_watch, token})
    settle_receive({:watch_cancelled, ^owner, ^token})
    assert :ok = DependencyAdmission.watch_capacity("watch-cleanup", :llm, old_token)
    assert :ok = DependencyAdmission.cancel_capacity_watch(old_token)

    SystemsRuntime.Proc.send(owner, {:watch, "watch-cleanup", token})
    settle_receive({:watch_registered, ^owner, :ok})
    SystemsRuntime.Proc.exit(owner, :kill)
    settle()
    assert :ok = DependencyAdmission.watch_capacity("watch-cleanup", :llm, old_token)
    :ok = DependencyJob.cancel(held)
    settle_receive({:dependency_capacity_available, ^old_token})
    settle_refute_receive({:dependency_capacity_available, ^token})
  end

  test "completed, crashed and timed out jobs wake a waiter only once" do
    for outcome <- [:complete, :crash, :timeout] do
      {:ok, held} =
        DependencyJob.start(:llm, "watch-settlement", fn ->
          SystemsRuntime.Proc.receive do
            :finish -> :ok
          end
        end)

      token = SystemsRuntime.Proc.make_ref()
      assert :ok = DependencyAdmission.watch_capacity("watch-settlement", :llm, token)

      case outcome do
        :complete -> SystemsRuntime.Proc.send(held.pid, :finish)
        :crash -> SystemsRuntime.Proc.exit(held.pid, :kill)
        :timeout -> DependencyJob.cancel(held, :timeout)
      end

      settle_receive({:dependency_capacity_available, ^token})
      :ok = DependencyJob.complete(held)
      settle_refute_receive({:dependency_capacity_available, ^token})
    end
  end

  test "admission emits active pressure and one terminal outcome per accepted job" do
    attach_telemetry([[:salix, :dependency_job, :active], [:salix, :dependency_job, :stop]])

    {:ok, job} =
      DependencyJob.start(:llm, "telemetry-tenant", fn -> SystemsClock.sleep(:infinity) end)

    settle_receive({:telemetry, [:salix, :dependency_job, :active], %{value: 1}, %{kind: :llm}})

    assert {:error, :dependency_saturated} =
             DependencyJob.start(:llm, "other-telemetry-tenant", fn -> :unreachable end)

    settle_receive(
      {:telemetry, [:salix, :dependency_job, :stop], %{}, %{kind: :llm, outcome: :saturated}}
    )

    :ok = DependencyJob.cancel(job)

    settle_receive(
      {:telemetry, [:salix, :dependency_job, :stop], %{}, %{kind: :llm, outcome: :cancelled}}
    )

    settle_receive({:telemetry, [:salix, :dependency_job, :active], %{value: 0}, %{kind: :llm}})
    settle_refute_receive({:telemetry, [:salix, :dependency_job, :stop], %{}, %{kind: :llm}}, 50)
  end

  defmodule InternalSends do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "internal", "provider" => "internal"}]}

    @impl true
    def provider_manual("internal") do
      {:ok,
       %{
         "provider" => "internal",
         "apis" => [
           %{
             "name" => "internal.send_message",
             "safety" => "write",
             "description" => "Send a visible internal conversation message.",
             "parameters" => %{
               "conversation_id" => "Conversation id.",
               "content" => "Message body."
             },
             "required_params" => ["conversation_id", "content"]
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(_agent_id, "internal", "internal.send_message", args),
      do: {:ok, %{"sent_to" => args["params"]["conversation_id"]}}
  end

  # A Worker's report must reach its Task while the Tenant's model rounds
  # hold every slot (`SalixAgent.Tools`): the send takes none.
  test "a session's send lands while the Tenant's slots are taken" do
    previous_im = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, InternalSends)
    on_exit(fn -> restore_env(:im_provider_mod, previous_im) end)

    tenant = "sends-tenant"
    {:ok, held} = DependencyJob.start(:llm, tenant, fn -> SystemsClock.sleep(:infinity) end)
    assert {:error, :dependency_saturated} = DependencyJob.start(:tool, tenant, fn -> :never end)

    ctx =
      %{
        agent_id: "a1",
        session_id: "s1",
        role: "worker",
        runtime_kind: :internal,
        tenant_id: tenant,
        visible_reply_guard: :clean,
        visible_reply_phase: :clean
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("worker", :internal, ctx)
      )

    [sent] =
      SalixAgent.Tools.execute(
        [
          %{
            "id" => "send-1",
            "name" => "im_api.internal.send_message",
            "args" => %{
              "connect_id" => "internal",
              "conversation_id" => "cnv1_0000000000000000001",
              "content" => [%{"type" => "text", "text" => "The notes are drafted."}]
            }
          }
        ],
        ctx
      )

    refute sent.error, sent.content
    assert sent.content =~ "cnv1_0000000000000000001"
    :ok = DependencyJob.cancel(held)
  end

  defp eventually_start(tenant_id, attempts \\ 3000)

  defp eventually_start(_tenant_id, 0), do: {:error, :admission_not_released}

  defp eventually_start(tenant_id, attempts) do
    case DependencyJob.start(:llm, tenant_id, fn -> SystemsClock.sleep(:infinity) end) do
      {:ok, _job} = result ->
        result

      {:error, :dependency_saturated} ->
        SystemsClock.sleep(10)
        eventually_start(tenant_id, attempts - 1)
    end
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp start_capacity_watch(tenant, token) do
    test_pid = SystemsRuntime.Proc.self()

    owner =
      SystemsRuntime.Proc.spawn(fn ->
        ref = SystemsRuntime.Proc.monitor(test_pid)
        result = DependencyAdmission.watch_capacity(tenant, :llm, token)

        SystemsRuntime.Proc.send(
          test_pid,
          {:watch_registered, SystemsRuntime.Proc.self(), result}
        )

        capacity_watch_loop(test_pid, ref)
      end)

    settle_receive({:watch_registered, ^owner, result})
    {owner, result}
  end

  defp capacity_watch_loop(test_pid, ref) do
    owner = SystemsRuntime.Proc.self()

    SystemsRuntime.Proc.receive do
      {:dependency_capacity_available, token} ->
        SystemsRuntime.Proc.send(test_pid, {:capacity_available, owner, token})
        capacity_watch_loop(test_pid, ref)

      {:watch, tenant, token} ->
        result = DependencyAdmission.watch_capacity(tenant, :llm, token)
        SystemsRuntime.Proc.send(test_pid, {:watch_registered, owner, result})
        capacity_watch_loop(test_pid, ref)

      {:cancel_watch, token} ->
        :ok = DependencyAdmission.cancel_capacity_watch(token)
        SystemsRuntime.Proc.send(test_pid, {:watch_cancelled, owner, token})
        capacity_watch_loop(test_pid, ref)

      {:DOWN, ^ref, :process, ^test_pid, _reason} ->
        :ok
    end
  end

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, SystemsRuntime.Proc.self(), SystemsRuntime.Proc.make_ref()}
    test_pid = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler_id) end)
  end

  @doc false
  def handle_telemetry(event, measurements, metadata, pid) do
    SystemsRuntime.Proc.send(pid, {:telemetry, event, measurements, metadata})
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)
end
