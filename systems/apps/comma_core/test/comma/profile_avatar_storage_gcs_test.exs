defmodule Comma.ProfileAvatarStorageGCSTest do
  use ExUnit.Case, async: false

  alias Comma.ProfileAvatar.Storage.GCS

  @session_url "https://storage.googleapis.com/upload/storage/v1/b/avatars/o?uploadType=resumable&upload_id=session-1"

  setup do
    previous = SystemsRuntime.get_env(:comma_core, :profile_avatar)

    SystemsRuntime.put_env(:comma_core, :profile_avatar,
      adapter: GCS,
      bucket: "avatars",
      token: "token-1",
      request_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:comma_core, :profile_avatar, previous),
        else: SystemsRuntime.delete_env(:comma_core, :profile_avatar)
    end)

    :ok
  end

  @tag :tmp_dir
  test "uploads through a resumable session, reads and deletes the object", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "avatar.png")
    File.write!(path, "png-bytes")

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-1"]
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/upload/storage/v1/b/avatars/o"} ->
          assert conn.query_params == %{
                   "uploadType" => "resumable",
                   "ifGenerationMatch" => "0"
                 }

          assert Plug.Conn.get_req_header(conn, "x-upload-content-type") == ["image/png"]

          assert Jason.decode!(body) == %{
                   "name" => "users/user-1/a.png",
                   "contentType" => "image/png"
                 }

          conn
          |> Plug.Conn.put_resp_header("location", @session_url)
          |> Plug.Conn.send_resp(200, "")

        {"PUT", "/upload/storage/v1/b/avatars/o"} ->
          assert conn.query_params["upload_id"] == "session-1"
          assert body == "png-bytes"
          assert Plug.Conn.get_req_header(conn, "content-range") == ["bytes 0-8/9"]
          Plug.Conn.send_resp(conn, 200, "{}")

        {"GET", "/storage/v1/b/avatars/o/users%2Fuser-1%2Fa.png"} ->
          assert conn.query_params == %{"alt" => "media"}
          Plug.Conn.send_resp(conn, 200, "png-bytes")

        {"DELETE", "/storage/v1/b/avatars/o/users%2Fuser-1%2Fa.png"} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:ok, @session_url} = GCS.start_put("users/user-1/a.png", "image/png")
    assert :ok = GCS.finish_put(@session_url, path, "image/png", 9)
    assert {:ok, "png-bytes"} = GCS.get("users/user-1/a.png")
    assert :ok = GCS.delete("users/user-1/a.png")
  end

  test "reports missing objects and treats a cancelled session as gone" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" -> Plug.Conn.send_resp(conn, 404, "{}")
        "DELETE" -> Plug.Conn.send_resp(conn, 499, "")
      end
    end)

    assert {:error, :not_found} = GCS.get("users/user-1/missing.png")
    assert :ok = GCS.cancel_put(@session_url)
  end
end
