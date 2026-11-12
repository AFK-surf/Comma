defmodule SalixAgent.AgentControlTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.Control
  alias SalixAgent.TestSupport.RetiredSessionFixture
  alias SalixStore.{AgentPGStore, Keys, Repo, S3}

  setup do
    previous_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

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
  test "wake starts the owner and reports an enqueued wake" do
    id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(id)
    assert {:ok, %{"status" => "queued"}} = Control.wake(id)
    assert [{pid, _}] = Registry.lookup(SalixAgent.Registry, id)
    assert SystemsRuntime.Proc.alive?(pid)
  end

  test "Inspector configuration persists and refuses External Runtimes and unsafe roots" do
    agent = create_agent!()
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

    retired = SalixAgent.StationBinding.retired_external_message()

    assert {:error, {:bad_request, ^retired}} =
             SalixAgent.AgentControl.configure(id, %{
               "runtime_config" => %{"kind" => "external", "provider" => "codex"}
             })

    assert {:ok, current} = SalixAgent.AgentControl.get_record(id)
    assert current["inspector_policy"] == policy
    assert current["runtime_config"]["kind"] == "internal"
  end

  test "a reply style is default or concise and reaches the runtime prompts" do
    id = create_agent!()["agent_id"]

    assert {:ok, %{"reply_style" => "concise"}} =
             SalixAgent.AgentControl.configure(id, %{"reply_style" => "concise"})

    assert {:ok, %{prompts: %{"reply_style" => "concise"}}} =
             SalixAgent.AgentRuntimeConfig.resolve(id)

    assert {:error, {:bad_request, _}} =
             SalixAgent.AgentControl.configure(id, %{"reply_style" => "terse"})

    assert {:ok, %{"reply_style" => "default"}} =
             SalixAgent.AgentControl.configure(id, %{"reply_style" => "default"})
  end

  test "a Worker writes in its Group Router's reply style" do
    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    router_id = SalixStore.Ids.new_agent_id(group_id)
    worker_id = SalixStore.Ids.new_agent_id(group_id)

    for {id, role} <- [{router_id, "router"}, {worker_id, "worker"}] do
      SalixAgent.TestSupport.create_control_agent!(id, %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "role" => role,
        "runtime_config" => %{"kind" => "internal"}
      })
    end

    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "tenant_id" => tenant_id,
      "router_agent_id" => router_id
    })

    worker_prompt = fn ->
      assert {:ok, config} =
               SalixAgent.RoundConfig.build_runtime_session_config(worker_id, "worker", %{})

      config.system_prompt
    end

    refute worker_prompt.() =~ "## Reply style: concise"

    assert {:ok, _} =
             SalixAgent.AgentControl.configure(router_id, %{"reply_style" => "concise"})

    assert worker_prompt.() =~ "## Reply style: concise"
  end

  test "a conditional write checks the record it replaces, also after a write lands in between" do
    agent = create_agent!()
    {id, tenant} = {agent["agent_id"], agent["tenant_id"]}

    unchanged = fn record ->
      if record["name"] == agent["name"], do: :ok, else: {:error, :changed}
    end

    # Another write lands after this one read the record and before it stores
    # its own: the retry sees it, and the precondition refuses.
    interleaved = fn record ->
      if record["name"] == agent["name"] do
        {:ok, _} = SalixAgent.AgentControl.configure(id, %{"name" => "Renamed elsewhere"})
      end

      unchanged.(record)
    end

    assert {:error, :changed} =
             SalixAgent.AgentControl.configure_if(
               id,
               %{"router_system_prompt" => "Mine."},
               tenant,
               interleaved
             )

    assert {:ok, record} = SalixAgent.AgentControl.get_record(id)
    assert record["name"] == "Renamed elsewhere"
    refute record["router_system_prompt"] == "Mine."

    assert {:ok, %{"router_system_prompt" => "Mine."}} =
             SalixAgent.AgentControl.configure_if(
               id,
               %{"router_system_prompt" => "Mine."},
               tenant,
               fn _ ->
                 :ok
               end
             )
  end

  test "list reads each control record once and no related resource" do
    internal = create_agent!()
    sibling = create_agent!(internal["tenant_id"])
    seed_related_objects!(internal)
    seed_related_objects!(sibling)
    SalixStore.S3.Fake.reset_read_log()

    listed = Control.list(internal["tenant_id"])

    assert Enum.sort(Enum.map(listed, & &1["agent_id"])) ==
             Enum.sort([internal["agent_id"], sibling["agent_id"]])

    assert Enum.all?(listed, &(not Map.has_key?(&1, "activity_status")))

    assert SalixStore.S3.Fake.read_log() == []
  end

  test "list_result surfaces database failures while list keeps the empty contract" do
    agent = create_agent!()
    tenant_id = agent["tenant_id"]

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL search_path = pg_catalog")
               assert {:error, %Postgrex.Error{}} = Control.list_result(tenant_id)
               assert Control.list(tenant_id) == []
               :ok
             end)

    assert {:ok, [%{"agent_id" => _}]} = Control.list_result(tenant_id)
  end

  test "list excludes archived agents unless include_archived is set" do
    active = create_agent!()
    archived = create_agent!(active["tenant_id"])
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
    created = create_agent!()
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
    visible = create_agent!(tenant_id)
    assert {:ok, _} = Control.delete(visible["agent_id"], tenant_id)
    other_tenant = SalixAgent.TestSupport.new_tenant_id()

    assert {:error, :not_found} =
             Control.get_including_archived(visible["agent_id"], other_tenant)

    assert {:ok, _} = Control.get_including_archived(visible["agent_id"], tenant_id)
  end

  defp list_ids(tenant_id, opts),
    do: tenant_id |> Control.list(opts) |> Enum.map(& &1["agent_id"])

  defp mark_hidden!(agent_id) do
    assert {:ok, %{record: record, revision: revision}} = AgentPGStore.read_config(agent_id)
    updated = Map.put(record, "hidden", true)
    assert {:ok, _} = AgentPGStore.put_config(agent_id, updated, revision)
    updated
  end

  test "activity reads bounded session projections, retired Sessions included" do
    agent = create_agent!()
    session_id = SalixStore.Ids.new_session_id()
    RetiredSessionFixture.put!(agent, session_id, %{"status" => "running"})
    SalixStore.S3.Fake.reset_read_log()

    # A retired Session is read-only history and never reports activity.
    assert SalixAgent.Activity.list(agent["tenant_id"]) == []

    agent_id = agent["agent_id"]
    session_key = Keys.agent_external_runtime_session(agent_id, session_id)
    session_prefix = Keys.agent_external_runtime_sessions_prefix(agent_id)

    assert SalixStore.S3.Fake.read_log() == [
             {:list, session_prefix, delimiter: "/"},
             {:get, session_key}
           ]
  end

  defp create_agent!(tenant_id \\ nil) do
    tenant_id = tenant_id || SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(agent_id, %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "role" => "worker",
      "runtime_config" => %{"kind" => "internal"}
    })
  end

  defp seed_related_objects!(agent) do
    agent_id = agent["agent_id"]
    group_id = agent["group_id"]
    payload = SystemsRuntime.Proc.random_bytes(128_000)

    assert {:ok, _} = S3.put(Keys.agent_internal_runtime_session(agent_id, "internal"), payload)
    assert {:ok, _} = S3.put(Keys.agent_external_runtime_session(agent_id, "external"), payload)
    assert {:ok, _} = S3.put(Keys.ctl_vm(group_id), payload)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
