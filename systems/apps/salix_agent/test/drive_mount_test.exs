defmodule SalixAgent.DriveMountTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The `/drive/...` mount of `SalixAgent.FileBackend` over a fake Drive port:
  routing, path validation, eager writes with no journal event, the bounded
  listing, and the unconfigured refusal.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{DriveMount, FileBackend}

  defmodule FakeDrive do
    @behaviour SalixAgent.Drive

    defp pid, do: SystemsRuntime.fetch_env!(:salix_agent, :drive_test_pid)
    defp files, do: Agent.get(__MODULE__, & &1)

    def put(path, body), do: Agent.update(__MODULE__, &Map.put(&1, path, body))

    @impl true
    def list(group_id, path) do
      SystemsRuntime.Proc.send(pid(), {:list, group_id, path})
      prefix = if path == "", do: "", else: path <> "/"

      entries =
        files()
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.map(fn full ->
          rel = String.replace_prefix(full, prefix, "")

          case String.split(rel, "/", parts: 2) do
            [name] ->
              %{
                path: full,
                name: name,
                kind: "file",
                size: byte_size(files()[full]),
                modified_at: 1
              }

            [dir, _rest] ->
              %{path: prefix <> dir, name: dir, kind: "dir", size: 0, modified_at: nil}
          end
        end)
        |> Enum.uniq()

      {:ok, entries}
    end

    @impl true
    def stat(_group_id, path) do
      case files()[path] do
        nil ->
          {:error, :not_found}

        body ->
          {:ok,
           %{
             path: path,
             name: Path.basename(path),
             kind: "file",
             size: byte_size(body),
             modified_at: 1
           }}
      end
    end

    @impl true
    def read(group_id, path, max_bytes) do
      SystemsRuntime.Proc.send(pid(), {:read, group_id, path})

      case files()[path] do
        nil -> {:error, :not_found}
        body when byte_size(body) > max_bytes -> {:ok, binary_part(body, 0, max_bytes), true}
        body -> {:ok, body, false}
      end
    end

    @impl true
    def stream(_group_id, path) do
      case files()[path] do
        nil -> {:error, :not_found}
        body -> {:ok, [body], byte_size(body)}
      end
    end

    @impl true
    def write(group_id, path, body, size) do
      body = if is_binary(body), do: body, else: body |> Enum.to_list() |> IO.iodata_to_binary()
      SystemsRuntime.Proc.send(pid(), {:write, group_id, path, body, size})
      put(path, body)
      {:ok, %{size: byte_size(body), root: "root"}}
    end

    @impl true
    def delete(group_id, path) do
      SystemsRuntime.Proc.send(pid(), {:delete, group_id, path})
      Agent.update(__MODULE__, &Map.delete(&1, path))
      {:ok, %{withdrawn: true, still_published: false}}
    end

    @impl true
    def status(_group_id), do: {:ok, %{available: true, writable: true, detail: "ok"}}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_drive = SystemsRuntime.get_env(:salix_agent, :drive_mod)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    start_supervised!(%{
      id: FakeDrive,
      start: {Agent, :start_link, [fn -> %{} end, [name: FakeDrive]]}
    })

    SystemsRuntime.put_env(:salix_agent, :drive_mod, FakeDrive)
    SystemsRuntime.put_env(:salix_agent, :drive_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
      put_or_delete_env(:salix_agent, :drive_mod, prev_drive)
      SystemsRuntime.delete_env(:salix_agent, :drive_test_pid)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    {:ok, ctx: %{agent_id: agent_id, group_id: "grp-drive"}}
  end

  defp put_or_delete_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  test "reads, stats and lists go to the group's Drive", %{ctx: ctx} do
    FakeDrive.put("notes/todo.md", "buy milk")
    FakeDrive.put("notes/deep/x.txt", "x")
    FakeDrive.put("top.txt", "t")

    assert {:ok, "buy milk", false} = FileBackend.read(ctx, "/drive/notes/todo.md")
    assert_received {:read, "grp-drive", "notes/todo.md"}
    assert {:error, :not_found} = FileBackend.read(ctx, "/drive/notes/missing.md")

    assert {:ok, %{kind: "file", size: 8}} = FileBackend.stat(ctx, "/drive/notes/todo.md")
    assert {:ok, %{kind: "dir"}} = FileBackend.stat(ctx, "/drive")

    assert FileBackend.list(ctx, "/drive") ==
             ["/drive/notes/deep/x.txt", "/drive/notes/todo.md", "/drive/top.txt"]

    assert FileBackend.list(ctx, "/drive/notes") ==
             ["/drive/notes/deep/x.txt", "/drive/notes/todo.md"]

    assert FileBackend.list(ctx, "/drive/top.txt") == ["/drive/top.txt"]
    assert {:ok, [body], 8} = FileBackend.stream(ctx, "/drive/notes/todo.md")
    assert body == "buy milk"
  end

  test "a write is applied as the tool runs and returns no journal event", %{ctx: ctx} do
    assert {:ok, nil} = FileBackend.prepare_write(ctx, "/drive/out/report.md", "# hi")
    assert_received {:write, "grp-drive", "out/report.md", "# hi", 4}
    assert {:ok, "# hi", false} = FileBackend.read(ctx, "/drive/out/report.md")

    assert {:ok, nil} = FileBackend.prepare_delete(ctx, "/drive/out/report.md")
    assert_received {:delete, "grp-drive", "out/report.md"}
    assert {:error, :not_found} = FileBackend.read(ctx, "/drive/out/report.md")
  end

  test "copy and move cross between the workspace and the Drive", %{ctx: ctx} do
    agent_id = ctx.agent_id

    {:ok, event} =
      SalixAgent.AgentWorkspace.prepare_write(agent_id, "/artifacts/src.txt", "payload")

    {:ok, _} =
      SalixAgent.AgentActor.commit_workspace_operation(agent_id, "op-src", %{}, [event], [])

    # Workspace -> Drive: the Drive takes the bytes now; no event is left to commit.
    assert {:ok, [], 7} = FileBackend.prepare_copy(ctx, "/artifacts/src.txt", "/drive/dst.txt")
    assert_received {:write, "grp-drive", "dst.txt", "payload", 7}

    # Drive -> workspace: an ordinary workspace write event, body from the Drive.
    assert {:ok, [%{"type" => "vfs_write", "path" => "/artifacts/back.txt", "size" => 7}], 7} =
             FileBackend.prepare_copy(ctx, "/drive/dst.txt", "/artifacts/back.txt")

    # A move out of the Drive withdraws the source only after the copy succeeded.
    assert {:ok, [%{"type" => "vfs_write"}], 7} =
             FileBackend.prepare_move(ctx, "/drive/dst.txt", "/artifacts/moved.txt")

    assert_received {:delete, "grp-drive", "dst.txt"}
  end

  defmodule ShapedDrive do
    @moduledoc "A Drive whose tree shape is a function, to probe the listing bounds."
    @behaviour SalixAgent.Drive

    @impl true
    def list(_group_id, path) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :drive_test_pid),
        {:list, path}
      )

      shape = SystemsRuntime.fetch_env!(:salix_agent, :drive_test_shape)
      {:ok, shape.(path)}
    end

    @impl true
    def stat(_group_id, _path), do: {:error, :not_found}
    @impl true
    def read(_group_id, _path, _max_bytes), do: {:error, :not_found}
    @impl true
    def stream(_group_id, _path), do: {:error, :not_found}
    @impl true
    def write(_group_id, _path, _body, _size), do: {:error, :drive_not_configured}
    @impl true
    def delete(_group_id, _path), do: {:error, :drive_not_configured}
    @impl true
    def status(_group_id), do: {:ok, %{available: true, writable: false, detail: "shaped"}}
  end

  defp dir(path),
    do: %{path: path, name: Path.basename(path), kind: "dir", size: 0, modified_at: nil}

  defp file(path),
    do: %{path: path, name: Path.basename(path), kind: "file", size: 1, modified_at: nil}
end
