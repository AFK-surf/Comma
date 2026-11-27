defmodule Salix.Bindings.DailyBriefPersonalSourceTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.DailyBriefPersonalSource, as: Source

  defmodule SlackStub do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      [token] = get_req_header(conn, "authorization")
      owner = SystemsRuntime.fetch_env!(:salix_web, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:slack, conn.request_path, token})
      fun = SystemsRuntime.fetch_env!(:salix_web, :daily_brief_test_slack)
      search = SystemsRuntime.get_env(:salix_web, :daily_brief_test_search)

      body =
        cond do
          conn.request_path == "/api/search.messages" and is_function(search, 1) ->
            search.(conn.query_params)

          conn.request_path == "/api/search.messages" and is_function(fun, 2) ->
            %{
              "ok" => true,
              "messages" => %{"matches" => [], "paging" => %{"page" => 1, "pages" => 1}}
            }

          is_function(fun, 2) ->
            fun.(conn.request_path, conn.query_params)

          true ->
            fun.(conn.request_path)
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  @owner %{"org_id" => "org-1", "member_id" => "member-1", "user_id" => "user-1"}

  setup do
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_base = SystemsRuntime.get_env(:salix_im, :slack_api_base_url)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_web, :daily_brief_test_owner, SystemsRuntime.Proc.self())

    bandit =
      start_supervised!(
        {Bandit, plug: SlackStub, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)

      if prev_base,
        do: SystemsRuntime.put_env(:salix_im, :slack_api_base_url, prev_base),
        else: SystemsRuntime.delete_env(:salix_im, :slack_api_base_url)

      SystemsRuntime.delete_env(:salix_web, :daily_brief_test_owner)
      SystemsRuntime.delete_env(:salix_web, :daily_brief_test_slack)
      SystemsRuntime.delete_env(:salix_web, :daily_brief_test_search)
    end)

    :ok =
      SalixStore.OAuth.put("conn-1", %{
        "connection_id" => "conn-1",
        "tenant" => "tenant-1",
        "provider" => "slack",
        "bft_member" => @owner,
        "access_token" => "xoxp-member",
        "slack_user_token" => "xoxp-member",
        "provider_account_id" => "UALICE1",
        "metadata" => %{"metadata" => %{"authed_user_id" => "UALICE1", "team_id" => "T1"}},
        "status" => "active"
      })

    :ok
  end

  test "reads every direct and group direct conversation's history in the window" do
    stub(fn
      "/api/users.conversations", _params ->
        %{
          "ok" => true,
          "channels" => [
            %{"id" => "D1", "is_im" => true, "user" => "UBOB1"},
            %{"id" => "C9", "is_mpim" => true, "name" => "mpdm-a--b-1"},
            %{"id" => "D2", "is_im" => true, "user" => "UQUIET1"}
          ],
          "response_metadata" => %{"next_cursor" => ""}
        }

      "/api/conversations.history", %{"channel" => "D1"} = params ->
        assert params["oldest"] == "1786929000.000000"
        assert params["latest"] == "1786940000.000000"

        %{
          "ok" => true,
          "messages" => [
            %{"ts" => "1786930000.000100", "user" => "UBOB1", "text" => "can you look?"},
            %{
              "ts" => "1786930000.000300",
              "user" => "UAPP1",
              "bot_id" => "B1",
              "text" => "an app's note"
            }
          ],
          "response_metadata" => %{"next_cursor" => ""}
        }

      "/api/conversations.history", %{"channel" => "C9"} ->
        %{
          "ok" => true,
          "messages" => [
            %{
              "ts" => "1786930100.000200",
              "thread_ts" => "1786930000.000900",
              "user" => "UCAROL1",
              "text" => "in a thread"
            }
          ],
          "response_metadata" => %{"next_cursor" => ""}
        }

      "/api/conversations.history", %{"channel" => "D2"} ->
        %{"ok" => true, "messages" => [], "response_metadata" => %{"next_cursor" => ""}}
    end)

    assert {:ok, %{messages: [direct, app, group], complete?: true}} =
             Source.direct_messages(
               Map.merge(request(), %{
                 after_us: 1_786_929_000_000_000,
                 before_us: 1_786_940_000_000_000
               })
             )

    assert %{channel_id: "D1", kind: "im", author: "UBOB1", text: "can you look?", bot?: false} =
             direct

    # An app posts as its bot user; it is still a bot.
    assert %{author: "UAPP1", bot?: true} = app
    assert %{channel_id: "C9", kind: "mpim", thread_ts: "1786930000.000900"} = group
    assert_received {:slack, "/api/users.conversations", "Bearer xoxp-member"}
  end

  test "reads the member's own messages in channels shared with another company" do
    stub(fn
      "/api/users.conversations", _params ->
        %{"ok" => true, "channels" => [], "response_metadata" => %{"next_cursor" => ""}}
    end)

    shared = %{
      "id" => "CEXT1",
      "name" => "pm-tool",
      "is_channel" => true,
      "is_ext_shared" => true
    }

    team = %{"id" => "CTEAM1", "name" => "general", "is_channel" => true}

    SystemsRuntime.put_env(:salix_web, :daily_brief_test_search, fn params ->
      assert params["query"] == "from:<@UALICE1> after:2026-08-16 before:2026-08-18"

      %{
        "ok" => true,
        "messages" => %{
          "matches" => [
            %{
              "ts" => "1786930200.000100",
              "user" => "UALICE1",
              "text" => "agents need a CLI too",
              "channel" => shared,
              "permalink" =>
                "https://x.slack.com/archives/CEXT1/p1786930200000100?thread_ts=1786930000.000100&cid=CEXT1"
            },
            # The bot reads the team's own channels; search does not add them.
            %{
              "ts" => "1786930300.000100",
              "user" => "UALICE1",
              "text" => "hi",
              "channel" => team
            },
            # Search takes whole days: a message before the window is cut.
            %{
              "ts" => "1786920000.000100",
              "user" => "UALICE1",
              "text" => "old",
              "channel" => shared
            }
          ],
          "paging" => %{"page" => 1, "pages" => 1}
        }
      }
    end)

    assert {:ok, %{messages: [message], complete?: true}} =
             Source.direct_messages(
               Map.merge(request(), %{
                 after_us: 1_786_929_000_000_000,
                 before_us: 1_786_940_000_000_000
               })
             )

    assert %{
             channel_id: "CEXT1",
             channel_name: "pm-tool",
             kind: "shared",
             author: "UALICE1",
             thread_ts: "1786930000.000100",
             text: "agents need a CLI too"
           } = message
  end

  test "a conversation Slack refuses is left out and the read marked partial" do
    stub(fn
      "/api/users.conversations", _params ->
        %{
          "ok" => true,
          "channels" => [%{"id" => "D1", "is_im" => true}, %{"id" => "D2", "is_im" => true}],
          "response_metadata" => %{"next_cursor" => ""}
        }

      "/api/conversations.history", %{"channel" => "D1"} ->
        %{"ok" => false, "error" => "channel_not_found"}

      "/api/conversations.history", %{"channel" => "D2"} ->
        %{
          "ok" => true,
          "messages" => [%{"ts" => "1.000100", "user" => "UBOB1", "text" => "hi"}],
          "response_metadata" => %{"next_cursor" => ""}
        }
    end)

    assert {:ok, %{messages: [%{channel_id: "D2"}], complete?: false}} =
             Source.direct_messages(window(request()))
  end

  test "the Slackbot direct message is not read and leaves the read complete" do
    stub(fn
      "/api/users.conversations", _params ->
        %{
          "ok" => true,
          "channels" => [
            %{"id" => "D1", "is_im" => true, "user" => "USLACKBOT"},
            %{"id" => "D2", "is_im" => true, "user" => "UBOB1"}
          ],
          "response_metadata" => %{"next_cursor" => ""}
        }

      "/api/conversations.history", %{"channel" => "D1"} ->
        %{"ok" => false, "error" => "channel_not_found"}

      "/api/conversations.history", %{"channel" => "D2"} ->
        %{
          "ok" => true,
          "messages" => [%{"ts" => "1.000100", "user" => "UBOB1", "text" => "hi"}],
          "response_metadata" => %{"next_cursor" => ""}
        }
    end)

    assert {:ok, %{messages: [%{channel_id: "D2"}], complete?: true}} =
             Source.direct_messages(window(request()))
  end

  test "refuses a grant owned by someone else or from another Slack user" do
    stub(fn _path -> %{"ok" => true, "channels" => [], "response_metadata" => %{}} end)

    other = %{
      request()
      | bft_member: %{org_id: "org-1", member_id: "member-2", user_id: "user-2"}
    }

    assert Source.direct_messages(window(other)) == {:error, :grant_revoked}

    assert Source.direct_messages(window(%{request() | slack_user_id: "UOTHER1"})) ==
             {:error, :grant_revoked}

    assert Source.direct_messages(window(%{request() | tenant_id: "tenant-2"})) ==
             {:error, :grant_revoked}

    refute_received {:slack, _path, _token}
  end

  test "reports a token Slack rejects as revoked and marks the grant for reconnecting" do
    stub(fn _path -> %{"ok" => false, "error" => "token_revoked"} end)

    assert Source.direct_messages(window(request())) == {:error, :grant_revoked}
    assert {:ok, %{"status" => "reauthorization_required"}} = SalixStore.OAuth.get("conn-1")
  end

  defp request,
    do: %{
      tenant_id: "tenant-1",
      connection_id: "conn-1",
      slack_user_id: "UALICE1",
      bft_member: %{org_id: "org-1", member_id: "member-1", user_id: "user-1"}
    }

  defp window(request), do: Map.merge(request, %{after_us: 1, before_us: 2_000_000})

  defp stub(fun), do: SystemsRuntime.put_env(:salix_web, :daily_brief_test_slack, fun)
end
