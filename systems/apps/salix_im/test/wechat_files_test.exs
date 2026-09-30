defmodule SalixIM.WeChatFilesTest do
  use ExUnit.Case, async: false
  alias SalixIM.{WeChatFiles, ProviderAttachments}

  defmodule CDN do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      conn = fetch_query_params(conn)
      id = conn.query_params["encrypted_query_param"]

      send(
        Application.fetch_env!(:salix_im, :wechat_files_test_pid),
        {:download, id, get_req_header(conn, "authorization")}
      )

      case id do
        "transient" ->
          if Agent.get_and_update(
               Application.fetch_env!(:salix_im, :wechat_files_test_attempts),
               fn n -> {n, n + 1} end
             ) == 0,
             do: send_resp(conn, 503, "temporary"),
             else:
               send_resp(conn, 200, Application.fetch_env!(:salix_im, :wechat_files_test_body))

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
          send_resp(conn, 200, Application.fetch_env!(:salix_im, :wechat_files_test_body))
      end
    end
  end

  defmodule Workspace do
    def put_ref(agent, path, ref) do
      send(
        Application.fetch_env!(:salix_im, :wechat_files_test_pid),
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

    previous = for {app, key} <- keys, do: {app, key, Application.get_env(app, key)}

    on_exit(fn ->
      for {app, key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    if Process.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    port = SalixIM.TestSupport.BanditServer.start!(fn p -> {Bandit, plug: CDN, port: p} end)
    Application.put_env(:salix_im, :wechat_cdn_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_im, :agent_workspace_mod, Workspace)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_im, :wechat_files_test_pid, self())
    attempts = start_supervised!({Agent, fn -> 0 end})
    Application.put_env(:salix_im, :wechat_files_test_attempts, attempts)
    :ok
  end

  test "temporary CDN failure recovers before publication and persistent failures stop after one retry" do
    body = <<255, 216, 255, "image">>
    key = "0123456789abcdef"
    Application.put_env(:salix_im, :wechat_files_test_body, encrypt(body, key))
    media = fn id -> item(2, %{"encrypt_query_param" => id, "aes_key" => Base.encode64(key)}) end

    assert {:ok, [_], []} = stage([media.("transient")])
    assert_receive {:download, "transient", []}
    assert_receive {:download, "transient", []}
    assert_receive {:published, "agent", _, ref}
    assert {:ok, ^body} = SalixStore.Blob.get("agent", ref)

    assert {:ok, [], [%{"stage_error" => "download_failed"}]} = stage([media.("unavailable")])
    assert_receive {:download, "unavailable", []}
    assert_receive {:download, "unavailable", []}
    refute_receive {:download, "unavailable", _}, 10

    assert {:ok, [], [%{"stage_error" => "resource_missing"}]} = stage([media.("expired")])
    assert_receive {:download, "expired", []}
    refute_receive {:download, "expired", _}, 10
    refute_receive {:published, _, _, _}, 10
  end

  test "encrypted image and document bytes reach VFS without CDN credentials" do
    body = <<0x89, "PNG", 13, 10, 26, 10, "real image bytes">>
    key = "0123456789abcdef"
    Application.put_env(:salix_im, :wechat_files_test_body, encrypt(body, key))

    for {type, encoded} <- [{2, Base.encode64(key)}, {4, Base.encode64(Base.encode16(key))}] do
      item = item(type, %{"encrypt_query_param" => "private-query", "aes_key" => encoded})
      assert {:ok, [staged], []} = stage([item])
      assert_receive {:download, "private-query", []}
      assert_receive {:published, "agent", path, ref}
      assert staged["path"] == path
      assert {:ok, ^body} = SalixStore.Blob.get("agent", ref)
      refute inspect(staged) =~ "private-query"
      refute inspect(staged) =~ encoded
      if type == 2, do: assert(staged["mime"] == "image/png")
    end
  end

  test "image hex key overrides media key and plaintext images are supported" do
    body = <<255, 216, 255, "image">>
    key = "0123456789abcdef"
    Application.put_env(:salix_im, :wechat_files_test_body, encrypt(body, key))

    encrypted =
      put_in(
        item(2, %{"encrypt_query_param" => "image", "aes_key" => "invalid"}),
        ["image_item", "aeskey"],
        Base.encode16(key)
      )

    assert {:ok, [_], []} = stage([encrypted])
    Application.put_env(:salix_im, :wechat_files_test_body, body)
    assert {:ok, [_], []} = stage([item(2, %{"encrypt_query_param" => "plain"})])
  end

  test "malformed keys, padding, destinations and redirects fail without publishing" do
    Application.put_env(:salix_im, :wechat_files_test_body, :binary.copy(<<0>>, 16))

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
      refute_receive {:published, _, _, _}, 10
    end

    refute_receive {:download, "never", _}, 10
  end

  test "declared and streamed oversize files do not publish partial bytes" do
    media = %{"encrypt_query_param" => "large", "aes_key" => Base.encode64("0123456789abcdef")}

    declared =
      put_in(
        item(4, %{media | "encrypt_query_param" => "never"}),
        ["file_item", "len"],
        "10485761"
      )

    for oversized <- [declared, item(4, media)] do
      assert {:ok, [], [%{"stage_error" => "size_limit"}]} = stage([oversized])
      refute_receive {:published, _, _, _}, 10
    end

    refute_receive {:download, "never", _}, 10
  end

  test "same names have separate paths and excess attachments fail explicitly" do
    Application.put_env(:salix_im, :wechat_files_test_body, "image")

    assert {:ok, staged, [%{"stage_error" => "size_limit"}]} =
             stage(List.duplicate(item(2, %{"encrypt_query_param" => "plain"}), 5))

    assert length(staged) == 4
    assert length(Enum.uniq_by(staged, & &1["path"])) == 4
  end

  test "inline quoted images and files share limits with direct media and keep quote provenance" do
    key = "0123456789abcdef"
    body = "quoted file bytes"
    Application.put_env(:salix_im, :wechat_files_test_body, encrypt(body, key))
    media = %{"encrypt_query_param" => "quoted-secret", "aes_key" => Base.encode64(key)}
    connect = %{"connect_id" => "connect", "wechat_id" => "alice"}

    for type <- [2, 4] do
      source = %{
        "message_id" => "quote-#{type}",
        "item_list" => [
          %{
            "type" => 1,
            "text_item" => %{"text" => "explain it"},
            "ref_msg" => %{"message_item" => item(type, media)}
          }
        ]
      }

      prepared = SalixIM.WeChatMessages.prepare(connect, source)

      assert {:ok, [staged], []} =
               ProviderAttachments.stage("agent", WeChatFiles.attachments(connect, prepared))

      assert staged["quoted"] == true
      assert_receive {:published, "agent", _, ref}
      assert {:ok, ^body} = SalixStore.Blob.get("agent", ref)
      refute inspect(staged) =~ "quoted-secret"
    end

    prepared =
      SalixIM.WeChatMessages.prepare(connect, %{
        "message_id" => "mixed",
        "item_list" => [
          item(4, media),
          %{
            "type" => 1,
            "text_item" => %{"text" => "compare"},
            "ref_msg" => %{"message_item" => item(4, media)}
          }
        ]
      })

    assert {:ok, [direct, quoted], []} =
             ProviderAttachments.stage("agent", WeChatFiles.attachments(connect, prepared))

    refute direct["quoted"]
    assert quoted["quoted"]
    refute direct["path"] == quoted["path"]
  end

  test "ID-only quotes recover exact observed content and media within the same connect and peer" do
    connect = %{"connect_id" => "connect", "wechat_id" => "alice"}
    Application.put_env(:salix_im, :wechat_files_test_body, "image bytes")
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

    assert_receive {:download, "private-query", []}

    for foreign <- [%{connect | "connect_id" => "other"}, %{connect | "wechat_id" => "mallory"}] do
      missing = SalixIM.WeChatMessages.prepare(foreign, quote)
      assert WeChatFiles.attachments(foreign, missing) == []
      assert SalixIM.WeChatMessages.text_body(missing) =~ "Quoted content unavailable"
    end

    refute_receive {:download, _, _}, 10
  end

  test "quoted text, titles, selections and missing targets remain separate from the current instruction" do
    connect = %{"connect_id" => "connect", "wechat_id" => "alice"}
    body = "before 开始 😀 内容结束 after"
    quoted = %{"type" => 1, "text_item" => %{"text" => body}}

    ref = %{
      "title" => "Alice",
      "message_item" => quoted,
      "partial_text" => %{"start" => "开始", "end" => "结束", "startindex" => 0, "endindex" => 0}
    }

    message = %{
      "item_list" => [%{"type" => 1, "text_item" => %{"text" => "explain"}, "ref_msg" => ref}]
    }

    prepared = SalixIM.WeChatMessages.prepare(connect, message)
    assert SalixIM.WeChatMessages.text_body(prepared, false) == "explain"
    output = SalixIM.WeChatMessages.text_body(prepared)
    assert output =~ body
    assert output =~ ~s("selected_text":"开始 😀 内容结束")
    assert output =~ "Alice"

    missing =
      put_in(message, ["item_list"], [
        %{
          "type" => 1,
          "text_item" => %{"text" => "explain"},
          "ref_msg" => %{"svr_id" => "unknown", "title" => "summary only"}
        }
      ])

    assert SalixIM.WeChatMessages.prepare(connect, missing) |> SalixIM.WeChatMessages.text_body() =~
             "Quoted content unavailable"

    assert SalixIM.WeChatMessages.prepare(connect, %{
             "item_list" => [
               nil,
               %{"type" => 1, "text_item" => %{"text" => "safe"}, "ref_msg" => []}
             ]
           })
           |> SalixIM.WeChatMessages.text_body() == "safe"
  end

  test "voice without transcript and video bytes are available as attachments, unknown media packing fails" do
    key = "0123456789abcdef"
    Application.put_env(:salix_im, :wechat_files_test_body, encrypt("media bytes", key))
    media = %{"encrypt_query_param" => "media", "aes_key" => Base.encode64(key)}

    for {type, field} <- [{3, "voice_item"}, {5, "video_item"}] do
      value = %{"type" => type, field => %{"media" => media, "encode_type" => 7}}
      assert {:ok, [_], []} = stage([value])
    end

    assert {:ok, [], [%{"stage_error" => "download_failed"}]} =
             stage([item(2, Map.put(media, "encrypt_type", 99))])
  end

  test "expired, oversized and unavailable quote projections fail explicitly without losing current text" do
    alias SalixIM.WeChatMessages
    alias SalixStore.{CasRecord, Keys}
    connect = %{"connect_id" => "connect", "wechat_id" => "alice"}

    original = %{
      "message_id" => "old",
      "item_list" => [%{"type" => 1, "text_item" => %{"text" => "old content"}}]
    }

    assert {:ok, _} = WeChatMessages.remember(connect, original)

    assert {:ok, _} =
             CasRecord.update(Keys.ctl_im_wechat_quote("connect", "old"), fn record ->
               Map.put(record, "created_at", 0)
             end)

    quote = %{
      "type" => 1,
      "text_item" => %{"text" => "current question"},
      "ref_msg" => %{"svr_id" => "old"}
    }

    prepared = WeChatMessages.prepare(connect, %{"item_list" => [quote]})
    assert WeChatMessages.text_body(prepared) =~ "Quoted content unavailable"
    assert WeChatMessages.text_body(prepared, false) == "current question"

    assert {:error, :quote_not_cacheable} =
             WeChatMessages.remember(connect, %{
               original
               | "message_id" => "large",
                 "item_list" =>
                   List.duplicate(
                     %{"type" => 1, "text_item" => %{"text" => String.duplicate("a", 8_000)}},
                     10
                   )
             })

    SalixStore.S3.Fake.blackhole({:fail, 503, :get, {:prefix, "ctl/im_wechat_quotes/"}})

    on_exit(fn ->
      if Process.whereis(SalixStore.S3.Fake), do: SalixStore.S3.Fake.clear_blackhole()
    end)

    assert WeChatMessages.prepare(connect, %{"item_list" => [quote]})
           |> WeChatMessages.text_body() =~ "current question"
  end

  test "quote lookup and item limits expose omissions and do not recursively expand quotes" do
    alias SalixIM.WeChatMessages
    connect = %{"connect_id" => "connect", "wechat_id" => "alice"}

    quoted =
      for n <- 1..5 do
        id = "message-#{n}"

        assert {:ok, _} =
                 WeChatMessages.remember(connect, %{
                   "message_id" => id,
                   "item_list" => [%{"type" => 1, "text_item" => %{"text" => "body-#{n}"}}]
                 })

        %{"type" => 1, "text_item" => %{"text" => "ask"}, "ref_msg" => %{"svr_id" => id}}
      end

    output =
      WeChatMessages.prepare(connect, %{"item_list" => quoted}) |> WeChatMessages.text_body()

    assert output =~ "body-4"
    refute output =~ "body-5"
    assert output =~ "Quoted content unavailable"

    nested = %{
      "type" => 1,
      "text_item" => %{"text" => "outer"},
      "ref_msg" => %{
        "message_item" => %{
          "type" => 1,
          "text_item" => %{"text" => "inner"},
          "ref_msg" => %{"message_item" => item(2, %{"encrypt_query_param" => "never-download"})}
        }
      }
    }

    prepared = WeChatMessages.prepare(connect, %{"item_list" => List.duplicate(nested, 11)})
    assert WeChatMessages.text_body(prepared) =~ "Additional WeChat items omitted"
    assert WeChatFiles.attachments(connect, prepared) == []
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
