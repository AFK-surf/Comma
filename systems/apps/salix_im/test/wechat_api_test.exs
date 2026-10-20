defmodule SalixIM.WeChatAPITest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

  defmodule Provider do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      {content_type, body} = SystemsRuntime.fetch_env!(:salix_im, :wechat_api_test_response)
      conn |> put_resp_content_type(content_type) |> send_resp(200, body)
    end
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_im, :wechat_api_base_url)

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port -> {Bandit, plug: Provider, port: port} end)

    base = "http://127.0.0.1:#{port}"
    SystemsRuntime.put_env(:salix_im, :wechat_api_base_url, base)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_im, :wechat_api_base_url, previous),
        else: SystemsRuntime.delete_env(:salix_im, :wechat_api_base_url)

      SystemsRuntime.delete_env(:salix_im, :wechat_api_test_response)
    end)

    %{base: base}
  end

  test "QR login and polling accept provider JSON sent as octet-stream", %{base: base} do
    qr = %{"qrcode" => "test-qr", "qrcode_img_content" => "https://weixin.qq.com/test-qr"}
    respond("application/octet-stream", Jason.encode!(qr))
    assert {:ok, ^qr} = SalixIM.WeChatAPI.start_login()

    respond("application/octet-stream", ~s({"status":"wait"}))
    assert {:ok, %{"status" => "wait"}} = SalixIM.WeChatAPI.poll_login(base, "test-qr")
  end

  test "outbound octet-stream JSON errors are not reported as delivered", %{base: base} do
    connect = %{
      "status" => "connected",
      "base_url" => base,
      "token" => "test-token",
      "wechat_id" => "test-user",
      "latest_context_token" => "test-context"
    }

    respond("application/octet-stream", ~s({"ret":42,"errmsg":"rejected"}))

    assert {:error, error} =
             SalixIM.Provider.WeChat.call("test-agent", connect, "wechat.reply_text", %{
               "text" => "hello"
             })

    assert error =~ "errcode=42"

    for body <- ["not json", "[]"] do
      respond("application/octet-stream", body)

      assert {:error, _} =
               SalixIM.Provider.WeChat.call("test-agent", connect, "wechat.reply_text", %{
                 "text" => "hello"
               })
    end

    respond("application/octet-stream", ~s({"ret":0}))

    assert {:ok, %{"message_id" => id}} =
             SalixIM.Provider.WeChat.call("test-agent", connect, "wechat.reply_text", %{
               "text" => "hello"
             })

    assert is_binary(id) and id != ""
  end

  test "reply_text retries a closed connection with the same message" do
    # Close the first two connections before responding, as a stale pooled
    # socket does, then accept the third attempt.
    {base, requests} = flaky_server(close_first: 2)

    assert {:ok, %{"message_id" => id}} =
             SalixIM.Provider.WeChat.call("test-agent", connect(base), "wechat.reply_text", %{
               "text" => "hello"
             })

    bodies = requests.()
    assert length(bodies) == 3
    assert bodies |> Enum.map(& &1["msg"]["client_id"]) |> Enum.uniq() == [id]
  end

  defp connect(base) do
    %{
      "status" => "connected",
      "base_url" => base,
      "token" => "test-token",
      "wechat_id" => "test-user",
      "latest_context_token" => "test-context"
    }
  end

  # Raw TCP so the test controls when the socket closes; Bandit always answers.
  defp flaky_server(close_first: close_first) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    test = SystemsRuntime.Proc.self()

    pid =
      SystemsRuntime.Proc.spawn_link(fn ->
        Stream.iterate(1, &(&1 + 1))
        |> Enum.each(fn attempt ->
          {:ok, socket} = :gen_tcp.accept(listen)
          SystemsRuntime.Proc.send(test, {:wechat_request, read_json_body(socket)})

          if close_first == :all or attempt <= close_first do
            :gen_tcp.close(socket)
          else
            body = ~s({"ret":0})

            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
                "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
            )

            :gen_tcp.close(socket)
          end
        end)
      end)

    on_exit(fn -> SystemsRuntime.Proc.exit(pid, :kill) end)

    requests = fn ->
      Stream.repeatedly(fn ->
        SystemsRuntime.Proc.receive do
          {:wechat_request, body} -> body
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
    end

    {"http://127.0.0.1:#{port}", requests}
  end

  defp read_json_body(socket, acc \\ "") do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    acc = acc <> data

    with [headers, body] <- String.split(acc, "\r\n\r\n", parts: 2),
         [_, length] <- Regex.run(~r/content-length: (\d+)/i, headers),
         true <- byte_size(body) >= String.to_integer(length) do
      Jason.decode!(body)
    else
      _ -> read_json_body(socket, acc)
    end
  end

  defp respond(content_type, body) do
    SystemsRuntime.put_env(:salix_im, :wechat_api_test_response, {content_type, body})
  end
end
