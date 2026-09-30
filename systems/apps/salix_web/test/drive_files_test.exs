defmodule Salix.Drive.FilesTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias Salix.Drive.{Files, Handle}

  @drive %Handle{
    group_id: "grp_1",
    base_url: "http://sync.test",
    org_slug: "comma-x",
    network: "default",
    space: "comma-drive",
    token: "synch_token",
    req_options: [plug: {Req.Test, Salix.Drive.Files}]
  }

  @base "/api/orgs/comma-x/networks/default/browse"

  defp entry(name, kind, size) do
    %{
      "name" => name,
      "path" => name,
      "kind" => kind,
      "size" => size,
      "mtime_ns" => 1_756_800_000_000_000_000,
      "versions" => 1,
      "origin" => "laptop@default.comma-x.sync.test",
      "root" => "abc",
      "all" => []
    }
  end

  defp query(conn), do: URI.decode_query(conn.query_string)

  describe "classify/2" do
    test "maps the file route's plain-text refusals and the JSON ones alike" do
      assert Files.classify(409, "hosting-disabled: the network is not cloud-hosted") ==
               :hosting_disabled

      assert Files.classify(409, %{"error" => %{"code" => "browse-disabled"}}) ==
               :browse_disabled

      assert Files.classify(503, "no-cloud-attached: hosting may still be provisioning") ==
               :no_cloud_attached

      assert Files.classify(503, %{"error" => %{"code" => "no-device-attached"}}) ==
               :no_device_attached

      assert Files.classify(404, "not_found") == :not_found
      assert Files.classify(412, "precondition: If-Match did not hold") == :precondition
      assert Files.classify(413, "too-large") == :too_large
      assert Files.classify(507, "over-budget") == :over_budget
      assert Files.classify(401, %{}) == :auth
      assert Files.classify(429, "too-many-writes") == {:retryable, {:status, 429}}
      assert Files.classify(500, "internal: boom") == {:retryable, {:status, 500}}

      assert Files.classify(400, %{"error" => %{"code" => "bad_request"}}) ==
               {:invalid, {:bad_request, "bad_request"}}
    end
  end

  test "list follows the cursor and carries the bearer, space and path" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == @base <> "/ls"
      assert get_req_header(conn, "authorization") == ["Bearer synch_token"]
      params = query(conn)
      assert params["space"] == "comma-drive"
      assert params["path"] == "docs"

      case params["cursor"] do
        nil ->
          Req.Test.json(conn, %{
            "entries" => [entry("a.txt", "file", 3), entry("sub", "dir", 0)],
            "cursor" => "page2"
          })

        "page2" ->
          Req.Test.json(conn, %{"entries" => [entry("b.txt", "file", 4)], "cursor" => ""})
      end
    end)

    assert {:ok, entries} = Files.list(@drive, "docs")
    assert Enum.map(entries, & &1.name) == ["a.txt", "sub", "b.txt"]
    assert Enum.map(entries, & &1.kind) == ["file", "dir", "file"]
    assert hd(entries).size == 3
    assert hd(entries).mtime_ns == 1_756_800_000_000_000_000
  end

  test "a refused listing is classified" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      conn
      |> put_status(409)
      |> Req.Test.json(%{"error" => %{"code" => "browse-disabled", "message" => "off"}})
    end)

    assert {:error, :browse_disabled} = Files.list(@drive, "")
  end

  test "read returns the bytes and says whether they were cut short" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      assert conn.request_path == @base <> "/file"
      assert query(conn)["path"] == "notes/hello.txt"

      conn
      |> put_resp_header("content-length", "11")
      |> send_resp(200, "hello world")
    end)

    assert {:ok, "hello world", false} = Files.read(@drive, "notes/hello.txt", 1024)
    assert {:ok, "hello", true} = Files.read(@drive, "notes/hello.txt", 5)
  end

  test "a missing file reads as not_found from the file route's plain text" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      send_resp(conn, 404, "not_found: no such path")
    end)

    assert {:error, :not_found} = Files.read(@drive, "gone.txt", 1024)
    assert {:error, :not_found} = Files.stream(@drive, "gone.txt")
  end

  test "stream yields the body and its size" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      conn
      |> put_resp_header("content-length", "6")
      |> send_resp(200, "abcdef")
    end)

    assert {:ok, stream, 6} = Files.stream(@drive, "f.bin")
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "abcdef"
  end

  test "write PUTs the body with its length and conditions, and returns the version" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == @base <> "/file"
      assert query(conn) == %{"space" => "comma-drive", "path" => "out/report.md"}
      assert get_req_header(conn, "content-length") == ["5"]
      assert get_req_header(conn, "if-none-match") == ["*"]
      {:ok, "hello", conn} = read_body(conn)

      Req.Test.json(conn, %{
        "device" => "cloud-1",
        "origin" => "cloud-1@default.comma-x.sync.test",
        "space" => "comma-drive",
        "path" => "out/report.md",
        "root" => "3e0c",
        "size" => 5,
        "seq" => 42,
        "mtime_ns" => 1
      })
    end)

    assert {:ok, %{root: "3e0c", size: 5, seq: 42}} =
             Files.write(@drive, "out/report.md", "hello", 5, if_none_match: true)
  end

  test "write streams an enumerable body" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      assert get_req_header(conn, "content-length") == ["6"]
      {:ok, "abcdef", conn} = read_body(conn)
      Req.Test.json(conn, %{"root" => "r", "size" => 6, "seq" => 1})
    end)

    assert {:ok, %{root: "r", size: 6}} = Files.write(@drive, "s.bin", ["abc", "def"], 6)
  end

  test "a write the hosted replica cannot take is classified from plain text" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      send_resp(conn, 503, "no-cloud-attached: hosting may still be provisioning")
    end)

    assert {:error, :no_cloud_attached} = Files.write(@drive, "x", "y", 1)
  end

  test "delete reports what was withdrawn and what a device still publishes" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      assert conn.method == "DELETE"
      assert query(conn)["path"] == "old.txt"
      Req.Test.json(conn, %{"withdrawn" => true, "still_published" => true})
    end)

    assert {:ok, %{withdrawn: true, still_published: true}} = Files.delete(@drive, "old.txt")
  end

  test "status reads the browse and write halves" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      assert conn.request_path == @base

      # The control plane's shape: attached readers under `devices`.
      Req.Test.json(conn, %{
        "enabled" => true,
        "devices" => [
          %{"label" => "cloud-1", "origin" => "cloud-1@default.comma-x.sync.test", "spaces" => []}
        ],
        "attach_url" => "https://sync.test/agent/v1/attach",
        "writes" => %{"enabled" => true, "attached" => true, "device" => "cloud-1"}
      })
    end)

    assert {:ok, %{browse_enabled: true, attached: true, writes: true}} = Files.status(@drive)
  end

  test "status with no attached device reads as not attached" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      Req.Test.json(conn, %{
        "enabled" => true,
        "devices" => [],
        "writes" => %{"enabled" => true, "attached" => false, "device" => ""}
      })
    end)

    assert {:ok, %{browse_enabled: true, attached: false, writes: false}} = Files.status(@drive)
  end

  test "a transport failure is retryable" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, {:retryable, _}} = Files.list(@drive, "")
    assert {:error, {:retryable, _}} = Files.read(@drive, "a", 10)
  end
end
