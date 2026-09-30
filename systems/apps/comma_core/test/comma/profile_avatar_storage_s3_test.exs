defmodule Comma.ProfileAvatarStorageS3Test do
  use ExUnit.Case, async: false

  alias Comma.ProfileAvatar.Storage.S3

  defmodule S3HTTPFake do
    @behaviour ExAws.Request.HttpClient

    @impl true
    def request(method, url, body, headers, _http_opts) do
      test_pid = Application.fetch_env!(:comma_core, :profile_avatar_s3_test_pid)
      send(test_pid, {:s3_request, method, url, body, headers})

      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")

      cond do
        method == :post and Map.has_key?(query, "uploads") ->
          response(200, initiate_xml(uri.path, "upload-123"))

        method == :put and query["partNumber"] == "1" ->
          response(200, "", [{"etag", "\"part-etag\""}])

        method == :post and query["uploadId"] == "upload-123" ->
          response(200, complete_xml(uri.path))

        method == :get and Application.get_env(:comma_core, :profile_avatar_s3_missing, false) ->
          response(404, "<Error><Code>NoSuchKey</Code></Error>")

        method == :get ->
          response(200, "avatar-bytes")

        method == :delete and
            Application.get_env(:comma_core, :profile_avatar_s3_missing, false) ->
          response(404, "<Error><Code>NoSuchUpload</Code></Error>")

        method == :delete ->
          response(204, "")
      end
    end

    defp response(status, body, headers \\ []) do
      {:ok, %{status_code: status, headers: headers, body: body}}
    end

    defp initiate_xml(path, upload_id) do
      key = path |> String.split("/", parts: 3) |> List.last()

      "<InitiateMultipartUploadResult><Bucket>avatars</Bucket><Key>#{key}</Key>" <>
        "<UploadId>#{upload_id}</UploadId></InitiateMultipartUploadResult>"
    end

    defp complete_xml(path) do
      key = path |> String.split("/", parts: 3) |> List.last()

      "<CompleteMultipartUploadResult><Bucket>avatars</Bucket><Key>#{key}</Key>" <>
        "<ETag>final-etag</ETag></CompleteMultipartUploadResult>"
    end
  end

  setup do
    previous = Application.get_env(:comma_core, :profile_avatar)

    Application.put_env(:comma_core, :profile_avatar,
      adapter: S3,
      bucket: "avatars",
      endpoint: "http://minio.test:9000",
      region: "us-east-1",
      access_key_id: "minioadmin",
      secret_access_key: "minioadmin",
      http_client: S3HTTPFake
    )

    Application.put_env(:comma_core, :profile_avatar_s3_test_pid, self())

    on_exit(fn ->
      restore_env(:profile_avatar, previous)
      Application.delete_env(:comma_core, :profile_avatar_s3_test_pid)
      Application.delete_env(:comma_core, :profile_avatar_s3_missing)
    end)

    :ok
  end

  @tag :tmp_dir
  test "finishes and retrieves a durable one-part multipart upload", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "avatar.png")
    File.write!(path, "png-bytes")

    assert {:ok, session} = S3.start_put("users/user-1/avatar.png", "image/png")
    assert String.starts_with?(session, "comma-s3-multipart:")

    assert :ok = S3.finish_put(session, path, "image/png", byte_size("png-bytes"))
    assert {:ok, "avatar-bytes"} = S3.get("users/user-1/avatar.png")
    assert :ok = S3.delete("users/user-1/avatar.png")

    assert_receive {:s3_request, :post, start_url, "", _headers}
    assert start_url =~ "uploads"
    assert_receive {:s3_request, :put, part_url, "png-bytes", _headers}
    assert part_url =~ "partNumber=1"
    assert_receive {:s3_request, :post, complete_url, complete_body, _headers}
    assert complete_url =~ "uploadId=upload-123"
    assert complete_body =~ "<ETag>\"part-etag\"</ETag>"
  end

  test "cancellation is idempotent and malformed sessions fail closed" do
    assert {:ok, session} = S3.start_put("users/user-1/avatar.png", "image/png")

    Application.put_env(:comma_core, :profile_avatar_s3_missing, true)
    assert :ok = S3.cancel_put(session)
    assert {:error, :not_found} = S3.get("users/user-1/missing.png")
    assert :ok = S3.delete("users/user-1/missing.png")
    assert {:error, :invalid_upload_session} = S3.cancel_put("not-a-session")
  end

  @tag :tmp_dir
  test "refuses a file that changed after validation", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "avatar.png")
    File.write!(path, "changed")
    assert {:ok, session} = S3.start_put("users/user-1/avatar.png", "image/png")

    assert {:error, :avatar_size_changed} =
             S3.finish_put(session, path, "image/png", byte_size("original"))
  end

  defp restore_env(key, nil), do: Application.delete_env(:comma_core, key)
  defp restore_env(key, value), do: Application.put_env(:comma_core, key, value)
end
