defmodule Salix.Drive.FilesTest do
  use SystemsClock.Case, async: false
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

  defp browse_status(conn, devices) do
    Req.Test.json(conn, %{
      "enabled" => true,
      "devices" => devices,
      "writes" => %{"enabled" => true, "attached" => true, "device" => "cloud-1"}
    })
  end

  defp device(name, spaces) do
    %{"device" => name, "origin" => name <> "@default.comma-x.sync.test", "spaces" => spaces}
  end

  describe "which view a read gets" do
    @cloud_origin "cloud-1@default.comma-x.sync.test"
    @older 1_000
    @newer 2_000

    defp two_holders(conn) do
      browse_status(conn, [
        device("win-1", ["comma-drive"]),
        device("cloud-1", ["comma-drive"])
      ])
    end

    defp versions_at(conn, nil), do: Req.Test.json(conn, %{"versions" => []})

    defp versions_at(conn, mtime_ns) do
      Req.Test.json(conn, %{
        "versions" => [%{"root" => "r", "kind" => "file", "mtime_ns" => mtime_ns}]
      })
    end

    # A device at `local` and `cloud-1` at `hosted`, each serving its own bytes.
    # nil is a view without the file.
    defp two_views(local, hosted) do
      Req.Test.stub(Salix.Drive.Files, fn conn ->
        hosted? = query(conn)["origin"] == @cloud_origin
        mtime_ns = if hosted?, do: hosted, else: local

        case conn.request_path do
          @base ->
            two_holders(conn)

          @base <> "/stat" ->
            versions_at(conn, mtime_ns)

          @base <> "/file" when is_nil(mtime_ns) ->
            send_resp(conn, 404, "not_found: no such path")

          @base <> "/file" ->
            send_resp(conn, 200, if(hosted?, do: "from cloud", else: "from device"))

          @base <> "/ls" ->
            entries =
              if mtime_ns,
                do: [Map.put(entry("a.md", "file", 1), "mtime_ns", mtime_ns) |> tag(hosted?)],
                else: []

            Req.Test.json(conn, %{"entries" => entries, "cursor" => ""})
        end
      end)
    end

    defp tag(entry, true), do: Map.put(entry, "origin", @cloud_origin)
    defp tag(entry, false), do: entry

    test "a write the device has not synced is read from the hosted replica" do
      two_views(nil, @newer)

      assert {:ok, "from cloud", false} = Files.read(@drive, "a.md", 1024)
      assert {:ok, stream, _size} = Files.stream(@drive, "a.md")
      assert IO.iodata_to_binary(Enum.to_list(stream)) == "from cloud"
      assert {:ok, [%{origin: @cloud_origin}]} = Files.list(@drive, "")
    end

    test "an overwrite the device has not synced is read from the hosted replica" do
      two_views(@older, @newer)

      assert {:ok, "from cloud", false} = Files.read(@drive, "a.md", 1024)
      assert {:ok, [%{mtime_ns: @newer, origin: @cloud_origin}]} = Files.list(@drive, "")
    end

    test "a file on the device is read there when the hosted replica has none" do
      two_views(@newer, nil)

      assert {:ok, "from device", false} = Files.read(@drive, "a.md", 1024)
      assert {:ok, [%{mtime_ns: @newer}]} = Files.list(@drive, "")
    end

    test "a version on the device at least as new as the hosted one is read there" do
      for hosted <- [@older, @newer] do
        two_views(@newer, hosted)

        assert {:ok, "from device", false} = Files.read(@drive, "a.md", 1024)
      end
    end

    test "a file neither has is not found" do
      two_views(nil, nil)

      assert {:error, :not_found} = Files.read(@drive, "a.md", 1024)
      assert {:ok, []} = Files.list(@drive, "")
    end

    test "with one holder the control plane's pick is the only request" do
      Req.Test.stub(Salix.Drive.Files, fn conn ->
        assert query(conn)["origin"] == nil

        case conn.request_path do
          @base -> browse_status(conn, [device("cloud-1", ["comma-drive"]), device("win-1", [])])
          @base <> "/file" -> send_resp(conn, 200, "only")
        end
      end)

      assert {:ok, "only", false} = Files.read(@drive, "a.md", 1024)
    end

    test "a hosted replica that fails leaves the device's answer" do
      for status <- [500, 502, 503] do
        Req.Test.stub(Salix.Drive.Files, fn conn ->
          case {conn.request_path, query(conn)["origin"]} do
            {@base, _} ->
              two_holders(conn)

            {_path, @cloud_origin} ->
              send_resp(conn, status, "internal: boom")

            {@base <> "/stat", nil} ->
              versions_at(conn, @older)

            {@base <> "/file", nil} ->
              send_resp(conn, 200, "from device")

            {@base <> "/ls", nil} ->
              Req.Test.json(conn, %{"entries" => [entry("a.md", "file", 1)], "cursor" => ""})
          end
        end)

        assert {:ok, "from device", false} = Files.read(@drive, "a.md", 1024)
        assert {:ok, [%{name: "a.md"}]} = Files.list(@drive, "")
      end
    end

    test "a device that fails leaves the hosted replica's answer" do
      for status <- [500, 502, 503] do
        Req.Test.stub(Salix.Drive.Files, fn conn ->
          case {conn.request_path, query(conn)["origin"]} do
            {@base, _} ->
              two_holders(conn)

            {_path, nil} ->
              send_resp(conn, status, "internal: boom")

            {@base <> "/stat", @cloud_origin} ->
              versions_at(conn, @older)

            {@base <> "/file", @cloud_origin} ->
              send_resp(conn, 200, "from cloud")

            {@base <> "/ls", @cloud_origin} ->
              Req.Test.json(conn, %{"entries" => [entry("a.md", "file", 1)], "cursor" => ""})
          end
        end)

        assert {:ok, "from cloud", false} = Files.read(@drive, "a.md", 1024)
        assert {:ok, [%{name: "a.md"}]} = Files.list(@drive, "")
      end
    end

    test "a refusal of the whole network is not answered from the other view" do
      Req.Test.stub(Salix.Drive.Files, fn conn ->
        case {conn.request_path, query(conn)["origin"]} do
          {@base, _} ->
            two_holders(conn)

          {@base <> "/ls", @cloud_origin} ->
            Req.Test.json(conn, %{"entries" => [], "cursor" => ""})

          {@base <> "/ls", nil} ->
            send_resp(conn, 401, "unauthorized")
        end
      end)

      assert {:error, :auth} = Files.list(@drive, "")
    end
  end

  test "list follows the cursor and carries the bearer, space and path" do
    Req.Test.stub(Salix.Drive.Files, fn
      %{request_path: @base} = conn ->
        browse_status(conn, [])

      conn ->
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
    Req.Test.stub(Salix.Drive.Files, fn
      %{request_path: @base} = conn ->
        browse_status(conn, [])

      conn ->
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

  test "a space without a holder is unavailable, while other 503s remain retryable" do
    Req.Test.stub(Salix.Drive.Files, fn conn ->
      send_resp(conn, 503, "no attached daemon holds comma-drive\n")
    end)

    assert {:error, :no_device_attached} = Files.read(@drive, "Comma/Notebook.md", 1024)
    assert {:error, :no_device_attached} = Files.stream(@drive, "Comma/Notebook.md")

    Req.Test.stub(Salix.Drive.Files, fn conn ->
      send_resp(conn, 503, "the daemon did not answer in time\n")
    end)

    assert {:error, {:retryable, {:status, 503}}} =
             Files.read(@drive, "Comma/Notebook.md", 1024)
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
          %{
            "device" => "cloud-1",
            "origin" => "cloud-1@default.comma-x.sync.test",
            "spaces" => ["comma-drive"]
          }
        ],
        "attach_url" => "https://sync.test/agent/v1/attach",
        "writes" => %{"enabled" => true, "attached" => true, "device" => "cloud-1"}
      })
    end)

    assert {:ok, %{browse_enabled: true, attached: true, writes: true}} = Files.status(@drive)
  end

  test "an attached daemon without the bound space does not make the Drive readable" do
    for spaces <- [[], ["other-space"]] do
      Req.Test.stub(Salix.Drive.Files, fn conn ->
        Req.Test.json(conn, %{
          "enabled" => true,
          "devices" => [%{"device" => "cloud-1", "spaces" => spaces}],
          "writes" => %{"enabled" => true, "attached" => true, "device" => "cloud-1"}
        })
      end)

      assert {:ok, %{browse_enabled: true, attached: false, writes: true}} = Files.status(@drive)
    end
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
