defmodule SalixIM.TelegramFilesTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixIM.{TelegramFiles, ProviderAttachments}
  alias SalixIM.TestSupport.BanditServer

  defmodule API do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.path_info do
        ["botprivate-token", method] when method in ["sendPhoto", "sendDocument"] ->
          {:ok, body, conn} = read_body(conn)

          SystemsRuntime.Proc.send(
            SystemsRuntime.fetch_env!(:salix_im, :telegram_files_test_pid),
            {:sent_media, body}
          )

          {status, response} =
            if String.contains?(body, "name=\"parse_mode\"") &&
                 SystemsRuntime.get_env(:salix_im, :telegram_caption_test_failure) do
              {code, description} =
                SystemsRuntime.fetch_env!(:salix_im, :telegram_caption_test_failure)

              {code, %{"ok" => false, "error_code" => code, "description" => description}}
            else
              {200, %{"ok" => true, "result" => %{"message_id" => 9}}}
            end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(response))

        ["botprivate-token", "getFile"] ->
          {:ok, body, conn} = read_body(conn)
          id = Jason.decode!(body)["file_id"]
          path = if id == "traversal", do: "../private", else: "files/#{id}"

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"file_path" => path}}))

        ["file", "botprivate-token", "files", "redirect"] ->
          conn
          |> put_resp_header("location", "http://127.0.0.1:1/private-token")
          |> send_resp(302, "")

        ["file", "botprivate-token", "files", "large"] ->
          conn = send_chunked(conn, 200)

          Enum.reduce_while(1..321, conn, fn _, conn ->
            case chunk(conn, :binary.copy("x", 65_536)) do
              {:ok, conn} -> {:cont, conn}
              _ -> {:halt, conn}
            end
          end)

        ["file", "botprivate-token", "files", _id] ->
          send_resp(conn, 200, "actual media bytes")

        _ ->
          send_resp(conn, 404, "")
      end
    end
  end

  defmodule Workspace do
    def read_upload(_agent_id, path, _title),
      do: {:ok, %{path: path, filename: "result.png", data: "result bytes"}}

    def put_ref(agent_id, path, ref) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :telegram_files_test_pid),
        {:published, agent_id, path, ref}
      )

      {:ok, %{path: path, size: ref.size}}
    end
  end

  setup do
    prior =
      for {app, key} <- [
            {:salix_im, :telegram_api_base_url},
            {:salix_im, :agent_workspace_mod},
            {:salix_store, :s3_backend},
            {:salix_im, :telegram_files_test_pid},
            {:salix_im, :telegram_caption_test_failure}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    start_supervised!(SalixStore.S3.Fake)
    port = BanditServer.start!(fn p -> {Bandit, plug: API, port: p} end)
    SystemsRuntime.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, Workspace)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_im, :telegram_files_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.delete_env(:salix_im, :telegram_caption_test_failure)

    on_exit(fn ->
      Enum.each(prior, fn {app, key, value} ->
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end)
    end)

    :ok
  end

  test "photo variants select one original, and voice/document bytes reach VFS by reference" do
    for media <- [
          %{
            "photo" => [
              %{"file_id" => "small", "width" => 1, "height" => 1},
              %{"file_id" => "large-photo", "width" => 20, "height" => 20}
            ]
          },
          %{"voice" => %{"file_id" => "voice", "mime_type" => "audio/ogg"}},
          %{
            "document" => %{
              "file_id" => "document",
              "file_name" => "report.pdf",
              "mime_type" => "application/pdf"
            }
          }
        ] do
      [attachment] = attachments(media)
      assert {:ok, [staged], []} = ProviderAttachments.stage("agent", [attachment])
      settle_receive({:published, "agent", path, ref})
      assert path == staged["path"]
      refute inspect(staged) =~ "private-token"
      refute Map.has_key?(staged, "to_blob")
      assert {:ok, "actual media bytes"} = SalixStore.Blob.get("agent", ref)
    end
  end

  test "provider traversal and redirects cannot expose token URLs or publish bytes" do
    for id <- ["traversal", "redirect"] do
      assert {:ok, [], [failure]} =
               ProviderAttachments.stage(
                 "agent",
                 attachments(%{"document" => %{"file_id" => id}})
               )

      assert failure["stage_error"] == "download_failed"
      refute inspect(failure) =~ "private-token"
      settle_refute_receive({:published, _, _, _})
    end
  end

  test "media replies preserve the exact topic and replied-to message" do
    connect = %{
      "provider" => "telegram",
      "status" => "connected",
      "managed_by" => "comma_product",
      "managed_peer_id" => "42",
      "bot_token" => "private-token"
    }

    for api <- ["telegram.send_photo", "telegram.send_document"] do
      assert {:ok, %{"message_id" => 9}} =
               SalixIM.Provider.Telegram.call("agent", connect, api, %{
                 "chat_id" => "42",
                 "path" => "/result.png",
                 "caption" => "**结果 😀** `a_b`",
                 "message_thread_id" => 55,
                 "reply_to_message_id" => 7
               })

      settle_receive({:sent_media, body})
      assert body =~ "name=\"message_thread_id\"\r\n\r\n55"
      assert body =~ "name=\"reply_to_message_id\"\r\n\r\n7"
      assert body =~ "result bytes"
      assert body =~ "name=\"parse_mode\"\r\n\r\nHTML"
      assert body =~ "<b>结果 😀</b> <code>a_b</code>"
    end
  end

  for {name, caption} <- [
        {"oversized media captions are rejected without uploading or sending",
         String.duplicate("😀", 513)},
        {"caption quote prefixes count toward the visible limit before upload",
         "> " <> String.duplicate("a", 1024)}
      ] do
    @caption caption
    test name do
      connect = %{
        "provider" => "telegram",
        "status" => "connected",
        "bot_token" => "private-token"
      }

      for api <- ["telegram.send_photo", "telegram.send_document"] do
        assert {:error, reason} =
                 SalixIM.Provider.Telegram.call("agent", connect, api, %{
                   "chat_id" => "42",
                   "path" => "/result.png",
                   "caption" => @caption
                 })

        assert reason =~ "1024"
        settle_refute_receive({:sent_media, _}, 20)
      end
    end
  end

  defp attachments(media) do
    TelegramFiles.attachments(
      %{"connect_id" => "connect", "bot_token" => "private-token"},
      Map.merge(%{"chat" => %{"id" => 42}, "message_id" => 7}, media)
    )
  end
end
