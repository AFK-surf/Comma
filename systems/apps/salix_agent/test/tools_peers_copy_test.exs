defmodule SalixAgent.ToolsPeersCopyTest do
  @moduledoc """
  Cross-agent `env.copy` (Comma peer qualifiers): PULL/PUSH zero-copy VFS→VFS ref
  sharing within an agent group, peer↔remote chunked streaming, idempotent peer
  commits, and the qualifier validation/group-scoping error surface. Against the
  Fake S3 backend.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{AgentWorkspace, Tools.Peers}
  alias SalixStore.{Keys, S3}
  alias SalixAgent.LLM.Mock

  defmodule FakeDispatch do
    @moduledoc false
    @behaviour SalixAgent.EnvDispatch

    @impl true
    def list_devices(_agent_id, _opts), do: {:ok, %{devices: [], next_cursor: nil}}

    @impl true
    def list_envs(_agent_id), do: {:ok, []}

    @impl true
    def get_device(_agent_id, _device_id), do: {:error, :no_environment}

    @impl true
    def exec(_agent_id, _env, _cmd, _opts), do: {:error, :no_environment}

    @impl true
    def computer_use(_agent_id, _env, _payload), do: {:error, :no_environment}
    @impl true
    def android(_agent_id, _env, _payload), do: {:error, :no_environment}

    @impl true
    def process_list(_agent_id, _env), do: {:error, :no_environment}

    @impl true
    def process_write(_agent_id, _env, _name, _data, _opts), do: {:error, :no_environment}

    @impl true
    def process_tail(_agent_id, _env, _name, _opts), do: {:error, :no_environment}

    @impl true
    def read_stream(_agent_id, %{device_id: "device-laptop", environment_id: "laptop"}, path) do
      # Deliver the body in multiple chunks to exercise chunked streaming.
      body = "streamed body for #{path}"
      chunks = for <<chunk::binary-5 <- body>>, do: chunk
      tail = binary_part(body, div(byte_size(body), 5) * 5, rem(byte_size(body), 5))
      chunks = if tail == "", do: chunks, else: chunks ++ [tail]
      {:ok, chunks, byte_size(body)}
    end

    def read_stream(_agent_id, _env, _path), do: {:error, :no_environment}

    @impl true
    def write_stream(
          _agent_id,
          %{device_id: "device-laptop", environment_id: "laptop"},
          path,
          stream
        ) do
      # Consume chunk-by-chunk; never buffer the whole stream up-front.
      size =
        Enum.reduce(stream, 0, fn chunk, acc -> acc + byte_size(IO.iodata_to_binary(chunk)) end)

      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:wrote_stream, path, size})
      {:ok, %{"size" => size}}
    end

    def write_stream(_agent_id, _env, _path, _stream), do: {:error, :no_environment}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_dispatch = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    SystemsRuntime.delete_env(:salix_agent, :env_dispatch)
    SalixAgent.TestSupport.configure_control_fixtures!()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      put_or_delete(:salix_store, :s3_backend, prev_s3)
      put_or_delete(:salix_agent, :env_dispatch, prev_dispatch)
      put_or_delete(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete(:salix_agent, :llm, prev_llm)
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    caller = create_agent!(SalixStore.Ids.new_agent_id(group), tenant, group, "router")
    peer = create_agent!(SalixStore.Ids.new_agent_id(group), tenant, group, "worker")

    ctx = %{agent_id: caller["agent_id"], session_id: "main", tool_call_id: "tc-#{suffix}"}

    {:ok, tenant: tenant, group: group, caller: caller, peer: peer, ctx: ctx}
  end

  defp put_or_delete(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp create_agent!(id, tenant, group, role) do
    SalixAgent.TestSupport.create_control_agent!(id, %{
      "tenant_id" => tenant,
      "group_id" => group,
      "role" => role
    })
  end

  defp seed_file!(agent_id, path, content) do
    {:ok, event} = AgentWorkspace.prepare_write(agent_id, path, content)

    {:ok, _} =
      AgentWorkspace.seed_operation(agent_id, "seed-#{path}", %{"ok" => true}, [event])

    {:ok, manifest} = AgentWorkspace.manifest(agent_id)
    manifest[path]
  end

  defp blob_count do
    {:ok, blobs} = S3.list_all("blobs/")
    length(blobs)
  end

  # ---- PULL: peer VFS -> caller VFS (zero-copy) ----

  test "PULL shares the source blob ref into the caller manifest with zero copy", %{
    caller: caller,
    peer: peer,
    ctx: ctx
  } do
    src_entry = seed_file!(peer["agent_id"], "/notes/shared.txt", "peer-owned bytes")
    src_uuid = src_entry["ref"]["uuid"]

    before_blobs = blob_count()

    out =
      Peers.copy(
        %{
          "src_environment" => "vfs",
          "src_path" => "/notes/shared.txt",
          "dst_environment" => "vfs",
          "dst_path" => "/pulled/shared.txt",
          "src_agent_id" => peer["agent_id"]
        },
        ctx
      )

    assert {content, [event]} = out
    decoded = Jason.decode!(content)

    assert decoded["src_agent_id"] == peer["agent_id"]
    refute Map.has_key?(decoded, "dst_agent_id")
    assert decoded["size"] == byte_size("peer-owned bytes")
    assert decoded["copied"] == true

    # Zero-copy: no new blob object was written.
    assert blob_count() == before_blobs

    # The event re-points at the SAME blob uuid the peer already owns.
    assert event["ref"]["uuid"] == src_uuid

    # Committing the returned caller event lands it in the caller's manifest.
    {:ok, _} =
      AgentWorkspace.seed_operation(caller["agent_id"], "apply-pull", %{"ok" => true}, [event])

    {:ok, manifest} = AgentWorkspace.manifest(caller["agent_id"])
    assert manifest["/pulled/shared.txt"]["ref"]["uuid"] == src_uuid

    assert {:ok, "peer-owned bytes"} =
             AgentWorkspace.read(caller["agent_id"], "/pulled/shared.txt")
  end

  # ---- PUSH: caller VFS -> peer VFS (zero-copy, committed now) ----

  test "PUSH commits the shared ref into the peer manifest and is idempotent on retry", %{
    caller: caller,
    peer: peer,
    ctx: ctx
  } do
    src_entry = seed_file!(caller["agent_id"], "/out/report.txt", "caller-owned report")
    src_uuid = src_entry["ref"]["uuid"]

    before_blobs = blob_count()

    args = %{
      "src_environment" => "vfs",
      "src_path" => "/out/report.txt",
      "dst_environment" => "vfs",
      "dst_path" => "/inbox/report.txt",
      "dst_agent_id" => peer["agent_id"]
    }

    out = Peers.copy(args, ctx)
    decoded = Jason.decode!(out)

    # Peer destination returns content only (no caller-side events).
    assert is_binary(out)
    assert decoded["dst_agent_id"] == peer["agent_id"]
    assert decoded["size"] == byte_size("caller-owned report")

    # Zero-copy across agents.
    assert blob_count() == before_blobs

    {:ok, manifest} = AgentWorkspace.manifest(peer["agent_id"])
    assert manifest["/inbox/report.txt"]["ref"]["uuid"] == src_uuid

    assert {:ok, "caller-owned report"} =
             AgentWorkspace.read(peer["agent_id"], "/inbox/report.txt")

    # Same tool_call_id -> deterministic operation id -> idempotent, no raise.
    out2 = Peers.copy(args, ctx)
    assert Jason.decode!(out2)["dst_agent_id"] == peer["agent_id"]

    {:ok, manifest2} = AgentWorkspace.manifest(peer["agent_id"])
    assert manifest2["/inbox/report.txt"]["ref"]["uuid"] == src_uuid
    assert blob_count() == before_blobs
  end

  # ---- Default behavior unchanged (same-agent VFS -> VFS) ----

  # ---- Case B: peer VFS -> remote env (chunked stream) ----

  # ---- Case C: remote env -> peer VFS (chunked into a fresh blob, committed) ----

  # ---- Validation / error surface ----

  for {side, args} <- [
        {"src",
         %{
           "src_device_id" => "device-laptop",
           "src_environment" => "laptop",
           "src_path" => "/x",
           "dst_environment" => "vfs",
           "dst_path" => "/y"
         }},
        {"dst",
         %{
           "src_environment" => "vfs",
           "src_path" => "/x",
           "dst_device_id" => "device-laptop",
           "dst_environment" => "laptop",
           "dst_path" => "/y"
         }}
      ] do
  end

  test "an agent_id from a different group is out of scope", %{ctx: ctx} do
    caller_group = SalixStore.Ids.group_id_from_agent!(ctx.agent_id)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(caller_group)
    other_group = SalixStore.Ids.new_group_id(tenant_id)
    stranger_id = SalixStore.Ids.new_agent_id(other_group)

    {:ok, _} =
      S3.put(
        Keys.ctl_agent(stranger_id),
        Jason.encode!(%{
          "agent_id" => stranger_id,
          "tenant" => "t1",
          "template" => "worker",
          "group_id" => other_group
        })
      )

    assert_raise RuntimeError,
                 ~r/env\.copy failed for agent_id "#{Regex.escape(stranger_id)}"/,
                 fn ->
                   Peers.copy(
                     %{
                       "src_environment" => "vfs",
                       "src_path" => "/x",
                       "dst_environment" => "vfs",
                       "dst_path" => "/y",
                       "src_agent_id" => stranger_id
                     },
                     ctx
                   )
                 end
  end

  test "a cross-agent runtime-mount path is rejected as caller-local", %{peer: peer, ctx: ctx} do
    assert_raise RuntimeError, ~r/runtime\/skill mounts are caller-local/, fn ->
      Peers.copy(
        %{
          "src_environment" => "vfs",
          "src_path" => "/.runtime/secret.md",
          "dst_environment" => "vfs",
          "dst_path" => "/y.txt",
          "src_agent_id" => peer["agent_id"]
        },
        ctx
      )
    end
  end
end
