defmodule SalixIM.SlackObservedReadReceiptTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias SalixIM.Provider.Slack.API
  alias SalixIM.TestSupport.BanditServer
  alias SalixIM.Triage.CanonicalJSON

  defmodule SlackLoopback do
    use Plug.Builder

    plug(:dispatch)

    defp dispatch(conn, _opts) do
      conn = fetch_query_params(conn)
      send(Application.fetch_env!(:salix_im, :slack_receipt_test_owner), {:slack_request, conn})

      case Application.get_env(:salix_im, :slack_receipt_test_response, :success) do
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
          Process.sleep(delay_ms)

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

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    :ok = SalixStore.S3.Fake.reset()

    previous_base_url = Application.get_env(:salix_im, :slack_api_base_url)
    previous_owner = Application.get_env(:salix_im, :slack_receipt_test_owner)
    previous_response = Application.get_env(:salix_im, :slack_receipt_test_response)
    Application.put_env(:salix_im, :slack_receipt_test_owner, self())
    Application.put_env(:salix_im, :slack_receipt_test_response, :success)

    port = BanditServer.start!(fn port -> {Bandit, plug: SlackLoopback, port: port} end)
    base_url = "http://127.0.0.1:#{port}/api"
    Application.put_env(:salix_im, :slack_api_base_url, base_url)

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
    Application.put_env(:salix_im, :slack_receipt_test_response, :slack_error)
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

    assert_receive {:slack_request, _conn}
    refute_receive {:slack_request, _conn}, 50

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

  test "observed rate limit returns one closed attempted receipt without retry details", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :rate_limited)
    selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
    origin_sha256 = origin_sha256(base_url)

    assert {:error, :rate_limited, receipt} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256,
               slack_api_origin_sha256: origin_sha256
             )

    assert_receive {:slack_request, _conn}
    refute_receive {:slack_request, _conn}, 50
    assert receipt["outcome"] == "rate_limited"
    assert receipt["typed_reason"] == "rate_limited"
    assert receipt["http_status"] == 429
    assert receipt["canonical_page_sha256"] == nil
    assert receipt["message_count"] == nil
    assert receipt["next_cursor_empty"] == nil
    assert receipt["slack_request_id_sha256"] == CanonicalJSON.sha256("req-rate-limited-1")

    receipt_text = inspect(receipt)
    refute receipt_text =~ "private-rate-limit"
    refute Map.has_key?(receipt, "retry_after")
  end

  test "observed HTTP error does not follow redirects and returns one closed receipt", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :redirect)
    selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
    origin_sha256 = origin_sha256(base_url)

    assert {:error, :http_error, receipt} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256,
               slack_api_origin_sha256: origin_sha256
             )

    assert_receive {:slack_request, conn}
    assert conn.request_path == "/api/conversations.replies"
    refute_receive {:slack_request, _conn}, 50
    assert receipt["outcome"] == "http_error"
    assert receipt["typed_reason"] == "http_error"
    assert receipt["http_status"] == 302
    assert receipt["slack_request_id_sha256"] == CanonicalJSON.sha256("req-http-error-1")

    receipt_text = inspect(receipt)
    refute receipt_text =~ "private-U-redirect"
    refute receipt_text =~ "private redirect body"
  end

  test "observed decode failure returns one closed receipt without malformed bytes", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :invalid_json)
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

    assert_receive {:slack_request, _conn}
    refute_receive {:slack_request, _conn}, 50
    assert receipt["outcome"] == "decode_error"
    assert receipt["typed_reason"] == "decode_error"
    assert exchange(receipt)["schema"] == "comma.slack-read-receipt.v2"

    assert receipt["rejection"] == %{
             "schema" => "comma.slack-read-rejection.v1",
             "stage" => "json_decode",
             "path" => "response",
             "unknown_keys" => []
           }

    assert receipt["http_status"] == 200
    assert receipt["slack_request_id_sha256"] == CanonicalJSON.sha256("req-decode-error-1")
    refute inspect(receipt) =~ "private-U-broken"
  end

  test "observed transport failure returns one closed receipt without retry", %{
    base_url: _base_url
  } do
    port = unused_port()
    unavailable_base_url = "http://127.0.0.1:#{port}/api"
    Application.put_env(:salix_im, :slack_api_base_url, unavailable_base_url)
    selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
    origin_sha256 = origin_sha256(unavailable_base_url)

    assert {:error, :transport_error, receipt} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256,
               slack_api_origin_sha256: origin_sha256
             )

    refute_receive {:slack_request, _conn}, 50
    assert receipt["outcome"] == "transport_error"
    assert receipt["typed_reason"] == "transport_error"
    assert receipt["http_status"] == nil
    assert receipt["canonical_page_sha256"] == nil
    assert receipt["slack_request_id_sha256"] == nil
    refute Map.has_key?(receipt, "url")
    refute Map.has_key?(receipt, "transport_error")
  end

  test "observed decoded body with an invalid page shape returns decode error", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :invalid_shape)
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

    assert_receive {:slack_request, _conn}
    refute_receive {:slack_request, _conn}, 50
    assert receipt["outcome"] == "decode_error"
    assert receipt["typed_reason"] == "decode_error"
    assert exchange(receipt)["schema"] == "comma.slack-read-receipt.v2"

    assert receipt["rejection"] == %{
             "schema" => "comma.slack-read-rejection.v1",
             "stage" => "response_shape",
             "path" => "response",
             "unknown_keys" => []
           }

    assert receipt["http_status"] == 200
    assert receipt["slack_request_id_sha256"] == CanonicalJSON.sha256("req-shape-error-1")
    refute inspect(receipt) =~ "private-U-not-a-list"
  end

  test "observed replies reject credential-shaped message content before page persistence", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :unsafe_message)
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

    assert_receive {:slack_request, _conn}
    refute_receive {:slack_request, _conn}, 50
    assert receipt["outcome"] == "decode_error"
    assert exchange(receipt)["schema"] == "comma.slack-read-receipt.v2"

    assert receipt["rejection"] == %{
             "schema" => "comma.slack-read-rejection.v1",
             "stage" => "credential_material",
             "path" => "messages[]",
             "unknown_keys" => []
           }

    assert receipt["canonical_page_sha256"] == nil
    assert receipt["message_count"] == nil

    refute inspect(receipt) =~ "safe visible text"
    refute inspect(receipt) =~ "private-metadata-credential"
  end

  test "observed replies allow and drop ordinary message metadata", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :unknown_message_key)
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

    assert_receive {:slack_request, _conn}
    refute_receive {:slack_request, _conn}, 50
    assert exchange(receipt)["schema"] == "comma.slack-read-receipt.v1"

    assert page == %{
             "messages" => [
               %{
                 "app_id" => nil,
                 "blocks" => [],
                 "bot_id" => nil,
                 "bot_profile_name" => nil,
                 "subtype" => nil,
                 "text" => "safe visible text",
                 "ts" => "1786693124.936679",
                 "user" => "U_ROOT"
               }
             ],
             "next_cursor" => ""
           }

    refute inspect(page) =~ "metadata"
    refute inspect(page) =~ "harmless amber private sentinel"
    refute inspect(receipt) =~ "metadata"
    refute inspect(receipt) =~ "harmless amber private sentinel"
  end

  test "observed replies preserve human authorship for user-owned uploads", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :user_attributed_upload)
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
                 "actor_kind" => "human",
                 "app_id" => "A_USER_SCOPED_CLIENT",
                 "blocks" => [],
                 "bot_id" => "B_UPLOAD_TRANSPORT",
                 "bot_profile_name" => nil,
                 "subtype" => nil,
                 "text" => "user-owned upload",
                 "ts" => "1786693124.936679",
                 "user" => "U_FILE_OWNER"
               }
             ],
             "next_cursor" => ""
           }

    refute inspect(page) =~ "F_PRIVATE"
    refute inspect(receipt) =~ "F_PRIVATE"
  end

  test "observed replies retain only the closed message projection from ordinary Slack extras", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :ordinary_extras)
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
                 "app_id" => "A_BFT",
                 "blocks" => [%{"type" => "user", "user_id" => "U_HUMAN"}],
                 "bot_id" => "B_BFT",
                 "bot_profile_name" => "BFT (staging)",
                 "subtype" => nil,
                 "text" => "hello <@U_HUMAN>",
                 "ts" => "1786693130.000001",
                 "user" => nil,
                 "reactions" => [%{"name" => "eyes", "count" => 1}]
               }
             ],
             "next_cursor" => ""
           }

    page_bytes = CanonicalJSON.encode!(page)
    assert receipt["canonical_page_sha256"] == CanonicalJSON.sha256(page_bytes)

    Enum.each(
      [
        "T_DROP",
        "client-drop",
        "1786693999.999999",
        "B_DROP",
        "drop-block-id",
        "example.invalid",
        "U_DROP"
      ],
      &refute(String.contains?(page_bytes, &1))
    )
  end

  test "observed replies accept Slack's optional boolean metadata on rich-text links", %{
    base_url: base_url
  } do
    Application.put_env(
      :salix_im,
      :slack_receipt_test_response,
      {:json_body, "req-truncated-link-1",
       %{
         "ok" => true,
         "messages" => [
           %{
             "text" => "see the linked context <@U_HUMAN>",
             "ts" => "1786693130.000001",
             "user" => "U_ROOT",
             "blocks" => [
               %{
                 "type" => "rich_text",
                 "elements" => [
                   %{
                     "type" => "rich_text_section",
                     "elements" => [
                       %{
                         "type" => "link",
                         "url" => "https://example.invalid/long-context",
                         "text" => "linked context",
                         "truncated" => true,
                         "from_llm" => true,
                         "is_slack_url" => false,
                         "unsafe" => false
                       },
                       %{"type" => "user", "user_id" => "U_HUMAN"}
                     ]
                   }
                 ]
               }
             ]
           }
         ],
         "response_metadata" => %{"next_cursor" => ""}
       }}
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

    assert page["messages"] == [
             %{
               "app_id" => nil,
               "blocks" => [%{"type" => "user", "user_id" => "U_HUMAN"}],
               "bot_id" => nil,
               "bot_profile_name" => nil,
               "subtype" => nil,
               "text" => "see the linked context <@U_HUMAN>",
               "ts" => "1786693130.000001",
               "user" => "U_ROOT"
             }
           ]

    refute inspect(page) =~ "truncated"
    refute inspect(page) =~ "from_llm"
    refute inspect(page) =~ "is_slack_url"
    refute inspect(page) =~ "unsafe"
    refute inspect(receipt) =~ "example.invalid"
  end

  test "observed replies validate and drop Slack message presentation blocks", %{
    base_url: base_url
  } do
    display_only_sentinel = "display-only-private-sentinel"

    blocks = [
      %{"type" => "divider", "block_id" => "divider-1"},
      %{
        "type" => "section",
        "block_id" => "section-1",
        "text" => %{"type" => "mrkdwn", "text" => display_only_sentinel},
        "expand" => true
      },
      %{
        "type" => "header",
        "block_id" => "header-1",
        "level" => 2,
        "text" => %{"type" => "plain_text", "text" => display_only_sentinel}
      },
      %{"type" => "markdown", "block_id" => "markdown-1", "text" => display_only_sentinel},
      %{
        "type" => "table",
        "block_id" => "table-1",
        "rows" => [[%{"type" => "raw_text", "text" => display_only_sentinel}]],
        "column_settings" => []
      },
      %{
        "type" => "actions",
        "block_id" => "actions-1",
        "elements" => [%{"type" => "button", "action_id" => "display-only-action"}]
      },
      %{
        "type" => "context",
        "block_id" => "context-1",
        "elements" => [%{"type" => "mrkdwn", "text" => display_only_sentinel}]
      },
      %{
        "type" => "image",
        "block_id" => "image-1",
        "image_url" => "https://example.invalid/display-only.png",
        "alt_text" => display_only_sentinel
      },
      %{
        "type" => "card",
        "block_id" => "card-1",
        "body" => %{"type" => "mrkdwn", "text" => display_only_sentinel},
        "subtext" => %{"type" => "plain_text", "text" => display_only_sentinel}
      },
      %{
        "type" => "container",
        "block_id" => "container-1",
        "width" => "standard",
        "title" => %{"type" => "plain_text", "text" => display_only_sentinel},
        "child_blocks" => [%{"type" => "context", "elements" => []}],
        "has_header_divider" => true
      },
      %{
        "type" => "plan",
        "block_id" => "plan-1",
        "title" => display_only_sentinel,
        "tasks" => [
          %{"task_id" => "display-only-plan-task", "title" => "Plan task", "status" => "pending"}
        ]
      },
      %{
        "type" => "task_card",
        "block_id" => "task-card-1",
        "task_id" => "display-only-task",
        "title" => "Task title",
        "status" => "complete",
        "output" => %{
          "type" => "rich_text",
          "elements" => [
            %{
              "type" => "rich_text_section",
              "elements" => [%{"type" => "text", "text" => display_only_sentinel}]
            }
          ]
        }
      },
      %{
        "type" => "rich_text",
        "elements" => [
          %{
            "type" => "rich_text_section",
            "elements" => [%{"type" => "user", "user_id" => "U_HUMAN"}]
          }
        ]
      }
    ]

    Application.put_env(
      :salix_im,
      :slack_receipt_test_response,
      {:json_body, "req-display-blocks-1",
       %{
         "ok" => true,
         "messages" => [
           %{
             "text" => "human summary <@U_HUMAN>",
             "ts" => "1786693130.000001",
             "user" => "U_ROOT",
             "blocks" => blocks
           }
         ],
         "response_metadata" => %{"next_cursor" => ""}
       }}
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

    assert get_in(page, ["messages", Access.at(0), "blocks"]) == [
             %{"type" => "user", "user_id" => "U_HUMAN"}
           ]

    refute inspect(page) =~ display_only_sentinel
    refute inspect(page) =~ "display-only-task"
    refute inspect(receipt) =~ display_only_sentinel
    refute inspect(receipt) =~ "display-only-task"
  end

  test "observed replies still reject credentials nested in dropped attachment structures", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :forbidden_attachment)
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

    assert receipt["canonical_page_sha256"] == nil
    assert exchange(receipt)["schema"] == "comma.slack-read-receipt.v2"

    assert receipt["rejection"] == %{
             "schema" => "comma.slack-read-rejection.v1",
             "stage" => "credential_material",
             "path" => "messages[]",
             "unknown_keys" => []
           }

    refute inspect(receipt) =~ "private-attachment-credential"
  end

  test "observed replies drop non-authoritative Slack structures after credential scan", %{
    base_url: base_url
  } do
    Application.put_env(
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

  test "observed replies reject duplicate Slack timestamps before page commit", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :duplicate_timestamps)
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

    assert receipt["canonical_page_sha256"] == nil
    assert receipt["message_count"] == nil
    assert exchange(receipt)["schema"] == "comma.slack-read-receipt.v2"

    assert receipt["rejection"] == %{
             "schema" => "comma.slack-read-rejection.v1",
             "stage" => "duplicate_timestamps",
             "path" => "messages",
             "unknown_keys" => []
           }
  end

  test "observed decode rejection uses the exact closed stage and path taxonomy", %{
    base_url: base_url
  } do
    base_message = %{
      "text" => "safe visible text",
      "ts" => "1786693124.936679",
      "user" => "U_ROOT"
    }

    cases = [
      {"message_field_shape", "messages[].ts", [], Map.put(base_message, "ts", 123)},
      {"bot_profile_unknown_keys", "messages[].bot_profile", ["metadata"],
       Map.put(base_message, "bot_profile", %{"name" => "BFT", "metadata" => "private"})},
      {"bot_profile_shape", "messages[].bot_profile", [],
       Map.put(base_message, "bot_profile", %{"name" => 123})},
      {"rich_text_unknown_keys", "messages[].blocks[]", ["metadata"],
       Map.put(base_message, "blocks", [
         %{"type" => "rich_text", "elements" => [], "metadata" => "private"}
       ])},
      {"rich_text_shape", "messages[].blocks", [], Map.put(base_message, "blocks", %{})},
      {"rich_text_shape", "messages[].blocks[]", [],
       Map.put(base_message, "blocks", [
         %{
           "type" => "rich_text",
           "elements" => [
             %{
               "type" => "rich_text_quote",
               "contains_padding" => "true",
               "elements" => []
             }
           ]
         }
       ])},
      {"rich_text_shape", "messages[].blocks[]", [],
       Map.put(base_message, "blocks", [
         %{
           "type" => "rich_text",
           "elements" => [
             %{
               "type" => "rich_text_section",
               "elements" => [
                 %{
                   "type" => "link",
                   "url" => "https://example.invalid/context",
                   "truncated" => "true"
                 }
               ]
             }
           ]
         }
       ])},
      {"rich_text_shape", "messages[].blocks[]", [],
       rich_text_link_message(base_message, "from_llm", "true")},
      {"rich_text_shape", "messages[].blocks[]", [],
       rich_text_link_message(base_message, "is_slack_url", "false")},
      {"rich_text_shape", "messages[].blocks[]", [],
       rich_text_link_message(base_message, "unsafe", 0)},
      {"rich_text_shape", "messages[].blocks[]", [],
       Map.put(base_message, "blocks", [
         %{
           "type" => "task_card",
           "task_id" => "task-1",
           "title" => "Task",
           "status" => "finished"
         }
       ])},
      {"unsafe_unknown_key_name", "messages[]", [], Map.put(base_message, "Bad-Key", "private")},
      {"unknown_key_overflow", "messages[]", [],
       Enum.reduce(1..17, base_message, fn index, message ->
         Map.put(message, "extra_#{index}", "private")
       end)}
    ]

    selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
    origin_sha256 = origin_sha256(base_url)

    Enum.each(cases, fn {stage, path, unknown_keys, message} ->
      Application.put_env(
        :salix_im,
        :slack_receipt_test_response,
        {:json_body, "req-#{stage}",
         %{
           "ok" => true,
           "messages" => [message],
           "response_metadata" => %{"next_cursor" => ""}
         }}
      )

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

      assert_receive {:slack_request, _conn}
      refute_receive {:slack_request, _conn}, 20
      assert exchange(receipt)["schema"] == "comma.slack-read-receipt.v2"

      assert receipt["rejection"] == %{
               "schema" => "comma.slack-read-rejection.v1",
               "stage" => stage,
               "path" => path,
               "unknown_keys" => unknown_keys
             }

      receipt_text = inspect(receipt)
      refute receipt_text =~ "safe visible text"
      refute receipt_text =~ "U_ROOT"
      refute receipt_text =~ "private"
      refute receipt_text =~ "1786693124.936679"
    end)
  end

  defp rich_text_link_message(base_message, key, value) do
    Map.put(base_message, "blocks", [
      %{
        "type" => "rich_text",
        "elements" => [
          %{
            "type" => "rich_text_section",
            "elements" => [
              %{
                "type" => "link",
                "url" => "https://example.invalid/context",
                key => value
              }
            ]
          }
        ]
      }
    ])
  end

  test "unknown receipt mode fails before transport" do
    assert {:error, :invalid_slack_read_receipt_request} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :unknown
             )

    refute_receive {:slack_request, _conn}, 50
  end

  test "legacy replies mode keeps its existing tuple result and query behavior" do
    assert {messages, ""} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               limit: 37,
               inclusive: true
             )

    assert length(messages) == 2
    assert_receive {:slack_request, conn}
    assert conn.method == "GET"
    assert conn.request_path == "/api/conversations.replies"

    # The legacy tuple mode passes the caller's page size straight through; only
    # the observed chain binds its own page limit.
    assert conn.query_params == %{
             "channel" => "C_THREAD",
             "inclusive" => "true",
             "limit" => "37",
             "ts" => "1786693124.936679"
           }
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

    refute_receive {:slack_request, _conn}, 50
  end

  test "an empty observed thread selector fails before transport", %{base_url: base_url} do
    assert {:error, :invalid_slack_read_receipt_request} =
             API.conversation_replies(
               "xoxb-private-token",
               "",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256("", "1786693124.936679"),
               slack_api_origin_sha256: origin_sha256(base_url)
             )

    refute_receive {:slack_request, _conn}, 50
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

    assert_receive {:slack_request, conn}
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
    Application.put_env(:salix_im, :slack_receipt_test_response, {:pages, 3})
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
        assert_receive {:slack_request, conn}
        assert conn.query_params["limit"] == "15"
        conn.query_params["cursor"]
      end

    refute_receive {:slack_request, _conn}, 50
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

  test "an observed read that outruns the page budget settles as a bounded truncation", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, {:pages, :unbounded})
    selector_sha256 = selector_sha256("C_THREAD", "1786693124.936679")
    origin_sha256 = origin_sha256(base_url)

    assert {:error, :page_budget_exceeded, receipt} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256,
               slack_api_origin_sha256: origin_sha256
             )

    for _ <- 1..14, do: assert_receive({:slack_request, _conn})
    refute_receive {:slack_request, _conn}, 50

    assert receipt["outcome"] == "page_budget_exceeded"
    assert receipt["typed_reason"] == "page_budget_exceeded"
    assert receipt["transport_invocation_count"] == 14
    assert receipt["page_budget"] == 14
    assert length(receipt["exchanges"]) == 14
    assert receipt["canonical_page_sha256"] == nil
    assert receipt["canonical_page_chain_sha256"] == nil
    assert receipt["message_count"] == nil
    assert receipt["next_cursor_empty"] == nil

    # Every exchange succeeded; the read still refuses to hand back a partial
    # thread, so the truncation is a product boundary, not a broken transport.
    assert Enum.all?(receipt["exchanges"], &(&1["outcome"] == "success"))
    assert Enum.all?(receipt["exchanges"], &(&1["next_cursor_empty"] == false))
  end

  test "an observed page chain ignores a lease left by an older runtime", %{base_url: base_url} do
    {:ok, _held} =
      SalixStore.Lease.acquire(method_lease_key(), "old-runtime", ttl_ms: 120_000)

    Application.put_env(:salix_im, :slack_receipt_test_response, {:pages, 3})

    assert {:ok, _page, _chain_bytes, receipt} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256("C_THREAD", "1786693124.936679"),
               slack_api_origin_sha256: origin_sha256(base_url)
             )

    assert receipt["transport_invocation_count"] == 3
    # Only the old runtime's initial write: the new reader never renews it.
    assert lease_writes() == 1
  end

  # Removing the shared lock does not remove the whole-chain time bound.
  test "a stalled chain aborts on its own wall-clock deadline", %{base_url: base_url} do
    previous = Application.get_env(:salix_im, :slack_observed_chain_deadline_ms)
    Application.put_env(:salix_im, :slack_observed_chain_deadline_ms, 120)
    Application.put_env(:salix_im, :slack_receipt_test_response, {:slow_pages, 80})
    on_exit(fn -> restore_env(:salix_im, :slack_observed_chain_deadline_ms, previous) end)

    assert {:error, :chain_deadline_exceeded, receipt} =
             API.conversation_replies(
               "xoxb-private-token",
               "C_THREAD",
               "1786693124.936679",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256("C_THREAD", "1786693124.936679"),
               slack_api_origin_sha256: origin_sha256(base_url)
             )

    # The stub never exhausts its cursor, so only the deadline can stop it —
    # well before the 14-page budget.
    assert receipt["outcome"] == "chain_deadline_exceeded"
    assert receipt["transport_invocation_count"] < 14
    assert receipt["transport_invocation_count"] >= 1
  end

  test "a rate-limited observed read does not install a cooldown for another read", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, :rate_limited_beyond_window)

    read = fn ->
      API.conversation_replies(
        "xoxb-private-token",
        "C_THREAD",
        "1786693124.936679",
        receipt: :return,
        limit: 200,
        request_selector_sha256: selector_sha256("C_THREAD", "1786693124.936679"),
        slack_api_origin_sha256: origin_sha256(base_url)
      )
    end

    assert {:error, :rate_limited, receipt} = read.()
    assert receipt["transport_invocation_count"] == 1
    assert receipt["typed_reason"] == "rate_limited"
    Application.put_env(:salix_im, :slack_receipt_test_response, {:pages, 2})
    assert {:ok, _page, _chain_bytes, receipt} = read.()
    assert receipt["transport_invocation_count"] == 2
    assert lease_writes() == 0
  end

  # A merge wider than the authorized logical read is a scope the authorization
  # never covered: it settles at the existing product boundary instead of
  # silently handing back objects nobody authorized.
  test "a chain wider than the authorized logical limit settles truncated", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, {:wide_pages, 14, 15})
    selector = history_selector_sha256("C_WIDE")

    assert {:error, :page_budget_exceeded, receipt} =
             API.conversation_history("xoxb-private-token", "C_WIDE",
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector,
               slack_api_origin_sha256: origin_sha256(base_url)
             )

    assert receipt["outcome"] == "page_budget_exceeded"
    assert receipt["canonical_page_sha256"] == nil
    # 14 pages x 15 objects = 210 > the authorized 200.
    assert receipt["transport_invocation_count"] == 14
  end

  # Slack answers `conversations.replies` on a REPLY's ts with the whole thread
  # headed by its real parent. Licensing the repeat by the REQUESTED ts made
  # that legitimate read fail as `decode_error` on duplicate timestamps.
  test "replies asked about a reply ts still merge on the parent Slack returned", %{
    base_url: base_url
  } do
    Application.put_env(:salix_im, :slack_receipt_test_response, {:reply_ts_pages, 2})
    reply_ts = "1786693131.000001"

    assert {:ok, page, _chain_bytes, receipt} =
             API.conversation_replies("xoxb-private-token", "C_THREAD", reply_ts,
               receipt: :return,
               limit: 200,
               request_selector_sha256: selector_sha256("C_THREAD", reply_ts),
               slack_api_origin_sha256: origin_sha256(base_url)
             )

    assert receipt["outcome"] == "success"

    assert Enum.map(page["messages"], & &1["text"]) == [
             "real parent",
             "reply 1",
             "reply 2"
           ]
  end

  defp lease_writes,
    do: SalixStore.S3.Fake.put_log() |> Enum.count(&(&1 == method_lease_key()))

  defp history_selector_sha256(channel_id) do
    %{
      "operation" => "conversations.history",
      "channel_id" => channel_id,
      "limit" => 200,
      "cursor" => ""
    }
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp unused_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
