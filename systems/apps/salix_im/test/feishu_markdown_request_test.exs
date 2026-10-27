defmodule SalixIM.Provider.Feishu.MarkdownRequestTest do
  use SystemsClock.Case, async: false

  alias SalixIM.MessageRenderer.Input
  alias SalixIM.Provider.Feishu
  alias SalixIM.Provider.Feishu.MessageRenderer

  @connect %{
    "status" => "connected",
    "app_id" => "cli_test",
    "tenant_access_token" => "offline-test-token"
  }

  setup do
    original = Req.default_options()
    Req.default_options(Keyword.put(original, :plug, {Req.Test, __MODULE__}))

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:http, conn.method, conn.request_path, conn.query_string, body, raw}
      )

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer offline-test-token"]

      data =
        if conn.method == "GET" do
          %{
            "items" => [
              %{
                "message_id" => "om_existing",
                "sender" => %{"id" => "cli_test", "sender_type" => "app"}
              }
            ]
          }
        else
          %{"message_id" => "om_sent"}
        end

      Req.Test.json(conn, %{"code" => 0, "data" => data})
    end)

    on_exit(fn -> Req.default_options(original) end)
    :ok
  end

  test "send sends a real encoded post request and preserves receive ID type and UUID" do
    params = %{
      "receive_id" => "ou_destination",
      "receive_id_type" => "open_id",
      "text" => "# 标题\n\n**正文**"
    }

    scope = %{tool_call_id: "tool-call-1"}
    assert {:ok, _} = Feishu.call("agent", @connect, "feishu.send_text", params, scope)

    assert_received {:http, "POST", "/open-apis/im/v1/messages", "receive_id_type=open_id", body,
                     raw}

    assert body["receive_id"] == "ou_destination"
    assert body["msg_type"] == "post"
    assert markdown(body) == params["text"]

    expected =
      :crypto.hash(:sha256, "feishu.send_text\0ou_destination\0tool-call-1")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 40)

    assert body["uuid"] == "bft_" <> expected
    assert byte_size(raw) == byte_size(Jason.encode!(body))
    assert {:ok, _} = Feishu.call("agent", @connect, "feishu.send_text", params, scope)
    assert_received {:http, "POST", _, _, replay, _}
    assert replay["uuid"] == body["uuid"]
  end

  test "reply preserves source path, UUID and explicit or default thread behavior" do
    for {extra, expected} <- [
          {%{"chat_type" => "group"}, true},
          {%{"chat_type" => "group", "thread_id" => "omt_existing"}, false},
          {%{"chat_type" => "group", "reply_in_thread" => false}, false}
        ] do
      params = Map.merge(%{"message_id" => "om_source", "text" => "- [x] Done"}, extra)

      assert {:ok, _} =
               Feishu.call("agent", @connect, "feishu.reply_text", params, %{
                 tool_call_id: "reply-1"
               })

      assert_received {:http, "POST", "/open-apis/im/v1/messages/om_source/reply", "", body, _}
      assert body["reply_in_thread"] == expected
      assert body["msg_type"] == "post"
      assert body["uuid"] =~ "bft_"
      refute Map.has_key?(body, "receive_id")
    end
  end

  test "a reply with a question is a card whose button carries what the answer needs" do
    assert {:ok, _} =
             Feishu.call("agent", @connect, "feishu.reply_text", %{
               "message_id" => "om_source",
               "chat_type" => "group",
               "thread_id" => "omt_source",
               "text" => "部署到哪个环境？",
               "mentions" => [%{"user_id" => "ou_alice", "name" => "Alice"}],
               "question" => %{"type" => "text", "locale" => "zh-CN"}
             })

    assert_received {:http, "POST", "/open-apis/im/v1/messages/om_source/reply", "", body, _}
    assert body["msg_type"] == "interactive"
    card = Jason.decode!(body["content"])

    assert [%{"tag" => "markdown", "content" => "<at id=ou_alice></at> 部署到哪个环境？"}, form] =
             card["body"]["elements"]

    assert [%{"tag" => "input"}, %{"tag" => "button", "behaviors" => [%{"value" => value}]}] =
             form["elements"]

    assert value == %{
             "bft_question" => true,
             "text" => "<at id=ou_alice></at> 部署到哪个环境？",
             "locale" => "zh-CN",
             "chat_type" => "group",
             "thread_id" => "omt_source"
           }

    # The Agent's own words cannot become a mention or any other card tag.
    assert {:ok, _} =
             Feishu.call("agent", @connect, "feishu.reply_text", %{
               "message_id" => "om_source",
               "text" => "<at id=all></at> <font color='red'>pick</font>",
               "question" => %{"type" => "text"}
             })

    assert_received {:http, "POST", _, _, %{"content" => content}, _}
    [markdown | _] = Jason.decode!(content)["body"]["elements"]

    assert markdown["content"] ==
             "&#60;at id=all&#62;&#60;/at&#62; &#60;font color='red'&#62;pick&#60;/font&#62;"

    # Mentions are checked as a post checks them: everyone only through mention_all.
    assert {:error, "use mention_all=true instead of a user_id=all mention"} =
             Feishu.call("agent", @connect, "feishu.reply_text", %{
               "message_id" => "om_source",
               "text" => "pick",
               "mentions" => [%{"user_id" => "all"}],
               "question" => %{"type" => "text"}
             })

    # The whole request is measured: a card under the limit whose escaped JSON
    # in the request body is over it is refused before anything is sent.
    for text <- [String.duplicate("\"", 9_000), String.duplicate("\\", 7_000)] do
      assert {:error, "Feishu interactive request is " <> _} =
               Feishu.call("agent", @connect, "feishu.reply_text", %{
                 "message_id" => "om_source",
                 "text" => text,
                 "question" => %{"type" => "text"}
               })
    end

    refute_received {:http, "POST", _, _, _, _}

    assert {:error, "question.options holds 1-6 options"} =
             Feishu.call("agent", @connect, "feishu.reply_text", %{
               "message_id" => "om_source",
               "text" => "Pick one",
               "question" => %{"type" => "options", "options" => []}
             })
  end

  test "update checks bot ownership and sends post via PUT" do
    assert {:ok, _} =
             Feishu.call("agent", @connect, "feishu.update_message", %{
               "message_id" => "om_existing",
               "text" => "## Updated"
             })

    assert_received {:http, "GET", "/open-apis/im/v1/messages/om_existing", _, nil, _}
    assert_received {:http, "PUT", "/open-apis/im/v1/messages/om_existing", "", body, _}
    assert body["msg_type"] == "post"
    assert markdown(body) == "## Updated"
  end

  test "update still refuses a message owned by another sender" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(conn, %{
        "code" => 0,
        "data" => %{"items" => [%{"sender" => %{"id" => "ou_other", "sender_type" => "user"}}]}
      })
    end)

    assert {:error, "Feishu message is not authored by this bot"} =
             Feishu.call("agent", @connect, "feishu.update_message", %{
               "message_id" => "om_other",
               "text" => "update"
             })
  end

  test "unknown write outcome still has one attempt and an actionable error" do
    Req.Test.stub(__MODULE__, fn conn ->
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :write_attempt)
      Plug.Conn.send_resp(conn, 503, "upstream error")
    end)

    assert {:error, error} =
             Feishu.call("agent", @connect, "feishu.reply_text", %{
               "message_id" => "om_source",
               "text" => "hello"
             })

    assert error =~ "write outcome unknown"
    assert_received :write_attempt
    refute_received :write_attempt
  end

  defp markdown(body) do
    get_in(Jason.decode!(body["content"]), ["zh_cn", "content"])
    |> List.last()
    |> hd()
    |> Map.fetch!("text")
  end
end
