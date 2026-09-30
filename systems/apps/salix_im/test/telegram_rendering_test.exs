defmodule SalixIM.TelegramRenderingTest do
  use ExUnit.Case, async: false

  alias SalixIM.Provider.Telegram
  alias SalixIM.TestSupport.BanditServer

  defmodule API do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      {:ok, raw, conn} = read_body(conn)
      body = Jason.decode!(raw)
      method = List.last(conn.path_info)
      send(Application.fetch_env!(:salix_im, :telegram_rendering_test_pid), {:sent, method, body})
      failure = Application.get_env(:salix_im, :telegram_rendering_test_failure)

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

    previous = Enum.map(keys, &{&1, Application.get_env(:salix_im, &1)})
    port = BanditServer.start!(fn port -> {Bandit, plug: API, port: port} end)
    Application.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_im, :telegram_rendering_test_pid, self())
    Application.delete_env(:salix_im, :telegram_rendering_test_failure)

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:salix_im, key),
          else: Application.put_env(:salix_im, key, value)
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
    assert_receive {:sent, "sendMessage", body}
    assert body["text"] =~ "<b>Agent Files（vfs）</b>"
    assert body["text"] =~ "<code>a_b</code>"
    assert body["text"] =~ ~s(<a href="https://comma.test">Comma</a>)
    assert body["message_thread_id"] == 7
    assert body["reply_parameters"] == %{"message_id" => 8}
    refute_receive {:sent, _, _}, 20
  end

  test "headings, lists, tables and fenced code retain structure without activating HTML or media",
       %{connect: connect} do
    source =
      "# 标题\n\n- **一**\n- 二\n\n| A | B |\n|---|---|\n|中|😀|\n\n```elixir\n<b>x</b> & y\n```\n\n![photo](https://example.test/private.png)\n\n<tg-button type=\"callback\" data=\"x\">run</tg-button>"

    assert {:ok, _} = send_text(connect, source)
    assert_receive {:sent, "sendMessage", %{"text" => html, "parse_mode" => "HTML"}}

    for tag <- [
          "<b>标题</b>",
          "• 一",
          "A | B",
          "<pre>",
          "&lt;b&gt;x&lt;/b&gt; &amp; y"
        ] do
      assert html =~ tag
    end

    refute html =~ "<img"
    refute html =~ "<tg-button"
    assert html =~ "&lt;tg-button"
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

    assert_receive {:sent, "sendMessage", body}
    assert body["text"] == "答案"

    assert body["reply_parameters"] == %{
             "message_id" => "81",
             "allow_sending_without_reply" => true
           }

    refute Map.has_key?(body, "allow_sending_without_reply")
    refute_receive {:sent, _, _}, 20
  end

  test "4096 characters use one normal message; oversized replies and invalid formats never send",
       %{connect: connect} do
    assert {:ok, _} = send_text(connect, String.duplicate("a", 4096))
    assert_receive {:sent, "sendMessage", _}

    for source <- [String.duplicate("a", 4097), String.duplicate("😀", 2049), "   "] do
      assert {:error, _} = send_text(connect, source)
    end

    assert {:error, _} = send_text(connect, "x", %{"text_format" => "html"})
    refute_receive {:sent, _, _}, 20
  end

  test "explicit plain text is literal and has the ordinary-message limit", %{connect: connect} do
    assert {:ok, _} = send_text(connect, "**literal** <tag>", %{"text_format" => "plain"})
    assert_receive {:sent, "sendMessage", %{"text" => "**literal** <tag>"} = body}
    refute Map.has_key?(body, "parse_mode")

    assert {:error, _} =
             send_text(connect, String.duplicate("a", 4097), %{"text_format" => "plain"})

    refute_receive {:sent, _, _}, 20
  end

  test "only explicit format rejection falls back, with a readable single final message", %{
    connect: connect
  } do
    handler = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _, _, metadata, _ ->
        if metadata[:operation] == "telegram_send_message",
          do: send(parent, {:outcome, metadata.outcome})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Application.put_env(
      :salix_im,
      :telegram_rendering_test_failure,
      {400, "Bad Request: can't parse entities"}
    )

    assert {:ok, _} = send_text(connect, "**你好** `a_b`")
    assert_receive {:sent, "sendMessage", _}

    assert_receive {:sent, "sendMessage",
                    %{"text" => "你好 a_b", "reply_parameters" => %{"message_id" => 8}}}

    refute_receive {:sent, _, _}, 20
    assert_receive {:outcome, :ok}
    refute_receive {:outcome, _}, 20
  end

  test "forbidden, throttling, server errors and unrelated bad requests never trigger a second send",
       %{connect: connect} do
    for failure <- [
          {403, "Forbidden"},
          {429, "Too Many Requests"},
          {503, "Unavailable"},
          {400, "Bad Request: chat not found"}
        ] do
      Application.put_env(:salix_im, :telegram_rendering_test_failure, failure)
      assert {:error, _} = send_text(connect, "**hello**")
      assert_receive {:sent, "sendMessage", _}
      refute_receive {:sent, _, _}, 20
    end
  end

  test "parser rejection preserves code whitespace through the actual plain resend", %{
    connect: connect
  } do
    Application.put_env(
      :salix_im,
      :telegram_rendering_test_failure,
      {400, "Bad Request: can't parse entities"}
    )

    assert {:ok, _} = send_text(connect, "```\n  first\n    second  \n```")
    assert_receive {:sent, "sendMessage", _}
    assert_receive {:sent, "sendMessage", %{"text" => "  first\n    second  \n"}}
    refute_receive {:sent, _, _}, 20

    assert {:ok, _} = send_text(connect, "- ```\n    first\n      second  \n  ```")
    assert_receive {:sent, "sendMessage", _}
    assert_receive {:sent, "sendMessage", %{"text" => "•   first\n    second  \n"}}
    refute_receive {:sent, _, _}, 20

    assert {:ok, _} = send_text(connect, "> ```\n>   first\n>     second  \n> ```")
    assert_receive {:sent, "sendMessage", _}
    assert_receive {:sent, "sendMessage", %{"text" => "  first\n    second  \n"}}
    refute_receive {:sent, _, _}, 20
  end

  test "overlong text is rejected before HTTP even when the provider rejects formatting", %{
    connect: connect
  } do
    Application.put_env(
      :salix_im,
      :telegram_rendering_test_failure,
      {400, "Bad Request: can't parse entities"}
    )

    assert {:error, _} = send_text(connect, String.duplicate("a", 4097))
    refute_receive {:sent, _, _}, 20
  end

  test "foreign managed peer remains denied before rendering or HTTP", %{connect: connect} do
    assert {:error, _} = send_text(connect, "**hello**", %{"chat_id" => "other"})
    refute_receive {:sent, _, _}, 20
  end

  test "keyboard removal sends a normal message with Telegram ReplyKeyboardRemove", %{
    connect: connect
  } do
    assert {:ok, %{"message_id" => 42}} = remove_keyboard(connect)

    assert_receive {:sent, "sendMessage",
                    %{
                      "chat_id" => "123",
                      "text" => "定位测试键盘已移除。",
                      "reply_markup" => %{"remove_keyboard" => true}
                    }}

    refute_receive {:sent, _, _}, 20
  end

  test "keyboard removal preserves the command through a definitive format fallback", %{
    connect: connect
  } do
    Application.put_env(
      :salix_im,
      :telegram_rendering_test_failure,
      {400, "Bad Request: can't parse entities"}
    )

    assert {:ok, _} = remove_keyboard(connect, %{"text" => "**已移除**"})
    assert_receive {:sent, "sendMessage", %{"parse_mode" => "HTML"}}

    assert_receive {:sent, "sendMessage",
                    %{"text" => "已移除", "reply_markup" => %{"remove_keyboard" => true}}}

    refute_receive {:sent, _, _}, 20
  end

  test "keyboard removal cannot address a foreign managed peer or send empty text", %{
    connect: connect
  } do
    assert {:error, _} = remove_keyboard(connect, %{"chat_id" => "other"})
    assert {:error, _} = remove_keyboard(connect, %{"text" => "   "})
    refute_receive {:sent, _, _}, 20
  end

  defp remove_keyboard(connect, extra \\ %{}) do
    Telegram.call(
      "agent",
      connect,
      "telegram.remove_reply_keyboard",
      Map.merge(%{"chat_id" => "123", "text" => "定位测试键盘已移除。"}, extra)
    )
  end

  test "varied realistic replies each reach the HTTP boundary as exactly one complete normal message",
       %{connect: connect} do
    samples = [
      {"**构建成功**，`mix test` 共 90 项通过。", "<b>构建成功</b>"},
      {"[![Build](https://example.test/badge.svg)](https://example.test/build)",
       ~s(<a href="https://example.test/build">Build</a>)},
      {"![](https://example.test/screenshot.png)", ~s(>https://example.test/screenshot.png</a>)},
      {"## 下一步\n\n1. 检查\n2. 验收", "1. 检查"},
      {"- [x] 编码完成\n- [ ] 尚未部署", "☑ "},
      {"| 环境 | 状态 |\n|---|---|\n| staging | 待验收 |", "环境 | 状态"},
      {"```json\n{\"count\": 42, \"value\": \"<>&\"}\n```", "&lt;&gt;&amp;"},
      {"> 引用历史讨论\n\n**结论**：继续。", "&gt; 引用历史讨论"},
      {"**👩🏽‍💻 café مرحبا**", "👩🏽‍💻 café مرحبا"},
      {"文字 <tg-button data=\"x\">不是按钮</tg-button>", "&lt;tg-button"},
      {"`` const x = `literal`; ``", "<code>const x = `literal`;</code>"},
      {"详情：[报告](https://example.test/a_(b)?x=1&y=2)", "?x=1&amp;y=2"}
    ]

    for {source, expected} <- samples do
      assert {:ok, %{"message_id" => 42}} = send_text(connect, source)
      assert_receive {:sent, "sendMessage", body}
      assert body["text"] =~ expected
      assert body["reply_parameters"] == %{"message_id" => 8}
      assert body["message_thread_id"] == 7
      refute_receive {:sent, _, _}, 10
    end
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
