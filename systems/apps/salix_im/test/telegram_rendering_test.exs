defmodule SalixIM.TelegramRenderingTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixIM.Provider.Telegram
  alias SalixIM.TestSupport.BanditServer

  defmodule API do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      {:ok, raw, conn} = read_body(conn)
      body = Jason.decode!(raw)
      method = List.last(conn.path_info)

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :telegram_rendering_test_pid),
        {:sent, method, body}
      )

      failure = SystemsRuntime.get_env(:salix_im, :telegram_rendering_test_failure)

      {status, response} =
        if method == "sendMessage" and body["parse_mode"] == "HTML" and failure do
          {status, description} = failure
          {status, %{"ok" => false, "error_code" => status, "description" => description}}
        else
          {200, %{"ok" => true, "result" => %{"message_id" => 42}}}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end
  end

  setup do
    keys = [
      :telegram_api_base_url,
      :telegram_rendering_test_pid,
      :telegram_rendering_test_failure
    ]

    previous = Enum.map(keys, &{&1, SystemsRuntime.get_env(:salix_im, &1)})
    port = BanditServer.start!(fn port -> {Bandit, plug: API, port: port} end)
    SystemsRuntime.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:salix_im, :telegram_rendering_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.delete_env(:salix_im, :telegram_rendering_test_failure)

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(:salix_im, key),
          else: SystemsRuntime.put_env(:salix_im, key, value)
      end
    end)

    %{
      connect: %{
        "status" => "connected",
        "provider" => "telegram",
        "bot_token" => "token",
        "managed_by" => "comma_product",
        "managed_peer_id" => "123"
      }
    }
  end

  test "screenshot Markdown becomes formatted text at the real provider boundary, preserving placement",
       %{connect: connect} do
    source =
      "**Agent Files（vfs）** and **Default workspace Connector（comma）**\n\n`a_b` [Comma](https://comma.test)"

    assert {:ok, %{"message_id" => 42}} = send_text(connect, source)
    settle_receive({:sent, "sendMessage", body})
    assert body["text"] =~ "<b>Agent Files（vfs）</b>"
    assert body["text"] =~ "<code>a_b</code>"
    assert body["text"] =~ ~s(<a href="https://comma.test">Comma</a>)
    assert body["message_thread_id"] == 7
    assert body["reply_parameters"] == %{"message_id" => 8}
    settle_refute_receive({:sent, _, _}, 20)
  end

  test "an automatic source reply reaches Telegram with its native reference", %{connect: connect} do
    ctx = %{
      llm_tool_envelope: true,
      terminal_reply_context: %{
        "kind" => "telegram",
        "eligible" => true,
        "connect_id" => "telegram-1",
        "chat_id" => "123",
        "message_thread_id" => "",
        "reply_to_message_id" => "81"
      }
    }

    call = %{
      id: "reply",
      name: "im_api.telegram.send_message",
      args: %{"connect_id" => "telegram-1", "chat_id" => "123", "text" => "答案"},
      reply_intent: %{"reply_mode" => "final", "final_outcome" => "done"}
    }

    assert {:ok, reply} = SalixAgent.TerminalReply.authorize(call, ctx)
    assert {:ok, _} = Telegram.call("agent", connect, "telegram.send_message", reply.args)

    settle_receive({:sent, "sendMessage", body})
    assert body["text"] == "答案"

    assert body["reply_parameters"] == %{
             "message_id" => "81",
             "allow_sending_without_reply" => true
           }

    refute Map.has_key?(body, "allow_sending_without_reply")
    settle_refute_receive({:sent, _, _}, 20)
  end

  test "foreign managed peer remains denied before rendering or HTTP", %{connect: connect} do
    assert {:error, _} = send_text(connect, "**hello**", %{"chat_id" => "other"})
    settle_refute_receive({:sent, _, _}, 20)
  end

  test "keyboard removal sends a normal message with Telegram ReplyKeyboardRemove", %{
    connect: connect
  } do
    assert {:ok, %{"message_id" => 42}} = remove_keyboard(connect)

    settle_receive(
      {:sent, "sendMessage",
       %{
         "chat_id" => "123",
         "text" => "定位测试键盘已移除。",
         "reply_markup" => %{"remove_keyboard" => true}
       }}
    )

    settle_refute_receive({:sent, _, _}, 20)
  end

  defp remove_keyboard(connect, extra \\ %{}) do
    Telegram.call(
      "agent",
      connect,
      "telegram.remove_reply_keyboard",
      Map.merge(%{"chat_id" => "123", "text" => "定位测试键盘已移除。"}, extra)
    )
  end

  defp send_text(connect, text, extra \\ %{}) do
    Telegram.call(
      "agent",
      connect,
      "telegram.send_message",
      Map.merge(
        %{
          "chat_id" => "123",
          "text" => text,
          "message_thread_id" => 7,
          "reply_to_message_id" => 8
        },
        extra
      )
    )
  end
end
