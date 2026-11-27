defmodule Salix.Bindings.IMAgentWorkspaceListTest do
  @moduledoc """
  The IM workspace port's `list/2` binding, which is what answers an `ls`
  control command in a chat.

  Its contract is the three-way answer the port documents — a directory, a
  file, or neither — because the chat surface words each one differently and
  cannot tell them apart from a flattened error. It also holds the stream read
  of a file too large to read whole. The rest of the binding is covered by the
  provider file tests that use it.
  """
  use SystemsClock.Case, async: false

  alias Salix.Bindings.IMAgentWorkspace

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      case previous do
        nil -> SystemsRuntime.delete_env(:salix_store, :s3_backend)
        backend -> SystemsRuntime.put_env(:salix_store, :s3_backend, backend)
      end
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => "router"})

    {:ok, _file} =
      SalixAgent.Workspace.write(agent_id, "/artifacts/report.md", "launch report\n",
        create: true
      )

    %{agent_id: agent_id}
  end

  test "a trusted blob import preserves its source audience", %{agent_id: agent_id} do
    {:ok, ref} = SalixStore.Blob.put_stream(agent_id, ["private attachment"])
    label = ["task|" <> SalixStore.Ids.new_conversation_id()]

    assert {:ok, _} =
             SalixAgent.Workspace.put_ref(agent_id, "/imported.bin", ref,
               create: true,
               ifc_label: label
             )

    assert SalixAgent.AgentWorkspace.label(agent_id, "/imported.bin") == label
  end

  test "a blob import cannot lower an existing destination audience", %{agent_id: agent_id} do
    {:ok, ref} = SalixStore.Blob.put_stream(agent_id, ["replacement"])

    assert {:ok, _} =
             SalixAgent.Workspace.write(agent_id, "/restricted.bin", "original",
               create: true,
               ifc_label: ["agent_private"]
             )

    assert {:ok, _} =
             SalixAgent.Workspace.put_ref(agent_id, "/restricted.bin", ref,
               create: true,
               ifc_label: ["public"]
             )

    assert SalixAgent.AgentWorkspace.label(agent_id, "/restricted.bin") == ["agent_private"]
  end

  test "an unlabelled existing destination remains private on blob import", %{agent_id: agent_id} do
    {:ok, ref} = SalixStore.Blob.put_stream(agent_id, ["replacement"])

    assert {:ok, _} =
             SalixAgent.Workspace.put_ref(agent_id, "/artifacts/report.md", ref,
               create: true,
               ifc_label: ["public"]
             )

    assert SalixAgent.AgentWorkspace.label(agent_id, "/artifacts/report.md") == ["agent_private"]
  end

  test "cross-agent attachment materialization preserves trusted labels, not block claims", %{
    agent_id: sender
  } do
    previous = SystemsRuntime.get_env(:salix_im, :agent_workspace_mod)
    SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, IMAgentWorkspace)
    on_exit(fn -> SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, previous) end)
    receiver = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(receiver, %{"role" => "worker"})
    label = ["task|" <> SalixStore.Ids.new_conversation_id()]

    {:ok, _} =
      SalixAgent.Workspace.write(sender, "/source.bin", "attachment",
        create: true,
        ifc_label: label
      )

    {:ok, ref} = IMAgentWorkspace.file_ref(sender, "/source.bin")

    message = %{
      "actor_type" => "agent",
      "agent_id" => sender,
      "message_id" => SalixStore.Ids.new_message_id(),
      "content" => [
        %{"type" => "file", "path" => "/source.bin", "blob_ref" => ref, "ifc_label" => ["public"]}
      ]
    }

    assert {:ok, [delivered]} =
             SalixIM.ConversationAttachments.materialize_messages(receiver, [message])

    [block] = delivered["content"]
    assert SalixAgent.AgentWorkspace.label(receiver, block["path"]) == label

    # An old immutable blob must not acquire a replacement path's public label.
    {:ok, _} =
      SalixAgent.Workspace.write(sender, "/source.bin", "different bytes",
        create: true,
        ifc_label: ["public"]
      )

    stale = Map.put(message, "message_id", SalixStore.Ids.new_message_id())

    assert {:ok, [stale_delivery]} =
             SalixIM.ConversationAttachments.materialize_messages(receiver, [stale])

    [stale_block] = stale_delivery["content"]
    assert SalixAgent.AgentWorkspace.label(receiver, stale_block["path"]) == nil
  end

  test "provider staging uses the trusted ingress audience", %{agent_id: agent_id} do
    previous = SystemsRuntime.get_env(:salix_im, :agent_workspace_mod)
    SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, IMAgentWorkspace)
    on_exit(fn -> SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, previous) end)
    {:ok, ref} = SalixStore.Blob.put_stream(agent_id, ["provider attachment"])

    attachment = %{
      "path" => "/incoming.bin",
      "ifc_label" => ["public"],
      "to_blob" => fn _ -> {:ok, ref} end
    }

    label = ["task|" <> SalixStore.Ids.new_conversation_id()]
    assert {:ok, [_], []} = SalixIM.ProviderAttachments.stage(agent_id, [attachment], label)
    assert SalixAgent.AgentWorkspace.label(agent_id, "/incoming.bin") == label

    assert {:ok, [_], []} =
             SalixIM.ProviderAttachments.stage(
               agent_id,
               [Map.put(attachment, "path", "/unknown.bin")]
             )

    assert SalixAgent.AgentWorkspace.label(agent_id, "/unknown.bin") == nil
  end

  test "a directory answers with one level of entries", %{agent_id: agent_id} do
    assert {:ok, entries} = IMAgentWorkspace.list(agent_id, "/")
    assert Enum.any?(entries, &(&1["path"] == "/artifacts/" and &1["kind"] == "dir"))

    assert {:ok, [entry]} = IMAgentWorkspace.list(agent_id, "/artifacts")
    assert entry["path"] == "/artifacts/report.md"
    assert entry["kind"] == "file"
    assert entry["size"] == 14
  end

  # A provider that sends a large file (QQ sends up to 200 MiB) depends on
  # this: a whole-file read stops at the blob read cap, and the stream does not.
  test "a file over the whole-file read cap is still read as a stream", %{agent_id: agent_id} do
    mib = 1024 * 1024
    chunks = for byte <- 0..10, do: :binary.copy(<<byte>>, mib)
    size = 11 * mib
    assert size > SalixStore.Blob.max_bytes()

    {:ok, ref} = SalixStore.Blob.put_stream(agent_id, chunks)
    assert {:ok, _file} = IMAgentWorkspace.put_ref(agent_id, "/artifacts/big.bin", ref)

    assert {:error, _too_large} = IMAgentWorkspace.read_upload(agent_id, "/artifacts/big.bin", "")

    assert {:ok, stream, ^size, "big.bin"} =
             IMAgentWorkspace.read_stream(agent_id, "/artifacts/big.bin")

    digest = Enum.reduce(stream, :crypto.hash_init(:md5), &:crypto.hash_update(&2, &1))
    assert :crypto.hash_final(digest) == :crypto.hash(:md5, chunks)
  end

  # A file is NOT an error: `ls` on a file names the file, the way a shell
  # does, and `cat` uses this branch to tell a real file from a directory
  # before it fetches any bytes.
  test "a file answers as a file", %{agent_id: agent_id} do
    assert {:file, file} = IMAgentWorkspace.list(agent_id, "/artifacts/report.md")
    assert file["path"] == "/artifacts/report.md"
    assert file["size"] == 14
  end
end
