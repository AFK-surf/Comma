defmodule SalixIM.WeChatFilesTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixIM.{WeChatFiles, ProviderAttachments}

  defmodule CDN do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      conn = fetch_query_params(conn)
      id = conn.query_params["encrypted_query_param"]

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :wechat_files_test_pid),
        {:download, id, get_req_header(conn, "authorization")}
      )

      case id do
        "transient" ->
          if Agent.get_and_update(
               SystemsRuntime.fetch_env!(:salix_im, :wechat_files_test_attempts),
               fn n -> {n, n + 1} end
             ) == 0,
             do: send_resp(conn, 503, "temporary"),
             else:
               send_resp(conn, 200, SystemsRuntime.fetch_env!(:salix_im, :wechat_files_test_body))

        "unavailable" ->
          send_resp(conn, 503, "temporary")

        "expired" ->
          send_resp(conn, 404, "expired")

        "redirect" ->
          conn |> put_resp_header("location", "http://127.0.0.1:1/private") |> send_resp(302, "")

        "large" ->
          conn = send_chunked(conn, 200)

          Enum.reduce_while(1..161, conn, fn _, conn ->
            case chunk(conn, :binary.copy("x", 65_536)) do
              {:ok, conn} -> {:cont, conn}
              _ -> {:halt, conn}
            end
          end)

        _ ->
          send_resp(conn, 200, SystemsRuntime.fetch_env!(:salix_im, :wechat_files_test_body))
      end
    end
  end

  defmodule Workspace do
    def put_ref(agent, path, ref) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :wechat_files_test_pid),
        {:published, agent, path, ref}
      )

      {:ok, %{path: path, size: ref.size}}
    end
  end

  setup do
    keys = [
      {:salix_im, :wechat_cdn_base_url},
      {:salix_im, :agent_workspace_mod},
      {:salix_store, :s3_backend},
      {:salix_im, :wechat_files_test_pid},
      {:salix_im, :wechat_files_test_body},
      {:salix_im, :wechat_files_test_attempts}
    ]

    previous = for {app, key} <- keys, do: {app, key, SystemsRuntime.get_env(app, key)}

    on_exit(fn ->
      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    port = SalixIM.TestSupport.BanditServer.start!(fn p -> {Bandit, plug: CDN, port: p} end)
    SystemsRuntime.put_env(:salix_im, :wechat_cdn_base_url, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, Workspace)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_im, :wechat_files_test_pid, SystemsRuntime.Proc.self())
    attempts = start_supervised!({Agent, fn -> 0 end})
    SystemsRuntime.put_env(:salix_im, :wechat_files_test_attempts, attempts)
    :ok
  end

  test "encrypted image and document bytes reach VFS without CDN credentials" do
    body = <<0x89, "PNG", 13, 10, 26, 10, "real image bytes">>
    key = "0123456789abcdef"
    SystemsRuntime.put_env(:salix_im, :wechat_files_test_body, encrypt(body, key))

    for {type, encoded} <- [{2, Base.encode64(key)}, {4, Base.encode64(Base.encode16(key))}] do
      item = item(type, %{"encrypt_query_param" => "private-query", "aes_key" => encoded})
      assert {:ok, [staged], []} = stage([item])
      settle_receive({:download, "private-query", []})
      settle_receive({:published, "agent", path, ref})
      assert staged["path"] == path
      assert {:ok, ^body} = SalixStore.Blob.get("agent", ref)
      refute inspect(staged) =~ "private-query"
      refute inspect(staged) =~ encoded
      if type == 2, do: assert(staged["mime"] == "image/png")
    end
  end

  test "malformed keys, padding, destinations and redirects fail without publishing" do
    SystemsRuntime.put_env(:salix_im, :wechat_files_test_body, :binary.copy(<<0>>, 16))

    for media <- [
          %{"encrypt_query_param" => "never", "aes_key" => "bad"},
          %{"encrypt_query_param" => "padding", "aes_key" => Base.encode64("0123456789abcdef")},
          %{
            "full_url" => "http://127.0.0.1:1/private",
            "aes_key" => Base.encode64("0123456789abcdef")
          },
          %{"encrypt_query_param" => "redirect", "aes_key" => Base.encode64("0123456789abcdef")}
        ] do
      assert {:ok, [], [failure]} = stage([item(4, media)])
      assert failure["stage_error"] == "download_failed"
      refute inspect(failure) =~ "127.0.0.1"
      settle_refute_receive({:published, _, _, _}, 10)
    end

    settle_refute_receive({:download, "never", _}, 10)
  end

  test "ID-only quotes recover exact observed content and media within the same connect and peer" do
    connect = %{"connect_id" => "connect", "wechat_id" => "alice"}
    SystemsRuntime.put_env(:salix_im, :wechat_files_test_body, "image bytes")
    target = "18446744073709551614"

    source = %{
      "message_id" => target,
      "client_id" => "different-client-id",
      "item_list" => [item(2, %{"encrypt_query_param" => "private-query"})]
    }

    assert {:ok, _} = SalixIM.WeChatMessages.remember(connect, source)

    quote = %{
      "message_id" => "followup",
      "item_list" => [
        %{
          "type" => 1,
          "text_item" => %{"text" => "what is this?"},
          "ref_msg" => %{"svr_id" => target}
        }
      ]
    }

    resolved = SalixIM.WeChatMessages.prepare(connect, quote)

    assert {:ok, [_], []} =
             ProviderAttachments.stage("agent", WeChatFiles.attachments(connect, resolved))

    settle_receive({:download, "private-query", []})

    for foreign <- [%{connect | "connect_id" => "other"}, %{connect | "wechat_id" => "mallory"}] do
      missing = SalixIM.WeChatMessages.prepare(foreign, quote)
      assert WeChatFiles.attachments(foreign, missing) == []
      assert SalixIM.WeChatMessages.text_body(missing) =~ "Quoted content unavailable"
    end

    settle_refute_receive({:download, _, _}, 10)
  end

  test "a voice message asks for our transcription of its audio, WeChat's text only a hint" do
    voice = fn fields -> %{"item_list" => [%{"type" => 3, "voice_item" => fields}]} end
    media = %{"encrypt_query_param" => "voice"}

    assert SalixIM.WeChatMessages.text_body(voice.(%{"media" => media, "text" => "今天天气"})) ==
             "[WeChat voice message: transcribe the attached audio with audio.transcribe. " <>
               "WeChat's own recognition, often wrong for languages other than Chinese: 今天天气]"

    assert SalixIM.WeChatMessages.text_body(voice.(%{"media" => media})) ==
             "[WeChat voice message: transcribe the attached audio with audio.transcribe]"

    assert SalixIM.WeChatMessages.text_body(voice.(%{"text" => "今天天气"})) =~
             ~r/as recognized by WeChat.*\n今天天气$/

    assert [%{"file_name" => "voice.silk"}] =
             WeChatFiles.attachments(
               %{"connect_id" => "connect"},
               voice.(%{"media" => media, "text" => "今天天气", "encode_type" => 6})
               |> Map.put("message_id", "message")
             )
  end

  defp item(type, media) do
    field = if type == 2, do: "image_item", else: "file_item"
    %{"type" => type, field => %{"media" => media, "file_name" => "report.pdf"}}
  end

  defp stage(items) do
    ProviderAttachments.stage(
      "agent",
      WeChatFiles.attachments(%{"connect_id" => "connect"}, %{
        "message_id" => "message",
        "item_list" => items
      })
    )
  end

  defp encrypt(body, key) do
    pad = 16 - rem(byte_size(body), 16)
    :crypto.crypto_one_time(:aes_128_ecb, key, body <> :binary.copy(<<pad>>, pad), true)
  end
end
