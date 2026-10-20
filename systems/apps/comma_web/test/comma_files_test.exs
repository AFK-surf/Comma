defmodule CommaWeb.CommaFilesTest do
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]

  import Plug.Conn
  import Plug.Test

  @admin_token "test-token"
  @opts CommaWeb.Router.init([])

  defmodule SalixClientFake do
    @behaviour Comma.Salix.Client

    @impl true
    def provision_workspace_scope(_workspace), do: :ok

    @impl true
    def resolve_workspace_scope(workspace) do
      group_id = workspace["default_group_id"]

      conversation_id =
        Process.get({__MODULE__, :router_conversation_id, group_id}) ||
          SalixStore.Ids.new_conversation_id()

      Process.put({__MODULE__, :router_conversation_id, group_id}, conversation_id)
      {:ok, Map.put(workspace, "router_conversation_id", conversation_id)}
    end

    @impl true
    def update_workspace_vm(_workspace, _vm), do: :ok

    @impl true
    def create_group_conversation(_workspace, attrs),
      do:
        {:ok,
         %{
           "conversation_id" => attrs["conversation_id"] || SalixStore.Ids.new_conversation_id(),
           "kind" => "user_chat",
           "title" => "聊天",
           "status" => "active",
           "message_count" => 0
         }}

    @impl true
    def ensure_group_router_conversation(workspace) do
      get_group_conversation(workspace, workspace["router_conversation_id"])
    end

    @impl true
    def get_group_conversation(_workspace, conversation_id) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "kind" => "user_chat",
         "title" => "聊天",
         "status" => "active",
         "message_count" => 0
       }}
    end

    @impl true
    def get_group_conversation_with_messages(_workspace, conversation_id, _opts) do
      {:ok,
       %{
         "conversation" => %{
           "conversation_id" => conversation_id,
           "kind" => "user_chat",
           "title" => "聊天",
           "status" => "active",
           "message_count" => 0
         },
         "messages" => []
       }}
    end

    @impl true
    def get_group_conversation_messages(_workspace, _conversation_id), do: {:ok, []}

    @impl true
    def ensure_group_conversation_user_participant(_workspace, conversation_id, user_id) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "actor_type" => "user",
         "user_id" => user_id,
         "state" => "active"
       }}
    end

    @impl true
    def reconcile_group_conversation_router_participant(_workspace, conversation_id) do
      {:ok, %{"conversation_id" => conversation_id}}
    end

    @impl true
    def list_group_conversation_participants(workspace, conversation_id, _opts) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participants" => [
           %{
             "actor_type" => "agent",
             "agent_id" => workspace["router_agent_id"],
             "state" => "active"
           },
           %{
             "actor_type" => "user",
             "user_id" => workspace["owner_user_id"],
             "state" => "active"
           }
         ],
         "has_more" => false
       }}
    end

    @impl true
    def append_group_conversation_message(_workspace, _conversation_id, _attrs),
      do: {:error, :not_implemented}

    @impl true
    def conversation_activity_context(_workspace, _conversation_id), do: {:error, :not_found}

    @impl true
    def list_agent_skills(_workspace), do: {:ok, %{"skills" => []}}

    @impl true
    def write_agent_file(workspace, path, body) do
      SystemsRuntime.Proc.send(test_pid!(), {:write_agent_file, workspace, path, body})
      Process.get(:write_agent_file_result, {:ok, %{"path" => path}})
    end

    @impl true
    def read_agent_file(workspace, path, max_bytes) do
      SystemsRuntime.Proc.send(test_pid!(), {:read_agent_file, workspace, path, max_bytes})

      result =
        :read_agent_file_results
        |> Process.get(%{})
        |> Map.get({workspace["id"], path}, {:error, :not_found})

      case result do
        {:ok, body} when is_binary(body) and byte_size(body) > max_bytes ->
          {:error, :too_large}

        other ->
          other
      end
    end

    defp test_pid!, do: SystemsRuntime.fetch_env!(:comma_core, :comma_files_test_pid)
  end

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_salix_client = SystemsRuntime.get_env(:comma_core, :salix_client)
    prev_api_token = SystemsRuntime.get_env(:comma_web, :api_token)
    prev_test_pid = SystemsRuntime.get_env(:comma_core, :comma_files_test_pid)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:comma_web, :api_token, @admin_token)
    SystemsRuntime.put_env(:comma_core, :salix_client, SalixClientFake)
    SystemsRuntime.put_env(:comma_core, :comma_files_test_pid, SystemsRuntime.Proc.self())

    ensure_fake_s3!()

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, prev_backend)
      restore_env(:comma_web, :api_token, prev_api_token)
      restore_env(:comma_core, :salix_client, prev_salix_client)
      restore_env(:comma_core, :comma_files_test_pid, prev_test_pid)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    :ok
  end

  test "uploads a file with a real multipart request body" do
    %{workspace: workspace, session: session} = create_fixture("files-happy@example.com")
    source = "hello from multipart"

    conn =
      upload_conn(
        session["token"],
        workspace["id"],
        filename: "a.txt",
        body: source
      )
      |> call()

    body = expect_json(conn, 201)

    assert %{
             "name" => "a.txt",
             "path" => path
           } = body

    assert body["size"] == byte_size(source)
    assert path =~ ~r|^/uploads/[A-Za-z0-9_-]{22}-a\.txt$|
    refute conn.resp_body =~ workspace["router_agent_id"]
    refute conn.resp_body =~ "im-comma-"

    workspace_id = workspace["id"]

    settle_receive(
      {:write_agent_file, %{"id" => ^workspace_id, "status" => "active"}, ^path, ^source}
    )
  end

  test "serves an authenticated uploaded image from the authorized Router VFS" do
    %{workspace: workspace, session: session} =
      create_fixture("files-image-read@example.com")

    source = png_image(320, 180)

    uploaded =
      upload_conn(session["token"], workspace["id"], filename: "preview.png", body: source)
      |> call()
      |> expect_json(201)

    put_read_agent_file_result(workspace, uploaded["path"], {:ok, source})

    conn =
      session["token"]
      |> image_conn(workspace["id"], uploaded["path"])
      |> call()

    assert conn.status == 200
    assert conn.resp_body == source
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    workspace_id = workspace["id"]

    settle_receive(
      {:read_agent_file, %{"id" => ^workspace_id, "status" => "active"}, uploaded_path,
       10_000_001}
    )

    assert uploaded_path == uploaded["path"]
    refute conn.resp_body =~ workspace["router_agent_id"]
  end

  test "fails closed for missing, non-image, oversized, and invalid upload paths" do
    %{workspace: workspace, session: session} =
      create_fixture("files-image-invalid@example.com")

    token = String.duplicate("B", 22)

    invalid_paths = [
      nil,
      "/uploads/#{token}-notes.txt",
      "/uploads/#{token}-vector.svg",
      "/uploads/short-image.png",
      "/uploads/#{token}-nested/image.png",
      "/uploads/#{token}-../../secret.png",
      "/other/#{token}-image.png",
      "/uploads/#{token}-#{String.duplicate("a", 4_100)}.png"
    ]

    for path <- invalid_paths do
      conn =
        session["token"]
        |> image_conn(workspace["id"], path)
        |> call()

      assert expect_json(conn, 404) == %{"error" => "not_found"}
    end

    refute_received {:read_agent_file, _, _, _}

    missing_path = "/uploads/#{token}-missing.png"

    missing =
      session["token"]
      |> image_conn(workspace["id"], missing_path)
      |> call()

    assert expect_json(missing, 404) == %{"error" => "not_found"}
    settle_receive({:read_agent_file, _, ^missing_path, 10_000_001})
    mismatched_path = "/uploads/#{token}-mismatched.png"
    put_read_agent_file_result(workspace, mismatched_path, {:ok, gif_image(1, 1)})

    mismatched =
      session["token"]
      |> image_conn(workspace["id"], mismatched_path)
      |> call()

    assert expect_json(mismatched, 404) == %{"error" => "not_found"}
    settle_receive({:read_agent_file, _, ^mismatched_path, 10_000_001})

    for {extension, body} <- [
          {"png", png_image(4_097, 1)},
          {"jpg", jpeg_image(1, 4_097, 0xC0)},
          {"gif", gif_image(4_097, 1)},
          {"webp", webp_vp8x_image(1, 4_097)}
        ] do
      path = "/uploads/#{token}-huge.#{extension}"
      put_read_agent_file_result(workspace, path, {:ok, body})

      huge =
        session["token"]
        |> image_conn(workspace["id"], path)
        |> call()

      assert expect_json(huge, 404) == %{"error" => "not_found"}
      settle_receive({:read_agent_file, _, ^path, 10_000_001})
    end

    oversized_path = "/uploads/#{token}-oversized.webp"

    put_read_agent_file_result(
      workspace,
      oversized_path,
      {:ok, String.duplicate("x", Comma.GroupFiles.max_upload_bytes() + 1)}
    )

    oversized =
      session["token"]
      |> image_conn(workspace["id"], oversized_path)
      |> call()

    assert expect_json(oversized, 404) == %{"error" => "not_found"}
  end

  test "requires upload and image-read authentication and rejects restricted sessions" do
    %{user: user, workspace: workspace, session: session, conversation: conversation} =
      create_fixture("files-auth@example.com")

    missing =
      :post
      |> json_conn("/v1/comma/groups/#{workspace["default_group_id"]}/files", %{})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(400)

    assert missing["error"] == "file_required"

    group_restricted =
      admin_json(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "group_id" => workspace["default_group_id"]
      })
      |> expect_json(201)

    conversation_restricted =
      admin_json(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "group_id" => workspace["default_group_id"],
        "conversation_id" => conversation["id"]
      })
      |> expect_json(201)

    for grant <- [group_restricted, conversation_restricted] do
      upload =
        upload_conn(grant["token"], workspace["id"], filename: "a.txt", body: "nope")
        |> call()

      assert upload.status == 403

      image =
        grant["token"]
        |> image_conn(
          workspace["id"],
          "/uploads/#{String.duplicate("D", 22)}-private.png"
        )
        |> call()

      assert image.status == 403
    end

    no_token =
      :post
      |> multipart_conn("/v1/comma/groups/#{workspace["default_group_id"]}/files",
        filename: "a.txt",
        body: "x"
      )
      |> call()

    assert no_token.status == 401

    no_image_token =
      nil
      |> image_conn(
        workspace["id"],
        "/uploads/#{String.duplicate("E", 22)}-private.png"
      )
      |> call()

    assert no_image_token.status == 401

    %{session: other_session} = create_fixture("files-other-owner@example.com")

    other_owner =
      other_session["token"]
      |> image_conn(
        workspace["id"],
        "/uploads/#{String.duplicate("F", 22)}-private.png"
      )
      |> call()

    assert other_owner.status == 404
    refute_received {:read_agent_file, _, _, _}
  end

  defp create_fixture(email) do
    user =
      admin_json(:post, "/v1/comma/admin/users", %{"email" => email, "name" => "Files"})
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"])

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    session =
      admin_json(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> expect_json(201)

    conversation =
      :post
      |> json_conn("/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat", %{})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    %{user: user, workspace: workspace, session: session, conversation: conversation}
  end

  defp admin_json(method, path, body) do
    method
    |> json_conn(path, body)
    |> admin_auth()
    |> call()
  end

  defp upload_conn(token, comma_workspace_id, opts) do
    group_id = group_id_for_comma_workspace!(comma_workspace_id)

    :post
    |> multipart_conn("/v1/comma/groups/#{group_id}/files", opts)
    |> user_auth(token)
  end

  defp image_conn(token, comma_workspace_id, path) do
    group_id = group_id_for_comma_workspace!(comma_workspace_id)
    query = if is_binary(path), do: "?path=#{URI.encode_www_form(path)}", else: ""
    conn = conn(:get, "/v1/comma/groups/#{group_id}/files#{query}")
    if is_binary(token), do: user_auth(conn, token), else: conn
  end

  defp group_id_for_comma_workspace!(workspace_id) do
    Comma.Repo.get!(Comma.Data.Workspace, workspace_id).salix_group_id
  end

  defp put_read_agent_file_result(workspace, path, result) do
    results = Process.get(:read_agent_file_results, %{})
    Process.put(:read_agent_file_results, Map.put(results, {workspace["id"], path}, result))
  end

  defp png_image(width, height) do
    <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32, 8, 6, 0, 0, 0,
      0::32>>
  end

  defp jpeg_image(width, height, sof_marker) do
    <<0xFF, 0xD8, 0xFF, 0xE0, 2::16, 0xFF, sof_marker, 7::16, 8, height::16, width::16>>
  end

  defp gif_image(width, height) do
    <<"GIF89a", width::little-16, height::little-16, 0, 0, 0>>
  end

  defp webp_vp8x_image(width, height) do
    <<"RIFF", 22::little-32, "WEBP", "VP8X", 10::little-32, 0::32, width - 1::little-24,
      height - 1::little-24>>
  end

  defp multipart_conn(method, path, opts) do
    boundary = "----comma-upload-boundary"
    filename = Keyword.fetch!(opts, :filename)
    body = Keyword.fetch!(opts, :body)

    multipart =
      IO.iodata_to_binary([
        "--",
        boundary,
        "\r\n",
        "content-disposition: form-data; name=\"file\"; filename=\"",
        filename,
        "\"\r\n",
        "content-type: text/plain\r\n\r\n",
        body,
        "\r\n--",
        boundary,
        "--\r\n"
      ])

    conn(method, path, multipart)
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
  end

  defp json_conn(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp call(conn), do: CommaWeb.Router.call(conn, @opts)
  defp admin_auth(conn), do: put_req_header(conn, "authorization", "Bearer #{@admin_token}")
  defp user_auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp expect_json(conn, status) do
    assert conn.status == status, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  defp ensure_fake_s3! do
    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
