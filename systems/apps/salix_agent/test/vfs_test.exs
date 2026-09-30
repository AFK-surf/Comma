defmodule SalixAgent.VFSTest do
  @moduledoc """
  VFS: blob storage, a 10 MB cap, manifest
  events, body immutability across delete, copy-shares-ref, and the file tools
  driven end-to-end through activation-scoped LLM/tool rounds. Against the Fake
  backend.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{Blob, Agent, Keys, S3}
  alias SalixAgent.{AgentWorkspace, Fleet, InternalAgentRuntime, State, Tools, WorkspaceEvents}
  alias SalixAgent.InternalSession.State, as: SessionState
  alias SalixAgent.LLM.Mock

  @session_main "ses1_0000000000000000104"
  @session_a "ses1_0000000000000000105"
  @session_b "ses1_0000000000000000106"

  defmodule DenyingStorageAuthorizer do
    @behaviour SalixAgent.StorageAuthorization

    @impl true
    def authorize_write(attrs) do
      send(Application.fetch_env!(:salix_agent, :storage_authorization_test_pid), {
        :storage_authorize,
        attrs
      })

      {:error, {:billing_unavailable, %{allowed?: false, reason: "insufficient_credits"}}}
    end
  end

  defmodule AllowingStorageAuthorizer do
    @behaviour SalixAgent.StorageAuthorization

    @impl true
    def authorize_write(attrs) do
      send(Application.fetch_env!(:salix_agent, :storage_authorization_test_pid), {
        :storage_authorize,
        attrs
      })

      :ok
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_storage_authorization = Application.get_env(:salix_agent, :storage_authorization_mod)

    prev_storage_authorization_test_pid =
      Application.get_env(:salix_agent, :storage_authorization_test_pid)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    prev_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :llm, prev_llm)
      put_or_delete_env(:salix_agent, :storage_authorization_mod, prev_storage_authorization)

      put_or_delete_env(
        :salix_agent,
        :storage_authorization_test_pid,
        prev_storage_authorization_test_pid
      )
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    {:ok, agent: agent_id}
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)

  describe "Blob storage (invariant #3)" do
    test "small and larger bodies both store as canonical blobs and round-trip", %{agent: a} do
      small = String.duplicate("x", 1000)
      big = String.duplicate("y", 20_000)

      assert {:ok, %{kind: "blob", size: 1000} = pref} = Blob.put(a, small)
      assert {:ok, %{kind: "blob", size: 20_000} = bref} = Blob.put(a, big)
      assert {:ok, ^small} = Blob.get(a, pref)
      assert {:ok, ^big} = Blob.get(a, bref)
    end

    test "rejects bodies over the 10MB cap", %{agent: a} do
      huge = String.duplicate("z", 10 * 1024 * 1024 + 1)
      assert {:error, :too_large} = Blob.put(a, huge)
    end
  end

  describe "VFS manifest operations" do
    test "write/read/list/delete/copy through workspace store + S3", %{agent: a} do
      {:ok, ev1} = AgentWorkspace.prepare_write(a, "/notes/a.txt", "alpha")
      {:ok, ev2} = AgentWorkspace.prepare_write(a, "/notes/b.txt", "beta")

      assert {:ok, _} =
               AgentWorkspace.seed_operation(a, "workspace-write", %{"ok" => true}, [ev1, ev2])

      assert AgentWorkspace.list(a, "/notes/") == ["/notes/a.txt", "/notes/b.txt"]
      assert {:ok, "alpha"} = AgentWorkspace.read(a, "/notes/a.txt")

      # copy shares the body ref (CopyBlobRef)
      assert {:ok, _} =
               AgentWorkspace.seed_operation(
                 a,
                 "workspace-copy",
                 %{"ok" => true},
                 [AgentWorkspace.prepare_copy("/notes/a.txt", "/notes/c.txt")]
               )

      assert {:ok, "alpha"} = AgentWorkspace.read(a, "/notes/c.txt")
      {:ok, vfs} = AgentWorkspace.manifest(a)
      assert vfs["/notes/c.txt"]["ref"] == vfs["/notes/a.txt"]["ref"]

      # delete removes the manifest entry but the body remains fetchable by ref
      ref_b = vfs["/notes/b.txt"]["ref"]

      assert {:ok, _} =
               AgentWorkspace.seed_operation(
                 a,
                 "workspace-delete",
                 %{"ok" => true},
                 [AgentWorkspace.prepare_delete("/notes/b.txt")]
               )

      assert {:error, :not_found} = AgentWorkspace.read(a, "/notes/b.txt")
      assert {:ok, "beta"} = Blob.get(a, ref_b)
    end

    test "workspace operations are idempotent by operation_id", %{agent: a} do
      {:ok, first_write} = AgentWorkspace.prepare_write(a, "/notes/op.txt", "first")

      assert {:ok, %{"path" => "/notes/op.txt", "version" => 1}} =
               AgentWorkspace.seed_operation(
                 a,
                 "workspace-op-1",
                 %{"path" => "/notes/op.txt", "version" => 1},
                 [first_write]
               )

      assert {:ok, "first"} = AgentWorkspace.read(a, "/notes/op.txt")

      {:ok, second_write} = AgentWorkspace.prepare_write(a, "/notes/op.txt", "second")

      assert {:ok, %{"path" => "/notes/op.txt", "version" => 1}} =
               AgentWorkspace.seed_operation(
                 a,
                 "workspace-op-1",
                 %{"path" => "/notes/op.txt", "version" => 2},
                 [second_write]
               )

      assert {:ok, "first"} = AgentWorkspace.read(a, "/notes/op.txt")

      assert {:ok, "first"} = AgentWorkspace.read(a, "/notes/op.txt")

      {:ok, workspace_state} = AgentWorkspace.read_state(a)
      assert workspace_state.operations["workspace-op-1"]["result"]["version"] == 1
    end

    test "low-level workspace commit only accepts the local agent owner", %{agent: a} do
      {:ok, write_event} = AgentWorkspace.prepare_write(a, "/notes/not-owner.txt", "blocked")

      assert {:error, :not_agent_owner} =
               AgentWorkspace.commit_operation(
                 a,
                 "not-owner",
                 %{"ok" => true},
                 [write_event]
               )

      assert {:error, :not_found} = AgentWorkspace.read(a, "/notes/not-owner.txt")
    end

    test "public write and delete are idempotent across request retries", %{agent: a} do
      assert {:ok, first} =
               SalixAgent.Workspace.write(a, "/notes/public.txt", "first",
                 idempotency_key: "write-public"
               )

      assert {:ok, ^first} =
               SalixAgent.Workspace.write(a, "/notes/public.txt", "second",
                 idempotency_key: "write-public"
               )

      assert {:ok, "first"} = AgentWorkspace.read(a, "/notes/public.txt")

      assert {:ok, deleted} =
               SalixAgent.Workspace.delete(a, "/notes/public.txt",
                 idempotency_key: "delete-public"
               )

      assert deleted == %{"path" => "/notes/public.txt", "deleted" => 1}

      assert {:ok, ^deleted} =
               SalixAgent.Workspace.delete(a, "/notes/public.txt",
                 idempotency_key: "delete-public"
               )

      assert {:error, :not_found} = AgentWorkspace.read(a, "/notes/public.txt")
    end

    test "public delete without an idempotency key does not turn history into success", %{
      agent: a
    } do
      assert {:ok, _} = SalixAgent.Workspace.write(a, "/notes/delete-once.txt", "content")
      assert {:ok, %{"deleted" => 1}} = SalixAgent.Workspace.delete(a, "/notes/delete-once.txt")

      assert {:error, :not_found} = SalixAgent.Workspace.delete(a, "/notes/delete-once.txt")
    end

    test "validated control projections still reject hidden and archived site reads", %{
      agent: a
    } do
      assert {:ok, agent} = SalixAgent.Control.get_record(a)

      for invisible <- [Map.put(agent, "hidden", true), Map.put(agent, "archived_at", 1)] do
        assert {:error, :not_found} = SalixAgent.Workspace.list_sites(invisible)
      end
    end

    test "billing unavailable blocks mutating workspace writes while reads remain available", %{
      agent: a
    } do
      assert {:ok, _} = SalixAgent.Workspace.write(a, "/notes/existing.txt", "still readable")

      Application.put_env(:salix_agent, :storage_authorization_mod, DenyingStorageAuthorizer)
      Application.put_env(:salix_agent, :storage_authorization_test_pid, self())

      billing_context = %{
        "billing_account_id" => "ba-storage-zero",
        "entrypoint" => "storage_write",
        "actor_type" => "user"
      }

      assert {:error, {:billing_unavailable, %{allowed?: false}}} =
               SalixAgent.Workspace.write(a, "/notes/blocked.txt", "blocked",
                 billing_context: billing_context
               )

      assert_receive {:storage_authorize,
                      %{
                        agent_id: ^a,
                        events: [%{"type" => "vfs_write"}],
                        billing_context: ^billing_context
                      }}

      assert {:error, :not_found} = AgentWorkspace.read(a, "/notes/blocked.txt")
      assert {:ok, "still readable"} = SalixAgent.Workspace.read(a, "/notes/existing.txt")
    end

    test "denied workspace write is authorized before blob storage and can derive billing owner",
         %{
           agent: a
         } do
      {:ok, before_blobs} = S3.list_all("blobs/")
      group_id = SalixStore.Ids.group_id_from_agent!(a)
      tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

      {:ok, _} =
        S3.put(
          Keys.ctl_group(group_id),
          Jason.encode!(%{
            "tenant_id" => tenant_id,
            "group_id" => group_id,
            "router_conversation_id" => SalixStore.Ids.new_conversation_id(),
            "billing_owner" => %{
              "billing_account_id" => "ba-storage-derived",
              "surface" => "bridge",
              "product_owner_type" => "organization",
              "product_owner_id" => "org-storage-derived",
              "salix_tenant_id" => tenant_id,
              "salix_group_id" => group_id
            }
          })
        )

      Application.put_env(:salix_agent, :storage_authorization_mod, DenyingStorageAuthorizer)
      Application.put_env(:salix_agent, :storage_authorization_test_pid, self())

      assert {:error, {:billing_unavailable, %{allowed?: false}}} =
               SalixAgent.Workspace.write(a, "/notes/derived-blocked.txt", "blocked")

      assert_receive {:storage_authorize,
                      %{
                        agent_id: ^a,
                        events: [%{"type" => "vfs_write"}],
                        billing_context: %{"billing_account_id" => "ba-storage-derived"}
                      }}

      {:ok, after_blobs} = S3.list_all("blobs/")
      assert Enum.map(after_blobs, & &1.key) == Enum.map(before_blobs, & &1.key)
      assert {:error, :not_found} = AgentWorkspace.read(a, "/notes/derived-blocked.txt")
    end

    test "denied tool write is authorized before blob storage", %{agent: a} do
      {:ok, before_blobs} = S3.list_all("blobs/")
      group_id = SalixStore.Ids.group_id_from_agent!(a)
      tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

      {:ok, _} =
        S3.put(
          Keys.ctl_group(group_id),
          Jason.encode!(%{
            "tenant_id" => tenant_id,
            "group_id" => group_id,
            "router_conversation_id" => SalixStore.Ids.new_conversation_id(),
            "billing_owner" => %{
              "billing_account_id" => "ba-storage-tool-zero",
              "surface" => "bridge",
              "product_owner_type" => "organization",
              "product_owner_id" => "org-storage-tool-zero",
              "salix_tenant_id" => tenant_id,
              "salix_group_id" => group_id
            }
          })
        )

      Application.put_env(:salix_agent, :storage_authorization_mod, DenyingStorageAuthorizer)
      Application.put_env(:salix_agent, :storage_authorization_test_pid, self())

      assert_raise RuntimeError, ~r/billing_unavailable/, fn ->
        Tools.write_file(
          %{"path" => "/notes/tool-blocked.txt", "content" => "blocked"},
          %{agent_id: a, session_id: @session_main}
        )
      end

      assert_receive {:storage_authorize,
                      %{
                        agent_id: ^a,
                        events: [%{"type" => "vfs_write"}],
                        billing_context: %{"billing_account_id" => "ba-storage-tool-zero"}
                      }}

      {:ok, after_blobs} = S3.list_all("blobs/")
      assert Enum.map(after_blobs, & &1.key) == Enum.map(before_blobs, & &1.key)
      assert {:error, :not_found} = AgentWorkspace.read(a, "/notes/tool-blocked.txt")
    end

    test "storage write authorizer allows active billing context", %{agent: a} do
      Application.put_env(:salix_agent, :storage_authorization_mod, AllowingStorageAuthorizer)
      Application.put_env(:salix_agent, :storage_authorization_test_pid, self())

      billing_context = %{"billing_account_id" => "ba-storage-active"}

      assert {:ok, %{"path" => "/notes/allowed.txt"}} =
               SalixAgent.Workspace.write(a, "/notes/allowed.txt", "allowed",
                 billing_context: billing_context
               )

      assert_receive {:storage_authorize,
                      %{
                        agent_id: ^a,
                        entrypoint: "storage_write",
                        billing_context: ^billing_context
                      }}

      assert {:ok, "allowed"} = SalixAgent.Workspace.read(a, "/notes/allowed.txt")
    end

    test "tool workspace operation ids are scoped by session while sharing agent workspace", %{
      agent: a
    } do
      {:ok, session_a_write} = AgentWorkspace.prepare_write(a, "/notes/session-a.txt", "A1")
      {:ok, session_b_write} = AgentWorkspace.prepare_write(a, "/notes/session-b.txt", "B1")

      result_a = %{
        id: "same-tool-call",
        name: "fs.write_file",
        status: "completed",
        content: "wrote A",
        events: [session_a_write]
      }

      result_b = %{
        id: "same-tool-call",
        name: "fs.write_file",
        status: "completed",
        content: "wrote B",
        events: [session_b_write]
      }

      assert {:ok, %{events: []}} =
               WorkspaceEvents.commit_result(a, @session_a, result_a, "tool-result")

      assert {:ok, %{events: []}} =
               WorkspaceEvents.commit_result(a, @session_b, result_b, "tool-result")

      assert {:ok, "A1"} = AgentWorkspace.read(a, "/notes/session-a.txt")
      assert {:ok, "B1"} = AgentWorkspace.read(a, "/notes/session-b.txt")

      {:ok, retry_write} = AgentWorkspace.prepare_write(a, "/notes/session-a.txt", "A2")

      assert {:ok, %{events: []}} =
               WorkspaceEvents.commit_result(
                 a,
                 @session_a,
                 %{result_a | content: "retry A", events: [retry_write]},
                 "tool-result"
               )

      assert {:ok, "A1"} = AgentWorkspace.read(a, "/notes/session-a.txt")

      {:ok, workspace_state} = AgentWorkspace.read_state(a)

      assert Map.has_key?(
               workspace_state.operations,
               "tool-result:#{a}:#{@session_a}:same-tool-call"
             )

      assert Map.has_key?(
               workspace_state.operations,
               "tool-result:#{a}:#{@session_b}:same-tool-call"
             )
    end

    test "tool workspace result requires a stable tool call id", %{agent: a} do
      {:ok, write_event} = AgentWorkspace.prepare_write(a, "/notes/missing-id.txt", "bad")

      assert {:error, :missing_tool_call_id} =
               WorkspaceEvents.commit_result(
                 a,
                 @session_a,
                 %{name: "fs.write_file", status: "completed", events: [write_event]},
                 "tool-result"
               )

      assert {:error, :not_found} = AgentWorkspace.read(a, "/notes/missing-id.txt")

      {:ok, workspace_state} = AgentWorkspace.read_state(a)
      assert workspace_state.operations == %{}
    end

    test "delivery workspace operation ids are scoped by session", %{agent: a} do
      SalixAgent.TestSupport.create_control_agent!(a)

      {:ok, write_a} = AgentWorkspace.prepare_write(a, "/notes/delivery-a.txt", "A")
      {:ok, write_b} = AgentWorkspace.prepare_write(a, "/notes/delivery-b.txt", "B")

      source_message_id = "same-source"

      assert {:ok, :committed} =
               SalixAgent.InternalSessionFleet.stage_delivery(a, @session_a, %{
                 source_message_id: source_message_id,
                 payload: %{
                   session_id: @session_a,
                   content: "write A",
                   events: [write_a]
                 }
               })

      assert {:ok, :committed} =
               SalixAgent.InternalSessionFleet.stage_delivery(a, @session_b, %{
                 source_message_id: source_message_id,
                 payload: %{
                   session_id: @session_b,
                   content: "write B",
                   events: [write_b]
                 }
               })

      assert {:ok, "A"} = AgentWorkspace.read(a, "/notes/delivery-a.txt")
      assert {:ok, "B"} = AgentWorkspace.read(a, "/notes/delivery-b.txt")

      {:ok, workspace_state} = AgentWorkspace.read_state(a)

      assert Map.has_key?(
               workspace_state.operations,
               "delivery-workspace:#{a}:#{@session_a}:#{source_message_id}"
             )

      assert Map.has_key?(
               workspace_state.operations,
               "delivery-workspace:#{a}:#{@session_b}:#{source_message_id}"
             )
    end
  end

  describe "file tools end-to-end through activation-scoped rounds" do
    test "agent writes a file via a tool, then reads it back; survives replay", %{agent: a} do
      Mock.script([
        {:assistant, "writing",
         [
           %{
             id: "w1",
             name: "call",
             args: %{
               "tool" => "fs.write_file",
               "params" => %{"path" => "/out.txt", "content" => "from tool"}
             }
           }
         ]},
        {:assistant, "reading",
         [
           %{
             id: "r1",
             name: "call",
             args: %{
               "tool" => "fs.read_file",
               "params" => %{"path" => "/out.txt"}
             }
           }
         ]},
        {:final, "done"}
      ])

      {:ok, _pid} = Fleet.ensure_started(a, create: true)

      {:ok, :created} =
        deliver(a, "u1", %{content: "make a file", session_id: @session_main})

      SalixAgent.Server.wake(a)
      {:parked, _owned} = SalixAgent.Server.info(a)
      assert eventually(fn -> internal_sessions_settled?(a) end, 200)

      write_result = await_tool_terminal!(a, @session_main, "w1")
      read_result = await_tool_terminal!(a, @session_main, "r1")

      assert tool_result_value(write_result, "status") == "completed"
      assert tool_result_value(read_result, "status") == "completed"

      assert eventually(
               fn ->
                 read_session!(a, @session_main).messages
                 |> Enum.any?(&(&1[:role] == "assistant" and &1[:content] == "done"))
               end,
               300
             )

      # the file is in the manifest
      assert {:ok, "from tool"} = AgentWorkspace.read(a, "/out.txt")

      # The zero-wait transcript keeps the running acknowledgement while the
      # terminal result carries the actual read payload.
      assert tool_result_value(read_result, "content") == "from tool"

      # Fresh claim replays the runtime session; workspace is loaded from its own store.
      {:ok, fresh} = Agent.claim(a, "other", State, steal: true)
      refute Map.has_key?(fresh.state, :vfs)
      assert {:ok, "from tool"} = AgentWorkspace.read(a, "/out.txt")
    end
  end

  defp internal_sessions_settled?(agent) do
    case SalixAgent.InternalSessionStore.list(agent) do
      {:ok, sessions} ->
        Enum.all?(
          sessions,
          &(SalixAgent.InternalSession.derived_state(&1) not in [:queued, :active])
        )

      {:error, _} ->
        false
    end
  end

  defp eventually(fun, retries) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  # A zero-wait tool has two valid terminal encodings: a dependency that wins
  # the zero-time yield is committed directly to the transcript, while a live
  # dependency first publishes `running` and later commits an async result.
  # Observe both; the bounded wait is only for the latter path to settle.
  defp await_tool_terminal!(agent_id, session_id, tool_call_id, retries \\ 1_200)

  defp await_tool_terminal!(_agent_id, _session_id, tool_call_id, 0) do
    flunk("tool call #{tool_call_id} did not reach a terminal result")
  end

  defp await_tool_terminal!(agent_id, session_id, tool_call_id, retries) do
    case terminal_tool_result(agent_id, session_id, tool_call_id) do
      nil ->
        Process.sleep(10)
        await_tool_terminal!(agent_id, session_id, tool_call_id, retries - 1)

      result ->
        result
    end
  end

  defp terminal_tool_result(agent_id, session_id, tool_call_id) do
    case InternalAgentRuntime.get_async_tool_call(agent_id, session_id, tool_call_id) do
      {:ok, result} ->
        if terminal_tool_result?(result), do: result

      {:error, :not_found} ->
        agent_id
        |> read_session!(session_id)
        |> Map.get(:messages, [])
        |> Enum.find(fn message ->
          (message[:tool_call_id] || message["tool_call_id"]) == tool_call_id and
            terminal_tool_result?(message)
        end)

      {:error, _reason} ->
        nil
    end
  end

  defp terminal_tool_result?(result) when is_map(result) do
    tool_result_value(result, "status") not in [nil, "async_running", "running"]
  end

  defp terminal_tool_result?(_result), do: false

  defp tool_result_value(result, key) when is_map(result) and is_binary(key) do
    case map_value(result, key) do
      nil ->
        case map_value(result, "result") do
          payload when is_map(payload) -> map_value(payload, key)
          _other -> nil
        end

      value ->
        value
    end
  end

  defp map_value(map, key) do
    case Enum.find(map, fn {candidate, _value} -> to_string(candidate) == key end) do
      {_candidate, value} -> value
      nil -> nil
    end
  end

  defp read_session!(agent_id, session_id) do
    {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent_id, session_id)
    session
  end

  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end
end
