defmodule Salix.Bindings.AgentDriveTest do
  @moduledoc """
  The Drive port binding: a group resolves to its binding's handle, and each
  operation reaches the control-plane file API with it.
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Salix.Bindings.AgentDrive
  alias Salix.Control.{DriveBindings, DriveSettings}

  setup do
    SalixStore.Repo.query!("TRUNCATE drive_settings, drive_bindings")
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Drive"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Drive group"}, tenant["tenant_id"])
    group_id = group["group_id"]

    {:ok, _} = DriveSettings.put_default(%{"base_url" => "http://127.0.0.1:1"})

    {:ok, _} =
      DriveBindings.put(group_id, %{"org_slug" => "comma-abc", "api_key" => "synch_agent-token"})

    previous = Application.get_env(:salix_web, :drive_req_options)
    Application.put_env(:salix_web, :drive_req_options, plug: {Req.Test, Salix.Drive.Files})

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:salix_web, :drive_req_options)
        value -> Application.put_env(:salix_web, :drive_req_options, value)
      end

      DriveBindings.delete(group_id)
      DriveSettings.delete_default()
    end)

    {:ok, group_id: group_id}
  end

  defp entry(name, kind, size) do
    %{
      "name" => name,
      "path" => "docs/" <> name,
      "kind" => kind,
      "size" => size,
      "mtime_ns" => 1_756_800_000_000_000_000,
      "versions" => 1,
      "origin" => "laptop@default.comma-abc.sync.test",
      "root" => "r",
      "all" => []
    }
  end

  test "operations reach the group's org with its key", %{group_id: group_id} do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer synch_agent-token"]
      assert String.starts_with?(conn.request_path, "/api/orgs/comma-abc/networks/default/browse")
      params = URI.decode_query(conn.query_string)
      assert params["space"] == "comma-drive"

      case {conn.method, conn.request_path} do
        {"GET", "/api/orgs/comma-abc/networks/default/browse/ls"} ->
          assert params["path"] == "docs"

          Req.Test.json(conn, %{
            "entries" => [entry("a.md", "file", 2), entry("old.md", "tombstone", 0)],
            "cursor" => ""
          })

        {"GET", "/api/orgs/comma-abc/networks/default/browse/file"} ->
          send_resp(conn, 200, "hi")

        {"PUT", "/api/orgs/comma-abc/networks/default/browse/file"} ->
          Req.Test.json(conn, %{"root" => "r2", "size" => 3, "seq" => 7})

        {"DELETE", "/api/orgs/comma-abc/networks/default/browse/file"} ->
          Req.Test.json(conn, %{"withdrawn" => true, "still_published" => false})
      end
    end)

    assert {:ok, [%{path: "docs/a.md", name: "a.md", kind: "file", size: 2, modified_at: at}, _]} =
             AgentDrive.list(group_id, "docs")

    assert at == 1_756_800_000
    assert {:ok, %{kind: "file", size: 2}} = AgentDrive.stat(group_id, "docs/a.md")
    assert {:error, :not_found} = AgentDrive.stat(group_id, "docs/old.md")
    assert {:error, :not_found} = AgentDrive.stat(group_id, "docs/none.md")
    assert {:ok, "hi", false} = AgentDrive.read(group_id, "docs/a.md", 100)
    assert {:ok, %{size: 3, root: "r2"}} = AgentDrive.write(group_id, "docs/b.md", "abc", 3)
    assert {:ok, %{withdrawn: true}} = AgentDrive.delete(group_id, "docs/a.md")
  end

  test "status folds the control plane's halves into one answer", %{group_id: group_id} do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      Req.Test.json(conn, %{
        "enabled" => true,
        "devices" => [%{"label" => "cloud-1", "origin" => "cloud-1@default.comma-abc.sync.test"}],
        "writes" => %{"enabled" => true, "attached" => false, "device" => ""}
      })
    end)

    assert {:ok, %{available: true, writable: false, detail: detail}} =
             AgentDrive.status(group_id)

    assert detail =~ "not taking writes"
  end

  test "a group without a binding is unavailable, never an exception" do
    assert {:error, :not_configured} = AgentDrive.read("grp-none", "a", 10)
    assert {:ok, %{available: false, detail: detail}} = AgentDrive.status("grp-none")
    assert detail =~ "no Drive binding"
  end
end
