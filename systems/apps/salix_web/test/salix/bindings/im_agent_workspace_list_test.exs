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
