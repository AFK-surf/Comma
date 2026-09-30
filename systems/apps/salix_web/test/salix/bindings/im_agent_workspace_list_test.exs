defmodule Salix.Bindings.IMAgentWorkspaceListTest do
  @moduledoc """
  The IM workspace port's `list/2` binding, which is what answers an `ls`
  control command in a chat.

  Its contract is the three-way answer the port documents — a directory, a
  file, or neither — because the chat surface words each one differently and
  cannot tell them apart from a flattened error. The rest of the binding is
  covered by the provider file tests that use it.
  """
  use ExUnit.Case, async: false

  alias Salix.Bindings.IMAgentWorkspace

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      case previous do
        nil -> Application.delete_env(:salix_store, :s3_backend)
        backend -> Application.put_env(:salix_store, :s3_backend, backend)
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

  test "a directory answers with one level of entries", %{agent_id: agent_id} do
    assert {:ok, entries} = IMAgentWorkspace.list(agent_id, "/")
    assert Enum.any?(entries, &(&1["path"] == "/artifacts/" and &1["kind"] == "dir"))

    assert {:ok, [entry]} = IMAgentWorkspace.list(agent_id, "/artifacts")
    assert entry["path"] == "/artifacts/report.md"
    assert entry["kind"] == "file"
    assert entry["size"] == 14
  end

  # A file is NOT an error: `ls` on a file names the file, the way a shell
  # does, and `cat` uses this branch to tell a real file from a directory
  # before it fetches any bytes.
  test "a file answers as a file", %{agent_id: agent_id} do
    assert {:file, file} = IMAgentWorkspace.list(agent_id, "/artifacts/report.md")
    assert file["path"] == "/artifacts/report.md"
    assert file["size"] == 14
  end

  # `:not_found` stays an ATOM through the binding. Flattened to a sentence
  # like the port's other callbacks, the chat surface could not tell a typo
  # from an unreachable workspace, and would word both the same way.
  test "neither is a matchable :not_found", %{agent_id: agent_id} do
    assert {:error, :not_found} = IMAgentWorkspace.list(agent_id, "/nope")
    assert {:error, :not_found} = IMAgentWorkspace.list(agent_id, "/artifacts/nope.md")
  end

  # The root of a workspace nothing has written to is an empty directory, not a
  # missing path: a chat answer of "no such path: /" would be nonsense.
  test "the root of an untouched workspace is empty, not missing" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => "router"})

    assert {:ok, []} = IMAgentWorkspace.list(agent_id, "/")
  end

  test "a blank agent id cannot reach a workspace" do
    assert {:error, _reason} = IMAgentWorkspace.list("", "/")
  end

  test "attachment delivery retains a real storage failure while provider put_ref keeps a display error",
       %{agent_id: agent_id} do
    previous = Application.get_env(:salix_im, :agent_workspace_mod)
    Application.put_env(:salix_im, :agent_workspace_mod, IMAgentWorkspace)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_im, :agent_workspace_mod, previous),
        else: Application.delete_env(:salix_im, :agent_workspace_mod)
    end)

    assert {:ok, ref} = IMAgentWorkspace.file_ref(agent_id, "/artifacts/report.md")

    :ok =
      SalixStore.S3.Fake.blackhole(
        {:fail, 503, :put, SalixStore.Keys.agent_workspace_state(agent_id)}
      )

    assert {:error, {:http, 503}} = IMAgentWorkspace.put_ref(agent_id, "/copy.md", ref)

    assert {:error, "{:http, 503}"} =
             SalixIM.Ports.AgentWorkspace.put_ref(agent_id, "/copy.md", ref)

    record = %{
      "participant_actor_type" => "agent",
      "participant_agent_id" => agent_id,
      "participant_payload" => %{"session_id" => SalixStore.Ids.new_session_id()},
      "participant_id" => SalixStore.Ids.new_participant_id(),
      "conversation_id" => SalixStore.Ids.new_conversation_id(),
      "message_id" => SalixStore.Ids.new_message_id(),
      "source_actor_type" => "agent",
      "source_agent_id" => SalixAgent.TestSupport.new_agent_id(),
      "message_content" => [%{"type" => "file", "path" => "/report.md", "blob_ref" => ref}]
    }

    assert {:error, {:conversation_attachment, "/report.md", {:http, 503}}} =
             SalixIM.ConversationAttachments.materialize_delivery(agent_id, record)

    assert {:error, message, true} = SalixIM.ConversationDelivery.materialize_agent(record)
    assert is_binary(message)
    assert message =~ "cannot share Conversation attachment /report.md"
  end
end
