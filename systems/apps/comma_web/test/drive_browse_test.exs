defmodule CommaWeb.DriveBrowseTest do
  use Comma.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  @moduletag :capture_log

  @admin_token "test-token"
  @opts CommaWeb.Router.init([])

  # A Drive with one listing per directory, the way `browse/ls` answers.
  defmodule FakeDrive do
    def start(dirs, files),
      do: Agent.start_link(fn -> %{dirs: dirs, files: files, lists: 0} end, name: __MODULE__)

    def lists, do: Agent.get(__MODULE__, & &1.lists)

    def list(_group, path) do
      Agent.get_and_update(__MODULE__, fn state ->
        {Map.fetch(state.dirs, path), %{state | lists: state.lists + 1}}
      end)
      |> case do
        {:ok, {:error, _reason} = error} -> error
        {:ok, entries} -> {:ok, entries}
        :error -> {:error, :not_found}
      end
    end

    def stream(_group, "Comma"), do: {:error, {:invalid, {:bad_request, "is-directory"}}}

    def stream(_group, path) do
      case Agent.get(__MODULE__, &Map.fetch(&1.files, path)) do
        {:ok, body} ->
          {:ok, [binary_part(body, 0, 3), binary_part(body, 3, byte_size(body) - 3)],
           byte_size(body)}

        :error ->
          {:error, :not_found}
      end
    end
  end

  setup do
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    if Process.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    # The request runs in Bandit/Plug processes of this test: the bindings are shared.
    :ok = SystemsRuntime.Test.shared()
    :ok = SystemsRuntime.Test.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    :ok = SystemsRuntime.Test.put_env(:comma_web, :api_token, @admin_token)
    :ok = SystemsRuntime.Test.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    :ok = SystemsRuntime.Test.put_env(:salix_agent, :drive_mod, FakeDrive)

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)

    :ok
  end

  test "the owner reads the hosted tree and a file's bytes" do
    {:ok, _} =
      FakeDrive.start(
        %{
          "" => [
            entry("Comma", "dir"),
            entry("notes.md", "file", 5),
            entry("gone.txt", "tombstone")
          ],
          "Comma" => [entry("Comma/Notebook.md", "file", 11)]
        },
        %{"Comma/Notebook.md" => "# Notebook\n"}
      )

    %{workspace: workspace, session: session} = fixture("drive-owner@example.com")
    group_id = workspace["default_group_id"]

    tree = get(session["token"], "/v1/comma/groups/#{group_id}/drive/tree") |> json(200)

    assert tree["truncated"] == false

    assert Enum.map(tree["entries"], &{&1["path"], &1["kind"]}) == [
             {"Comma", "dir"},
             {"notes.md", "file"},
             {"Comma/Notebook.md", "file"}
           ]

    assert %{"name" => "Notebook.md", "size" => 11, "modified_at" => 1_790_000_000} =
             Enum.find(tree["entries"], &(&1["path"] == "Comma/Notebook.md"))

    file = get(session["token"], drive_file(group_id, "Comma/Notebook.md"))
    assert file.status == 200
    assert file.resp_body == "# Notebook\n"
    assert get_resp_header(file, "cache-control") == ["private, no-store"]
    assert get_resp_header(file, "x-content-type-options") == ["nosniff"]

    assert get(session["token"], drive_file(group_id, "missing.md")) |> json(404)

    # A path the control plane refuses (a directory) is the caller's mistake.
    assert %{"error" => "invalid_drive_path"} =
             get(session["token"], drive_file(group_id, "Comma")) |> json(400)
  end

  test "a tree past its budget says it is truncated instead of listing on" do
    # 100 folders side by side: the walk stops at its listing budget.
    folders = for index <- 1..100, do: "f#{String.pad_leading("#{index}", 3, "0")}"
    dirs = Map.new(folders, &{&1, []}) |> Map.put("", Enum.map(folders, &entry(&1, "dir")))

    {:ok, _} = FakeDrive.start(dirs, %{})
    %{workspace: workspace, session: session} = fixture("drive-deep@example.com")

    tree =
      get(session["token"], "/v1/comma/groups/#{workspace["default_group_id"]}/drive/tree")
      |> json(200)

    assert tree["truncated"] == true
    assert FakeDrive.lists() == 64
  end

  test "only the owner's full session reads, and refusals stay generic" do
    {:ok, _} =
      FakeDrive.start(%{"" => [entry("a.txt", "file", 1)]}, %{"a.txt" => "abcd"})

    %{user: user, workspace: workspace, session: session} = fixture("drive-auth@example.com")
    group_id = workspace["default_group_id"]

    assert conn(:get, "/v1/comma/groups/#{group_id}/drive/tree") |> call() |> Map.get(:status) ==
             401

    %{session: other} = fixture("drive-other@example.com")
    assert get(other["token"], "/v1/comma/groups/#{group_id}/drive/tree") |> json(404)
    assert get(other["token"], drive_file(group_id, "a.txt")) |> json(404)

    restricted =
      conn(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "group_id" => group_id
      })
      |> put_req_header("authorization", "Bearer #{@admin_token}")
      |> call()
      |> json(201)

    assert get(restricted["token"], "/v1/comma/groups/#{group_id}/drive/tree") |> json(403)
    assert get(restricted["token"], drive_file(group_id, "a.txt")) |> json(403)

    for path <- ["", "/a.txt", "a/../b", "a//b", "./a"] do
      assert %{"error" => "invalid_drive_path"} =
               get(session["token"], drive_file(group_id, path)) |> json(400)
    end

    :ok = SystemsRuntime.Test.put_env(:salix_agent, :drive_mod, SalixAgent.Drive.Unconfigured)

    assert %{"error" => "drive_unavailable"} =
             get(session["token"], "/v1/comma/groups/#{group_id}/drive/tree") |> json(409)
  end

  defp entry(path, kind, size \\ 0),
    do: %{
      path: path,
      name: Path.basename(path),
      kind: kind,
      size: size,
      modified_at: 1_790_000_000
    }

  defp drive_file(group_id, path),
    do: "/v1/comma/groups/#{group_id}/drive/file?" <> URI.encode_query(%{"path" => path})

  defp fixture(email) do
    user =
      conn(:post, "/v1/comma/admin/users", %{"email" => email, "name" => "Drive"})
      |> put_req_header("authorization", "Bearer #{@admin_token}")
      |> call()
      |> json(201)

    workspace = create_ready_workspace!(user["id"])
    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    session =
      conn(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> put_req_header("authorization", "Bearer #{@admin_token}")
      |> call()
      |> json(201)

    %{user: user, workspace: workspace, session: session}
  end

  defp get(token, path),
    do: conn(:get, path) |> put_req_header("authorization", "Bearer #{token}") |> call()

  defp call(conn), do: CommaWeb.Router.call(conn, @opts)

  defp json(conn, status) do
    assert conn.status == status, conn.resp_body
    Jason.decode!(conn.resp_body)
  end
end
