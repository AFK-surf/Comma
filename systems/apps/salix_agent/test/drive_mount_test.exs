defmodule SalixAgent.DriveMountTest do
  @moduledoc """
  The `/drive/...` mount of `SalixAgent.FileBackend` over a fake Drive port:
  routing, path validation, eager writes with no journal event, the bounded
  listing, and the unconfigured refusal.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{DriveMount, FileBackend}

  defmodule FakeDrive do
    @behaviour SalixAgent.Drive

    defp pid, do: Application.fetch_env!(:salix_agent, :drive_test_pid)
    defp files, do: Agent.get(__MODULE__, & &1)

    def put(path, body), do: Agent.update(__MODULE__, &Map.put(&1, path, body))

    @impl true
    def list(group_id, path) do
      send(pid(), {:list, group_id, path})
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
      send(pid(), {:read, group_id, path})

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
      send(pid(), {:write, group_id, path, body, size})
      put(path, body)
      {:ok, %{size: byte_size(body), root: "root"}}
    end

    @impl true
    def delete(group_id, path) do
      send(pid(), {:delete, group_id, path})
      Agent.update(__MODULE__, &Map.delete(&1, path))
      {:ok, %{withdrawn: true, still_published: false}}
    end

    @impl true
    def status(_group_id), do: {:ok, %{available: true, writable: true, detail: "ok"}}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_drive = Application.get_env(:salix_agent, :drive_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    start_supervised!(%{
      id: FakeDrive,
      start: {Agent, :start_link, [fn -> %{} end, [name: FakeDrive]]}
    })

    Application.put_env(:salix_agent, :drive_mod, FakeDrive)
    Application.put_env(:salix_agent, :drive_test_pid, self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      put_or_delete_env(:salix_agent, :drive_mod, prev_drive)
      Application.delete_env(:salix_agent, :drive_test_pid)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    {:ok, ctx: %{agent_id: agent_id, group_id: "grp-drive"}}
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)

  test "the mount is recognised and never a normal workspace path" do
    assert DriveMount.matches?("/drive")
    assert DriveMount.matches?("/drive/")
    assert DriveMount.matches?("/drive/a/b.txt")
    assert DriveMount.matches?("/drive/../drive/x")
    refute DriveMount.matches?("/driver/x")
    refute DriveMount.matches?("/artifacts/drive/x")
    refute FileBackend.normal_path?("/drive/a")
    assert FileBackend.normal_path?("/artifacts/a")
    assert DriveMount.relative("/drive/a/b") == "a/b"
    assert DriveMount.relative("/drive") == ""
  end

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

  test "a whole-tree listing does not sweep the Drive", %{ctx: ctx} do
    FakeDrive.put("top.txt", "t")
    refute Enum.any?(FileBackend.list(ctx, ""), &String.starts_with?(&1, "/drive"))
    refute_received {:list, _, _}
    assert FileBackend.list(ctx, "/artifacts") == []
    refute_received {:list, _, _}
  end

  test "a write is applied as the tool runs and returns no journal event", %{ctx: ctx} do
    assert {:ok, nil} = FileBackend.prepare_write(ctx, "/drive/out/report.md", "# hi")
    assert_received {:write, "grp-drive", "out/report.md", "# hi", 4}
    assert {:ok, "# hi", false} = FileBackend.read(ctx, "/drive/out/report.md")

    assert {:ok, nil} = FileBackend.prepare_delete(ctx, "/drive/out/report.md")
    assert_received {:delete, "grp-drive", "out/report.md"}
    assert {:error, :not_found} = FileBackend.read(ctx, "/drive/out/report.md")
  end

  test "the fs tools carry a Drive write with no events", %{ctx: ctx} do
    ctx = Map.merge(ctx, %{tenant_id: "tenant", session_id: "sess", role: "worker"})

    assert {"wrote 5 bytes to /drive/a.txt", []} =
             SalixAgent.Tools.write_file(%{"path" => "/drive/a.txt", "content" => "hello"}, ctx)

    assert {"edited /drive/a.txt", []} =
             SalixAgent.Tools.edit_file(
               %{"path" => "/drive/a.txt", "old" => "hello", "new" => "bye"},
               ctx
             )

    assert {:ok, "bye", false} = FileBackend.read(ctx, "/drive/a.txt")

    assert {"deleted /drive/a.txt", []} =
             SalixAgent.Tools.delete_file(%{"path" => "/drive/a.txt"}, ctx)
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

  test "malformed Drive paths are refused before the port is asked", %{ctx: ctx} do
    assert {:error, "/drive is a directory"} = FileBackend.prepare_write(ctx, "/drive", "x")
    assert {:error, "/drive is a directory"} = FileBackend.read(ctx, "/drive/")
    assert {:error, "invalid drive path"} = FileBackend.prepare_write(ctx, "/drive/a\0b", "x")
    refute_received {:write, _, _, _, _}
  end

  test "the unconfigured port makes the mount answer with a sentence", %{ctx: ctx} do
    Application.delete_env(:salix_agent, :drive_mod)
    refute DriveMount.available?()
    assert FileBackend.list(ctx, "/drive") == []

    assert {:error, "the Comma Drive is not available on this deployment"} =
             FileBackend.read(ctx, "/drive/a.txt")

    assert {:error, "the Comma Drive is not available on this deployment"} =
             FileBackend.prepare_write(ctx, "/drive/a.txt", "x")

    assert %{"available" => false, "mount" => "/drive"} =
             Jason.decode!(SalixAgent.Tools.Drive.status(%{}, ctx))
  end

  test "drive.status reports the port's answer", %{ctx: ctx} do
    assert %{"available" => true, "writable" => true, "detail" => "ok", "mount" => "/drive"} =
             Jason.decode!(SalixAgent.Tools.Drive.status(%{}, ctx))

    assert Enum.any?(SalixAgent.Tools.registry(), &(elem(&1, 0) == "drive.status"))
  end

  defmodule ShapedDrive do
    @moduledoc "A Drive whose tree shape is a function, to probe the listing bounds."
    @behaviour SalixAgent.Drive

    @impl true
    def list(_group_id, path) do
      send(Application.fetch_env!(:salix_agent, :drive_test_pid), {:list, path})
      shape = Application.fetch_env!(:salix_agent, :drive_test_shape)
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

  defp list_calls(count \\ 0) do
    receive do
      {:list, _path} -> list_calls(count + 1)
    after
      0 -> count
    end
  end

  test "a wide directories-only tree costs one listing, not one per child", %{ctx: ctx} do
    Application.put_env(:salix_agent, :drive_mod, ShapedDrive)

    Application.put_env(:salix_agent, :drive_test_shape, fn
      "" -> Enum.map(1..2_001, &dir("d#{&1}"))
      _child -> []
    end)

    assert FileBackend.list(ctx, "/drive") == []
    assert list_calls() == 1
  end

  test "a branching tree stops at the request budget", %{ctx: ctx} do
    Application.put_env(:salix_agent, :drive_mod, ShapedDrive)

    # Ten subdirectories under every directory, one file in each: 1,110
    # entries within three levels, so only the request budget can end it.
    Application.put_env(:salix_agent, :drive_test_shape, fn path ->
      base = if path == "", do: "", else: path <> "/"
      [file(base <> "f.txt") | Enum.map(1..10, &dir(base <> "s#{&1}"))]
    end)

    paths = FileBackend.list(ctx, "/drive")
    calls = list_calls()
    assert calls <= 256
    assert calls > 100
    assert length(paths) == calls
    assert Enum.all?(paths, &String.starts_with?(&1, "/drive/"))
  end

  test "entries are charged for directories, so a full budget queues no more", %{ctx: ctx} do
    Application.put_env(:salix_agent, :drive_mod, ShapedDrive)

    # 1,999 files and 10 directories at the root: the files and one directory
    # fill the budget, so no directory is listed (nothing in it could be
    # admitted) and `deep.txt` never appears. Without the charge, all ten
    # would be listed and one `deep.txt` admitted.
    Application.put_env(:salix_agent, :drive_test_shape, fn
      "" -> Enum.map(1..1_999, &file("f#{&1}")) ++ Enum.map(1..10, &dir("z#{&1}"))
      _child -> [file("deep.txt")]
    end)

    paths = FileBackend.list(ctx, "/drive")
    assert length(paths) == 1_999
    refute Enum.any?(paths, &String.ends_with?(&1, "deep.txt"))
    assert list_calls() == 1
  end
end
