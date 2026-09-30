defmodule SalixAgent.AgentControlTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{Control, ExternalAgentRuntime}
  alias SalixStore.{Keys, S3}

  defmodule GateBackend do
    @moduledoc """
    Listing backend whose configured GETs block until released, so a test can
    observe how many record reads are in flight at once. Unrelated storage
    calls delegate to the normal fake backend. Configuration is passed via
    :persistent_term.
    """

    @behaviour SalixStore.S3

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_uploads(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    def list(prefix, opts) do
      case :persistent_term.get({__MODULE__, :config}, nil) do
        %{prefix: ^prefix, keys: keys} ->
          objects = Enum.map(keys, &%{key: &1})
          {:ok, %{objects: objects, next: nil}}

        _unrelated ->
          SalixStore.S3.Fake.list(prefix, opts)
      end
    end

    @impl true
    def get(key, opts) do
      case :persistent_term.get({__MODULE__, :config}, nil) do
        %{coordinator: coordinator, gate_ref: gate_ref, keys: keys} ->
          if key in keys do
            send(coordinator, {:get_started, gate_ref, key, self()})

            receive do
              {:release, ^gate_ref, ^key} -> {:ok, %{body: "{}", etag: "gate"}}
            end
          else
            SalixStore.S3.Fake.get(key, opts)
          end

        _unconfigured ->
          SalixStore.S3.Fake.get(key, opts)
      end
    end
  end

  setup do
    previous_store = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_store, :s3_backend, previous_store)
    end)

    :ok
  end

  defmodule UnavailableWakePlacement do
    def ensure_started(_, _), do: {:error, {:owner_unreachable, :wake_owner, :not_connected}}
  end

  @tag :owner_retry_fix
  test "wake returns placement failure instead of claiming the wake was queued" do
    id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(id)
    previous = Application.get_env(:salix_agent, :placement)
    Application.put_env(:salix_agent, :placement, UnavailableWakePlacement)
    on_exit(fn -> restore_env(:salix_agent, :placement, previous) end)

    assert {:error, {:owner_unreachable, :wake_owner, :not_connected}} = Control.wake(id)
    assert [] = Registry.lookup(SalixAgent.Registry, id)
  end

  @tag :owner_retry_fix
  test "wake starts the owner and reports an enqueued wake" do
    id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(id)
    assert {:ok, %{"status" => "queued"}} = Control.wake(id)
    assert [{pid, _}] = Registry.lookup(SalixAgent.Registry, id)
    assert Process.alive?(pid)
  end

  test "all External Worker binding kinds share the external runtime owner" do
    assert Control.runtime_kind(%{"runtime_config" => %{"kind" => "external"}}) == "external"

    assert Control.runtime_kind(%{"runtime_config" => %{"kind" => "connected_runtime"}}) ==
             "external"

    assert Control.runtime_kind(%{"runtime_config" => %{"kind" => "compute_workload"}}) ==
             "external"

    assert Control.runtime_kind(%{"runtime_config" => %{"kind" => "internal"}}) == "internal"
  end

  test "get reads only the agent control record" do
    agent = create_agent!("external")
    seed_related_objects!(agent)
    SalixStore.S3.Fake.reset_read_log()

    assert {:ok, result} = Control.get(agent["agent_id"], agent["tenant_id"])
    assert result["status"] == "idle"
    refute Map.has_key?(result, "activity_status")

    agent_key = Keys.ctl_agent(agent["agent_id"])

    assert SalixStore.S3.Fake.read_log() == [{:get, agent_key}]
  end

  test "Inspector configuration persists and refuses external runtimes and unsafe roots" do
    agent = create_agent!("internal")
    id = agent["agent_id"]
    policy = SalixAgent.TestSupport.inspector_policy()

    assert {:ok, configured} =
             SalixAgent.AgentControl.configure(id, %{"inspector_policy" => policy})

    assert configured["inspector_policy"] == policy
    assert {:ok, runtime} = SalixAgent.AgentRuntimeConfig.resolve(id)
    assert runtime.inspector_policy == policy

    for root <- ["/", "/.runtime/skills", "/.shape-up-inspector/../shared", "relative", "/a//b"] do
      assert {:error, {:bad_request, _}} =
               SalixAgent.AgentControl.configure(id, %{
                 "inspector_policy" => %{policy | "artifact_root" => root}
               })
    end

    external = create_agent!("external", agent["tenant_id"])

    assert {:error, {:bad_request, _}} =
             SalixAgent.AgentControl.configure(external["agent_id"], %{
               "inspector_policy" => policy
             })

    assert {:error, {:bad_request, _}} =
             SalixAgent.AgentControl.configure(id, %{
               "runtime_config" => external_runtime_config()
             })

    assert {:ok, current} = SalixAgent.AgentControl.get_record(id)
    assert current["inspector_policy"] == policy
    assert current["runtime_config"]["kind"] == "internal"
  end

  test "list reads each control record once and no related resource" do
    internal = create_agent!("internal")
    external = create_agent!("external", internal["tenant_id"])
    seed_related_objects!(internal)
    seed_related_objects!(external)
    SalixStore.S3.Fake.reset_read_log()

    listed = Control.list(internal["tenant_id"])

    assert Enum.sort(Enum.map(listed, & &1["agent_id"])) ==
             Enum.sort([internal["agent_id"], external["agent_id"]])

    assert Enum.all?(listed, &(not Map.has_key?(&1, "activity_status")))

    prefix = Keys.ctl_agents_prefix_for_tenant(internal["tenant_id"])

    assert [{:list, ^prefix, []} | reads] = SalixStore.S3.Fake.read_log()

    assert Enum.sort(reads) ==
             Enum.sort([
               {:get, Keys.ctl_agent(internal["agent_id"])},
               {:get, Keys.ctl_agent(external["agent_id"])}
             ])
  end

  test "list_result surfaces LIST failures while list keeps the legacy empty contract" do
    agent = create_agent!("internal")
    tenant_id = agent["tenant_id"]
    prefix = Keys.ctl_agents_prefix_for_tenant(tenant_id)

    SalixStore.S3.Fake.set_fault({:fail, 503, :list, prefix})
    assert {:error, {:http, 503}} = Control.list_result(tenant_id)

    SalixStore.S3.Fake.set_fault({:fail, 503, :list, prefix})
    assert Control.list(tenant_id) == []

    # Faults are one-shot, so the next call sees healthy storage again.
    assert {:ok, [%{"agent_id" => _}]} = Control.list_result(tenant_id)
  end

  test "list_result surfaces per-record GET transport failures instead of dropping rows" do
    agent = create_agent!("internal")
    _sibling = create_agent!("internal", agent["tenant_id"])

    SalixStore.S3.Fake.set_fault({:fail, 500, :get, Keys.ctl_agent(agent["agent_id"])})

    assert {:error, {:http, 500}} = Control.list_result(agent["tenant_id"])
  end

  test "list keeps at most eight record reads in flight while later reads wait" do
    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    prefix = Keys.ctl_agents_prefix_for_tenant(tenant_id)
    keys = for i <- 1..12, do: prefix <> "gate-#{i}.json"
    gate_ref = make_ref()

    :persistent_term.put(
      {GateBackend, :config},
      %{coordinator: self(), gate_ref: gate_ref, keys: keys, prefix: prefix}
    )

    Application.put_env(:salix_store, :s3_backend, GateBackend)

    on_exit(fn ->
      :persistent_term.erase({GateBackend, :config})
    end)

    unrelated_prefix = "agent-control-gate-unrelated/#{System.unique_integer([:positive])}/"
    assert {:ok, %{objects: [], next: nil}} = S3.list(unrelated_prefix)
    assert {:error, :not_found} = S3.get(unrelated_prefix <> "record.json")
    refute_receive {:get_started, ^gate_ref, _, _}, 0

    task = Task.async(fn -> Control.list_result(tenant_id) end)

    # Exactly eight reads start; the ninth stays queued behind the cap.
    workers =
      for _ <- 1..8 do
        assert_receive {:get_started, ^gate_ref, key, pid}, 2_000
        {key, pid}
      end

    assert workers |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 8
    assert workers |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 8

    # An unrelated, unscoped control message cannot open a record gate.
    {_first_key, first_pid} = hd(workers)
    send(first_pid, :release)
    refute_receive {:get_started, ^gate_ref, _, _}, 200

    # Releasing one slot admits exactly one more read.
    [{first_key, first_pid} | rest] = workers
    send(first_pid, {:release, gate_ref, first_key})
    assert_receive {:get_started, ^gate_ref, ninth_key, ninth_pid}, 2_000
    refute_receive {:get_started, ^gate_ref, _, _}, 200

    for {key, pid} <- rest ++ [{ninth_key, ninth_pid}],
        do: send(pid, {:release, gate_ref, key})

    for _ <- 1..3 do
      assert_receive {:get_started, ^gate_ref, key, pid}, 2_000
      send(pid, {:release, gate_ref, key})
    end

    # Bodies decode to records without an agent_id, which are skipped.
    assert {:ok, []} = Task.await(task)
  end

  test "concurrent list reads keep the caller's observability surface" do
    agent = create_agent!("internal")
    test_pid = self()
    handler_id = "agent-control-list-surface-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:salix, :operation, :stop],
      fn _event, _meas, meta, _cfg ->
        if meta.operation == "store_get", do: send(test_pid, {:surface, meta.surface})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    SystemsObservability.Context.with_surface("salix", fn ->
      assert {:ok, [_]} = Control.list_result(agent["tenant_id"])
    end)

    assert_receive {:surface, "salix"}
  end

  test "list excludes archived agents unless include_archived is set" do
    active = create_agent!("internal")
    archived = create_agent!("internal", active["tenant_id"])
    tenant_id = active["tenant_id"]

    assert {:ok, _} = Control.delete(archived["agent_id"], tenant_id)

    default_ids = tenant_id |> Control.list() |> Enum.map(& &1["agent_id"])
    assert active["agent_id"] in default_ids
    refute archived["agent_id"] in default_ids

    all_ids =
      tenant_id |> Control.list(include_archived: true) |> Enum.map(& &1["agent_id"])

    assert active["agent_id"] in all_ids
    assert archived["agent_id"] in all_ids

    assert {:error, :not_found} = Control.get(archived["agent_id"], tenant_id)
    assert {:ok, rec} = Control.get_including_archived(archived["agent_id"], tenant_id)
    assert Control.archived?(rec)
  end

  test "get_including_archived widens get only on the archived axis" do
    # hidden is not settable through create/update; the meeting runtime writes
    # its internal agent records directly, so the test does the same.
    created = create_agent!("internal")
    tenant_id = created["tenant_id"]
    hidden = mark_hidden!(created["agent_id"])
    assert hidden["hidden"] == true

    # Hidden agents stay unresolvable by ID while active…
    assert {:error, :not_found} = Control.get(hidden["agent_id"], tenant_id)
    assert {:error, :not_found} = Control.get_including_archived(hidden["agent_id"], tenant_id)

    # …and while archived (scoped delete can't see hidden, archive directly).
    assert {:ok, _} = Control.delete(hidden["agent_id"])
    assert {:error, :not_found} = Control.get_including_archived(hidden["agent_id"], tenant_id)
    refute hidden["agent_id"] in list_ids(tenant_id, include_archived: true)

    # Tenant scoping still applies to non-hidden archived agents.
    visible = create_agent!("internal", tenant_id)
    assert {:ok, _} = Control.delete(visible["agent_id"], tenant_id)
    other_tenant = SalixAgent.TestSupport.new_tenant_id()

    assert {:error, :not_found} =
             Control.get_including_archived(visible["agent_id"], other_tenant)

    assert {:ok, _} = Control.get_including_archived(visible["agent_id"], tenant_id)
  end

  defp list_ids(tenant_id, opts),
    do: tenant_id |> Control.list(opts) |> Enum.map(& &1["agent_id"])

  defp mark_hidden!(agent_id) do
    key = Keys.ctl_agent(agent_id)
    assert {:ok, %{body: body, etag: etag}} = S3.get(key)
    updated = body |> Jason.decode!() |> Map.put("hidden", true)
    assert {:ok, _} = S3.put(key, Jason.encode!(updated), if_match: etag)
    updated
  end

  test "activity reads bounded session, status, and availability projections" do
    agent = create_agent!("external")
    session_id = SalixStore.Ids.new_session_id()

    assert {:ok, :external} =
             ExternalAgentRuntime.stage_delivery(agent["agent_id"], %{
               source_message_id: "agent-control-activity",
               payload: %{
                 "session_id" => session_id,
                 "role" => "user",
                 "content" => "context only",
                 "no_wake" => true
               }
             })

    SalixAgent.TestSupport.stop_all_agents()
    seed_related_objects!(agent)
    SalixStore.S3.Fake.reset_read_log()

    assert SalixAgent.Activity.list(agent["tenant_id"]) == []

    agent_id = agent["agent_id"]
    agent_key = Keys.ctl_agent(agent_id)
    session_key = Keys.agent_external_runtime_session(agent_id, session_id)
    status_key = Keys.agent_external_runtime_session_status(agent_id, session_id)
    control_prefix = Keys.ctl_agents_prefix_for_tenant(agent["tenant_id"])
    session_prefix = Keys.agent_external_runtime_sessions_prefix(agent_id)
    device_key = Keys.ctl_group_device(agent["tenant_id"], agent["group_id"], "test-device")

    assert SalixStore.S3.Fake.read_log() == [
             {:list, control_prefix, []},
             {:get, agent_key},
             {:list, session_prefix, delimiter: "/"},
             {:get, session_key},
             {:get, device_key},
             {:get, status_key}
           ]
  end

  defp create_agent!(runtime_kind, tenant_id \\ nil) do
    tenant_id = tenant_id || SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(agent_id, %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "role" => "worker",
      "runtime_config" =>
        if(runtime_kind == "external",
          do: external_runtime_config(),
          else: %{"kind" => "internal"}
        )
    })
  end

  defp external_runtime_config do
    device_id = "test-device"
    runtime_id = "test-runtime"

    %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => device_id,
      "runtime_id" => runtime_id,
      "device_runtime_id" =>
        SalixStore.RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)
    }
  end

  defp seed_related_objects!(agent) do
    agent_id = agent["agent_id"]
    group_id = agent["group_id"]
    payload = :crypto.strong_rand_bytes(128_000)

    assert {:ok, _} = S3.put(Keys.agent_internal_runtime_session(agent_id, "internal"), payload)
    assert {:ok, _} = S3.put(Keys.agent_external_runtime_session(agent_id, "external"), payload)
    assert {:ok, _} = S3.put(Keys.ctl_vm(group_id), payload)

    key = Keys.ctl_agent(agent_id)
    assert {:ok, %{body: body, etag: etag}} = S3.get(key)

    updated =
      body
      |> Jason.decode!()
      |> Map.put("vm", %{"enabled" => true, "provider" => "sprites"})

    assert {:ok, _} = S3.put(key, Jason.encode!(updated), if_match: etag)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
