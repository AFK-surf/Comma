defmodule SalixIM.SlackObservedReadReceiptTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  import Plug.Conn

  alias SalixIM.Provider.Slack.API
  alias SalixIM.TestSupport.BanditServer
  alias SalixIM.Triage.CanonicalJSON

  defmodule SlackLoopback do
    use Plug.Builder

    plug(:dispatch)

    defp dispatch(conn, _opts) do
      conn = fetch_query_params(conn)

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :slack_receipt_test_owner),
        {:slack_request, conn}
      )

      case SystemsRuntime.get_env(:salix_im, :slack_receipt_test_response, :success) do
        {:json_body, request_id, body} ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", request_id)
          |> send_resp(200, Jason.encode!(body))

        :success ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-success-1")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{"text" => "root", "ts" => "1786693124.936679", "user" => "U_ROOT"},
                %{"text" => "reply", "ts" => "1786693130.000001", "user" => "U_REPLY"}
              ],
              "response_metadata" => %{"next_cursor" => ""}
            })
          )

        :slack_error ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-slack-error-1")
          |> send_resp(200, Jason.encode!(%{"ok" => false, "error" => "private-U-error"}))

        :rate_limited ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("retry-after", "17")
          |> put_resp_header("x-slack-req-id", "req-rate-limited-1")
          |> send_resp(429, Jason.encode!(%{"ok" => false, "error" => "private-rate-limit"}))

        :redirect ->
          conn
          |> put_resp_header("location", "/private-U-redirect")
          |> put_resp_header("x-slack-req-id", "req-http-error-1")
          |> send_resp(302, "private redirect body")

        :invalid_json ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-decode-error-1")
          |> send_resp(200, ~s({"ok":true,"messages":["private-U-broken"))

        :invalid_shape ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-shape-error-1")
          |> send_resp(
            200,
            Jason.encode!(%{
              "messages" => "private-U-not-a-list",
              "response_metadata" => %{"next_cursor" => 123}
            })
          )

        :unsafe_message ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-unsafe-message-1")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{
                  "text" => "safe visible text",
                  "ts" => "1786693124.936679",
                  "user" => "U_ROOT",
                  "display_as_bot" => true,
                  "upload" => false,
                  "root" => %{
                    "text" => "private root duplicate",
                    "ts" => "1786693000.000001",
                    "user" => "U_PRIVATE_ROOT"
                  },
                  "metadata" => %{
                    "authorization" => "Bearer private-metadata-credential"
                  }
                }
              ],
              "response_metadata" => %{"next_cursor" => ""}
            })
          )

        :unknown_message_key ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-unknown-message-key-1")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{
                  "text" => "safe visible text",
                  "ts" => "1786693124.936679",
                  "user" => "U_ROOT",
                  "metadata" => %{
                    "event_type" => "harmless amber private sentinel"
                  }
                }
              ],
              "response_metadata" => %{"next_cursor" => ""}
            })
          )

        :user_attributed_upload ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-user-attributed-upload-1")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{
                  "text" => "user-owned upload",
                  "ts" => "1786693124.936679",
                  "user" => "U_FILE_OWNER",
                  "bot_id" => "B_UPLOAD_TRANSPORT",
                  "app_id" => "A_USER_SCOPED_CLIENT",
                  "display_as_bot" => false,
                  "upload" => true,
                  "files" => [%{"id" => "F_PRIVATE", "user" => "U_FILE_OWNER"}]
                }
              ],
              "response_metadata" => %{"next_cursor" => ""}
            })
          )

        :ordinary_extras ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-ordinary-extras-1")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{
                  "type" => "message",
                  "team" => "T_DROP",
                  "client_msg_id" => "client-drop",
                  "thread_ts" => "1786693124.936679",
                  "last_read" => "1786693999.999999",
                  "unread_count" => 7,
                  "text" => "hello <@U_HUMAN>",
                  "ts" => "1786693130.000001",
                  "bot_id" => "B_BFT",
                  "app_id" => "A_BFT",
                  "bot_profile" => %{
                    "id" => "B_DROP",
                    "name" => "BFT (staging)",
                    "icons" => %{"image_36" => "https://example.invalid/icon.png"}
                  },
                  "blocks" => [
                    %{
                      "type" => "rich_text",
                      "block_id" => "drop-block-id",
                      "elements" => [
                        %{
                          "type" => "rich_text_section",
                          "elements" => [
                            %{"type" => "text", "text" => "hello "},
                            %{"type" => "user", "user_id" => "U_HUMAN"}
                          ]
                        },
                        %{
                          "type" => "rich_text_quote",
                          "contains_padding" => true,
                          "elements" => [%{"type" => "text", "text" => "quoted context"}]
                        }
                      ]
                    }
                  ],
                  "reactions" => [%{"name" => "eyes", "count" => 1, "users" => ["U_DROP"]}]
                }
              ],
              "response_metadata" => %{"next_cursor" => ""}
            })
          )

        :forbidden_attachment ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-forbidden-attachment-1")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{
                  "text" => "safe visible text",
                  "ts" => "1786693124.936679",
                  "user" => "U_ROOT",
                  "attachments" => [%{"text" => "Bearer private-attachment-credential"}]
                }
              ],
              "response_metadata" => %{"next_cursor" => ""}
            })
          )

        :ordinary_non_authoritative_content ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-ordinary-non-authoritative-content-1")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{
                  "text" => "safe visible text",
                  "ts" => "1786693124.936679",
                  "user" => "U_ROOT",
                  "display_as_bot" => true,
                  "upload" => false,
                  "root" => %{
                    "text" => "private root duplicate",
                    "ts" => "1786693000.000001",
                    "user" => "U_PRIVATE_ROOT"
                  },
                  "attachments" => [
                    %{
                      "fallback" => "private attachment fallback",
                      "original_url" => "https://private.example.invalid/attachment",
                      "title" => "private attachment title"
                    }
                  ],
                  "files" => [
                    %{
                      "id" => "F_PRIVATE",
                      "title" => "private file title",
                      "url_private" => "https://private.example.invalid/file"
                    }
                  ],
                  "blocks" => [
                    %{
                      "type" => "section",
                      "block_id" => "private-section",
                      "text" => %{
                        "type" => "mrkdwn",
                        "text" => "private section text"
                      }
                    },
                    %{"type" => "divider", "block_id" => "private-divider"},
                    %{
                      "type" => "rich_text",
                      "elements" => [
                        %{
                          "type" => "rich_text_section",
                          "elements" => [
                            %{
                              "type" => "user",
                              "user_id" => "U_MENTIONED",
                              "from_llm" => true
                            },
                            %{
                              "type" => "message_mention",
                              "author_id" => "U_PRIVATE_AUTHOR",
                              "channel_id" => "C_PRIVATE",
                              "message_ts" => "1786693000.000001",
                              "thread_ts" => "1786693000.000001",
                              "text" => "private linked message",
                              "url" => "https://private.example.invalid/message"
                            }
                          ]
                        }
                      ]
                    }
                  ]
                },
                %{
                  "text" => "",
                  "ts" => "1786693125.000001",
                  "user" => "U_FILE_OWNER",
                  "subtype" => "file_share",
                  "files" => [
                    %{
                      "id" => "F_PRIVATE_ONLY",
                      "title" => "private only file title",
                      "url_private" => "https://private.example.invalid/only-file"
                    }
                  ]
                }
              ],
              "response_metadata" => %{"next_cursor" => ""}
            })
          )

        {:pages, total} ->
          cursor = conn.query_params["cursor"] || ""
          index = if cursor == "", do: 1, else: String.to_integer(cursor)

          next_cursor =
            if total != :unbounded and index >= total, do: "", else: Integer.to_string(index + 1)

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-page-#{index}")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{"text" => "root", "ts" => "1786693124.936679", "user" => "U_ROOT"},
                %{
                  "text" => "reply #{index}",
                  "ts" => "17866931#{30 + index}.000001",
                  "user" => "U_REPLY"
                }
              ],
              "response_metadata" => %{"next_cursor" => next_cursor}
            })
          )

        # Every page carries `per_page` DISTINCT objects, so a full page budget
        # overruns the authorized logical limit.
        {:wide_pages, total, per_page} ->
          cursor = conn.query_params["cursor"] || ""
          index = if cursor == "", do: 1, else: String.to_integer(cursor)
          next_cursor = if index >= total, do: "", else: Integer.to_string(index + 1)

          messages =
            for slot <- 1..per_page do
              ordinal = (index - 1) * per_page + slot

              %{
                "text" => "wide #{ordinal}",
                "ts" => "1786694#{String.pad_leading(Integer.to_string(ordinal), 3, "0")}.000001",
                "user" => "U_WIDE"
              }
            end

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-wide-#{index}")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => messages,
              "response_metadata" => %{"next_cursor" => next_cursor}
            })
          )

        # `conversations.replies` asked about a REPLY's ts still answers with
        # the whole thread headed by its real parent.
        {:reply_ts_pages, total} ->
          cursor = conn.query_params["cursor"] || ""
          index = if cursor == "", do: 1, else: String.to_integer(cursor)
          next_cursor = if index >= total, do: "", else: Integer.to_string(index + 1)

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-reply-ts-#{index}")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{"text" => "real parent", "ts" => "1786693100.000001", "user" => "U_PARENT"},
                %{
                  "text" => "reply #{index}",
                  "ts" => "17866931#{30 + index}.000001",
                  "user" => "U_REPLY"
                }
              ],
              "response_metadata" => %{"next_cursor" => next_cursor}
            })
          )

        {:slow_pages, delay_ms} ->
          cursor = conn.query_params["cursor"] || ""
          index = if cursor == "", do: 1, else: String.to_integer(cursor)
          SystemsClock.sleep(delay_ms)

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-slow-#{index}")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{"text" => "root", "ts" => "1786693124.936679", "user" => "U_ROOT"},
                %{
                  "text" => "reply #{index}",
                  "ts" => "17866931#{30 + index}.000001",
                  "user" => "U_REPLY"
                }
              ],
              "response_metadata" => %{"next_cursor" => Integer.to_string(index + 1)}
            })
          )

        :rate_limited_beyond_window ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("retry-after", "180")
          |> put_resp_header("x-slack-req-id", "req-rate-limited-long-1")
          |> send_resp(429, Jason.encode!(%{"ok" => false, "error" => "private-rate-limit"}))

        :duplicate_timestamps ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-slack-req-id", "req-duplicate-timestamps-1")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "messages" => [
                %{"text" => "first", "ts" => "1786693124.936679", "user" => "U_FIRST"},
                %{"text" => "second", "ts" => "1786693124.936679", "user" => "U_SECOND"}
              ],
              "response_metadata" => %{"next_cursor" => ""}
            })
          )
      end
    end
  end

  @doc false
  def method_lease_key do
    scope =
      "xoxb-private-token" |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    "ctl/provider-method-budget/slack/#{scope}/conversations.replies.json"
  end

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    :ok = SalixStore.S3.Fake.reset()

    previous_base_url = SystemsRuntime.get_env(:salix_im, :slack_api_base_url)
    previous_owner = SystemsRuntime.get_env(:salix_im, :slack_receipt_test_owner)
    previous_response = SystemsRuntime.get_env(:salix_im, :slack_receipt_test_response)
    SystemsRuntime.put_env(:salix_im, :slack_receipt_test_owner, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_im, :slack_receipt_test_response, :success)

    port = BanditServer.start!(fn port -> {Bandit, plug: SlackLoopback, port: port} end)
    base_url = "http://127.0.0.1:#{port}/api"
    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, base_url)

    on_exit(fn ->
      restore_env(:salix_im, :slack_api_base_url, previous_base_url)
      restore_env(:salix_im, :slack_receipt_test_owner, previous_owner)
      restore_env(:salix_im, :slack_receipt_test_response, previous_response)
    end)

    {:ok, base_url: base_url}
  end

  test "observed Slack error returns one attempted receipt without the provider body", %{
    base_url: base_url
  } do
    SystemsRuntime.put_env(:salix_im, :slack_receipt_test_response, :slack_error)
    selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
    origin_sha256 = origin_sha256(base_url)

    assert {:error, :slack_error, receipt} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256,
               slack_api_origin_sha256: origin_sha256
             )

    settle_receive({:slack_request, _conn})
    settle_refute_receive({:slack_request, _conn}, 50)

    assert receipt == %{
             "schema" => "comma.slack-read-receipt-chain.v1",
             "operation" => "conversations.replies",
             "method" => "GET",
             "request_selector_sha256" => selector_sha256,
             "slack_api_origin_sha256" => origin_sha256,
             "transport_invocation_count" => 1,
             "page_budget" => 14,
             "retry" => false,
             "redirect" => false,
             "outcome" => "slack_error",
             "typed_reason" => "slack_error",
             "http_status" => 200,
             "canonical_page_sha256" => nil,
             "message_count" => nil,
             "next_cursor_empty" => nil,
             "canonical_page_chain_sha256" => nil,
             "rejection" => nil,
             "slack_request_id_sha256" => CanonicalJSON.sha256("req-slack-error-1"),
             "exchanges" => [
               %{
                 "schema" => "comma.slack-read-receipt.v1",
                 "operation" => "conversations.replies",
                 "method" => "GET",
                 "request_selector_sha256" =>
                   page_selector_sha256("C_THREAD", "1786693124.936679", ""),
                 "slack_api_origin_sha256" => origin_sha256,
                 "transport_invocation_count" => 1,
                 "retry" => false,
                 "redirect" => false,
                 "outcome" => "slack_error",
                 "typed_reason" => "slack_error",
                 "http_status" => 200,
                 "canonical_page_sha256" => nil,
                 "message_count" => nil,
                 "next_cursor_empty" => nil,
                 "slack_request_id_sha256" => CanonicalJSON.sha256("req-slack-error-1")
               }
             ]
           }

    receipt_text = inspect(receipt)
    refute receipt_text =~ "private-U-error"
    refute receipt_text =~ "xoxb-private-token"
  end

  # Every rejected page is one closed decode_error receipt: one request, no
  # canonical page, the typed rejection, and none of the rejected bytes.
  for {name, mode, stage, path, response_id, secrets} <- [
        {"observed decode failure returns one closed receipt without malformed bytes",
         :invalid_json, "json_decode", "response", {200, "req-decode-error-1"},
         ["private-U-broken"]},
        {"observed decoded body with an invalid page shape returns decode error", :invalid_shape,
         "response_shape", "response", {200, "req-shape-error-1"}, ["private-U-not-a-list"]},
        {"observed replies reject credential-shaped message content before page persistence",
         :unsafe_message, "credential_material", "messages[]", nil,
         ["safe visible text", "private-metadata-credential"]},
        {"observed replies still reject credentials nested in dropped attachment structures",
         :forbidden_attachment, "credential_material", "messages[]", nil,
         ["private-attachment-credential"]}
      ] do
    @mode mode
    @stage stage
    @path path
    @tag response_id: response_id
    @secrets secrets
    test name, %{base_url: base_url, response_id: response_id} do
      SystemsRuntime.put_env(:salix_im, :slack_receipt_test_response, @mode)
      selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
      origin_sha256 = origin_sha256(base_url)

      assert {:error, :decode_error, receipt} =
               API.conversation_replies(
                 "xoxb-private-token",
                 "C_THREAD",
                 "1786693124.936679",
                 receipt: :return,
                 limit: 200,
                 request_selector_sha256: selector_sha256,
                 slack_api_origin_sha256: origin_sha256
               )

      settle_receive({:slack_request, _conn})
      settle_refute_receive({:slack_request, _conn}, 50)
      assert receipt["outcome"] == "decode_error"
      assert receipt["typed_reason"] == "decode_error"
      assert receipt["canonical_page_sha256"] == nil
      assert receipt["message_count"] == nil
      assert exchange(receipt)["schema"] == "comma.slack-read-receipt.v2"

      assert receipt["rejection"] == %{
               "schema" => "comma.slack-read-rejection.v1",
               "stage" => @stage,
               "path" => @path,
               "unknown_keys" => []
             }

      with {http_status, request_id} <- response_id do
        assert receipt["http_status"] == http_status
        assert receipt["slack_request_id_sha256"] == CanonicalJSON.sha256(request_id)
      end

      for secret <- @secrets, do: refute(inspect(receipt) =~ secret)
    end
  end

  test "observed replies drop non-authoritative Slack structures after credential scan", %{
    base_url: base_url
  } do
    SystemsRuntime.put_env(
      :salix_im,
      :slack_receipt_test_response,
      :ordinary_non_authoritative_content
    )

    selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
    origin_sha256 = origin_sha256(base_url)

    assert {:ok, page, _chain_bytes, receipt} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256,
               slack_api_origin_sha256: origin_sha256
             )

    assert page == %{
             "messages" => [
               %{
                 "app_id" => nil,
                 "blocks" => [%{"type" => "user", "user_id" => "U_MENTIONED"}],
                 "bot_id" => nil,
                 "bot_profile_name" => nil,
                 "subtype" => nil,
                 "text" => "safe visible text",
                 "ts" => "1786693124.936679",
                 "user" => "U_ROOT"
               },
               %{
                 "app_id" => nil,
                 "blocks" => [],
                 "bot_id" => nil,
                 "bot_profile_name" => nil,
                 "subtype" => "file_share",
                 "text" => "",
                 "ts" => "1786693125.000001",
                 "user" => "U_FILE_OWNER"
               }
             ],
             "next_cursor" => ""
           }

    page_bytes = CanonicalJSON.encode!(page)
    assert receipt["canonical_page_sha256"] == CanonicalJSON.sha256(page_bytes)
    assert receipt["message_count"] == 2
    assert receipt["transport_invocation_count"] == 1
    assert receipt["retry"] == false
    assert receipt["redirect"] == false

    Enum.each(
      [
        "private attachment",
        "private file",
        "F_PRIVATE",
        "private root",
        "U_PRIVATE_ROOT",
        "private-section",
        "private section",
        "private-divider",
        "U_PRIVATE_AUTHOR",
        "C_PRIVATE",
        "private linked",
        "private.example.invalid"
      ],
      &refute(String.contains?(page_bytes, &1))
    )
  end

  test "observed selector, origin, and option drift all fail before transport", %{
    base_url: base_url
  } do
    selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
    origin_sha256 = origin_sha256(base_url)

    common = [
      receipt: :return,
      limit: 200,
      request_selector_sha256: selector_sha256,
      slack_api_origin_sha256: origin_sha256
    ]

    assert {:error, :invalid_slack_read_receipt_request} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_OTHER",
               "1786693124.936679",
               common
             )

    assert {:error, :invalid_slack_read_origin} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               Keyword.put(common, :slack_api_origin_sha256, String.duplicate("0", 64))
             )

    assert {:error, :invalid_slack_read_receipt_request} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               Keyword.put(common, :cursor, "next-private-cursor")
             )

    settle_refute_receive({:slack_request, _conn}, 50)
  end

  test "observed replies returns the exact page and one closed causal receipt", %{
    base_url: base_url
  } do
    selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
    origin_sha256 = origin_sha256(base_url)

    assert {:ok, page, chain_bytes, receipt} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256,
               slack_api_origin_sha256: origin_sha256
             )

    settle_receive({:slack_request, conn})
    assert conn.method == "GET"
    assert conn.request_path == "/api/conversations.replies"

    assert conn.query_params == %{
             "channel" => "C_THREAD",
             "limit" => "15",
             "ts" => "1786693124.936679"
           }

    assert get_req_header(conn, "authorization") == ["Bearer xoxb-private-token"]

    assert page == %{
             "messages" => [
               %{
                 "app_id" => nil,
                 "blocks" => [],
                 "bot_id" => nil,
                 "bot_profile_name" => nil,
                 "subtype" => nil,
                 "text" => "root",
                 "ts" => "1786693124.936679",
                 "user" => "U_ROOT"
               },
               %{
                 "app_id" => nil,
                 "blocks" => [],
                 "bot_id" => nil,
                 "bot_profile_name" => nil,
                 "subtype" => nil,
                 "text" => "reply",
                 "ts" => "1786693130.000001",
                 "user" => "U_REPLY"
               }
             ],
             "next_cursor" => ""
           }

    page_sha256 = page |> CanonicalJSON.encode!() |> CanonicalJSON.sha256()

    assert chain_bytes ==
             CanonicalJSON.encode!(%{
               "schema" => "comma.slack-read-page-chain.v1",
               "pages" => [page]
             })

    assert receipt == %{
             "schema" => "comma.slack-read-receipt-chain.v1",
             "operation" => "conversations.replies",
             "method" => "GET",
             "request_selector_sha256" => selector_sha256,
             "slack_api_origin_sha256" => origin_sha256,
             "transport_invocation_count" => 1,
             "page_budget" => 14,
             "retry" => false,
             "redirect" => false,
             "outcome" => "success",
             "typed_reason" => nil,
             "http_status" => 200,
             "canonical_page_sha256" => page_sha256,
             "message_count" => 2,
             "next_cursor_empty" => true,
             "canonical_page_chain_sha256" => CanonicalJSON.sha256(chain_bytes),
             "rejection" => nil,
             "slack_request_id_sha256" => CanonicalJSON.sha256("req-success-1"),
             "exchanges" => [
               %{
                 "schema" => "comma.slack-read-receipt.v1",
                 "operation" => "conversations.replies",
                 "method" => "GET",
                 "request_selector_sha256" =>
                   page_selector_sha256("C_THREAD", "1786693124.936679", ""),
                 "slack_api_origin_sha256" => origin_sha256,
                 "transport_invocation_count" => 1,
                 "retry" => false,
                 "redirect" => false,
                 "outcome" => "success",
                 "typed_reason" => nil,
                 "http_status" => 200,
                 "canonical_page_sha256" => page_sha256,
                 "message_count" => 2,
                 "next_cursor_empty" => true,
                 "slack_request_id_sha256" => CanonicalJSON.sha256("req-success-1")
               }
             ]
           }

    receipt_text = inspect(receipt)
    refute receipt_text =~ "xoxb-private-token"
    refute receipt_text =~ "C_THREAD"
    refute receipt_text =~ "1786693124.936679"
    refute receipt_text =~ "U_ROOT"
  end

  test "a multi-page observed read binds every exchange into one ordered proof chain", %{
    base_url: base_url
  } do
    SystemsRuntime.put_env(:salix_im, :slack_receipt_test_response, {:pages, 3})
    selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
    origin_sha256 = origin_sha256(base_url)

    assert {:ok, page, chain_bytes, receipt} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256,
               slack_api_origin_sha256: origin_sha256
             )

    cursors =
      for _ <- 1..3 do
        settle_receive({:slack_request, conn})
        assert conn.query_params["limit"] == "15"
        conn.query_params["cursor"]
      end

    settle_refute_receive({:slack_request, _conn}, 50)
    assert cursors == [nil, "2", "3"]

    # Slack repeats the thread parent on every replies page; the merged page
    # keeps it exactly once and every reply exactly once, in order.
    assert Enum.map(page["messages"], & &1["text"]) == [
             "root",
             "reply 1",
             "reply 2",
             "reply 3"
           ]

    assert page["next_cursor"] == ""

    assert receipt["schema"] == "comma.slack-read-receipt-chain.v1"
    assert receipt["outcome"] == "success"
    assert receipt["transport_invocation_count"] == 3
    assert receipt["message_count"] == 4
    assert receipt["next_cursor_empty"] == true
    assert receipt["request_selector_sha256"] == selector_sha256

    assert receipt["canonical_page_sha256"] ==
             page |> CanonicalJSON.encode!() |> CanonicalJSON.sha256()

    assert [first, second, third] = receipt["exchanges"]
    assert Enum.map([first, second, third], & &1["next_cursor_empty"]) == [false, false, true]
    assert Enum.map([first, second, third], & &1["message_count"]) == [2, 2, 2]

    assert Enum.map([first, second, third], & &1["slack_request_id_sha256"]) ==
             Enum.map(1..3, &CanonicalJSON.sha256("req-page-#{&1}"))

    # Each exchange binds its own physical, cursor-anchored selector; the chain
    # binds the one logical selector the identity fence pinned.
    assert Enum.map([first, second, third], & &1["request_selector_sha256"]) ==
             Enum.map(["", "2", "3"], &page_selector_sha256("C_THREAD", "1786693124.936679", &1))

    refute selector_sha256 in Enum.map([first, second, third], & &1["request_selector_sha256"])

    assert {:ok, %{"schema" => "comma.slack-read-page-chain.v1", "pages" => pages}} =
             Jason.decode(chain_bytes)

    assert CanonicalJSON.sha256(chain_bytes) == receipt["canonical_page_chain_sha256"]
    assert length(pages) == 3

    assert Enum.map(pages, &(&1 |> CanonicalJSON.encode!() |> CanonicalJSON.sha256())) ==
             Enum.map([first, second, third], & &1["canonical_page_sha256"])

    assert Enum.map(pages, & &1["next_cursor"]) == ["2", "3", ""]
  end

  defp exchange(receipt) do
    assert receipt["schema"] == "comma.slack-read-receipt-chain.v1"
    assert [only] = receipt["exchanges"]
    only
  end

  defp page_selector_sha256(channel_id, thread_ts, cursor) do
    %{
      "operation" => "conversations.replies",
      "channel_id" => channel_id,
      "thread_ts" => thread_ts,
      "limit" => 15,
      "cursor" => cursor
    }
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end

  defp selector_sha256(channel_id, thread_ts) do
    %{
      "operation" => "conversations.replies",
      "channel_id" => channel_id,
      "thread_ts" => thread_ts,
      "limit" => 200,
      "cursor" => ""
    }
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end

  defp origin_sha256(base_url) do
    uri = URI.parse(base_url)

    %{
      "scheme" => uri.scheme,
      "host" => uri.host,
      "port" => uri.port,
      "base_path" => uri.path
    }
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
