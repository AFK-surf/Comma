defmodule SalixAgent.AgentControlTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.Control
  alias SalixAgent.TestSupport.RetiredSessionFixture
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
      case SystemsRuntime.PersistentTerm.get({__MODULE__, :config}, nil) do
        %{prefix: ^prefix, keys: keys} ->
          objects = Enum.map(keys, &%{key: &1})
          {:ok, %{objects: objects, next: nil}}

        _unrelated ->
          SalixStore.S3.Fake.list(prefix, opts)
      end
    end

    @impl true
    def get(key, opts) do
      case SystemsRuntime.PersistentTerm.get({__MODULE__, :config}, nil) do
        %{coordinator: coordinator, gate_ref: gate_ref, keys: keys} ->
          if key in keys do
            SystemsRuntime.Proc.send(
              coordinator,
              {:get_started, gate_ref, key, SystemsRuntime.Proc.self()}
            )

            SystemsRuntime.Proc.receive do
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

    prefix = Keys.ctl_agents_prefix_for_tenant(internal["tenant_id"])

    assert [{:list, ^prefix, []} | reads] = SalixStore.S3.Fake.read_log()

    assert Enum.sort(reads) ==
             Enum.sort([
               {:get, Keys.ctl_agent(internal["agent_id"])},
               {:get, Keys.ctl_agent(sibling["agent_id"])}
             ])
  end

  test "list_result surfaces LIST failures while list keeps the legacy empty contract" do
    agent = create_agent!()
    tenant_id = agent["tenant_id"]
    prefix = Keys.ctl_agents_prefix_for_tenant(tenant_id)

    SalixStore.S3.Fake.set_fault({:fail, 503, :list, prefix})
    assert {:error, {:http, 503}} = Control.list_result(tenant_id)

    SalixStore.S3.Fake.set_fault({:fail, 503, :list, prefix})
    assert Control.list(tenant_id) == []

    # Faults are one-shot, so the next call sees healthy storage again.
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
    key = Keys.ctl_agent(agent_id)
    assert {:ok, %{body: body, etag: etag}} = S3.get(key)
    updated = body |> Jason.decode!() |> Map.put("hidden", true)
    assert {:ok, _} = S3.put(key, Jason.encode!(updated), if_match: etag)
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
    agent_key = Keys.ctl_agent(agent_id)
    session_key = Keys.agent_external_runtime_session(agent_id, session_id)
    control_prefix = Keys.ctl_agents_prefix_for_tenant(agent["tenant_id"])
    internal_prefix = Keys.agent_internal_runtime_sessions_prefix(agent_id)
    session_prefix = Keys.agent_external_runtime_sessions_prefix(agent_id)

    assert SalixStore.S3.Fake.read_log() == [
             {:list, control_prefix, []},
             {:get, agent_key},
             {:list, internal_prefix, []},
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

    key = Keys.ctl_agent(agent_id)
    assert {:ok, %{body: body, etag: etag}} = S3.get(key)

    updated =
      body
      |> Jason.decode!()
      |> Map.put("vm", %{"enabled" => true})

    assert {:ok, _} = S3.put(key, Jason.encode!(updated), if_match: etag)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
