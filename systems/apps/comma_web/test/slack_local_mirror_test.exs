defmodule CommaWeb.SlackLocalMirrorTest do
  use Comma.DataCase, async: false

  alias CommaWeb.{RecommendationSlackMemberSource, SlackLocalMirror, SlackWebAPI}
  alias SalixStore.SlackMirrorBackfillLedger

  defmodule FakeReader do
    def replies(scope, root_ts, opts) do
      send(
        SystemsRuntime.fetch_env!(:comma_web, :slack_local_mirror_test_pid),
        {:reader_replies, scope, root_ts, opts}
      )

      {:ok,
       %{
         messages: [
           %{
             "message_ts" => root_ts,
             "thread_ts" => root_ts,
             "actor_kind" => "user",
             "actor_id" => "UOWNER",
             "text" => "I will send the report today"
           },
           %{
             "message_ts" => "1795020500.000100",
             "thread_ts" => root_ts,
             "actor_kind" => "user",
             "actor_id" => "UALICE",
             "text" => "Got it, thanks!"
           }
         ],
         next_cursor: nil,
         has_more?: false
       }}
    end

    def history(scope, opts) do
      send(
        SystemsRuntime.fetch_env!(:comma_web, :slack_local_mirror_test_pid),
        {:reader_history, scope, opts}
      )

      {:ok,
       %{
         messages: [
           %{
             "message_ts" => "1795020900.000100",
             "actor_kind" => "user",
             "actor_id" => "UOWNER",
             "text" => "Handled in channel"
           }
         ],
         next_cursor: nil,
         has_more?: false
       }}
    end

    def search(scope, opts) do
      send(
        SystemsRuntime.fetch_env!(:comma_web, :slack_local_mirror_test_pid),
        {:reader_search, scope, opts}
      )

      {:ok,
       %{
         messages: [
           %{
             "ts" => "1795021500.000200",
             "thread_ts" => "1795020900.000100",
             "user" => "UALICE",
             "text" => "Can you check this prod alert?"
           },
           %{
             "ts" => "1795020900.000100",
             "user" => "UBOT1",
             "bot_id" => "B_ALERT",
             "subtype" => "bot_message",
             "username" => "AlertBot",
             "text" => "Handled in channel"
           }
         ],
         next_cursor: nil,
         has_more?: false
       }}
    end
  end

  setup do
    prev_mirror = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_mod)
    prev_reader = SystemsRuntime.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)
    prev_pid = SystemsRuntime.get_env(:comma_web, :slack_local_mirror_test_pid)

    SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, FakeReader)
    SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, FakeReader)
    SystemsRuntime.put_env(:comma_web, :slack_local_mirror_test_pid, SystemsRuntime.Proc.self())
    SlackLocalMirror.clear_cache()

    on_exit(fn ->
      SlackLocalMirror.clear_cache()

      if is_nil(prev_mirror),
        do: SystemsRuntime.delete_env(:salix_im, :slack_message_mirror_mod),
        else: SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, prev_mirror)

      if is_nil(prev_reader),
        do: SystemsRuntime.delete_env(:salix_im, :slack_triage_clickhouse_reader_mod),
        else: SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, prev_reader)

      if is_nil(prev_pid),
        do: SystemsRuntime.delete_env(:comma_web, :slack_local_mirror_test_pid),
        else: SystemsRuntime.put_env(:comma_web, :slack_local_mirror_test_pid, prev_pid)
    end)

    :ok
  end

  test "serves covered public channel replies and history locally without hitting Slack API" do
    scope = %{
      "tenant_id" => "tnt_mirror",
      "workspace_id" => "T123",
      "channel_id" => "C_PUBLIC"
    }

    assert {:ok, _} = SlackMirrorBackfillLedger.claim_channel(scope, 60_000)
    assert :ok = SlackMirrorBackfillLedger.mark_exhausted(scope)

    replies_url =
      SlackWebAPI.url("conversations.replies", %{
        "channel" => "C_PUBLIC",
        "ts" => "1795020000.000100",
        "limit" => 15
      })

    assert {:ok, %{"ok" => true, "messages" => [first, second]}} =
             SlackLocalMirror.fetch_url("tnt_mirror", "T123", replies_url)

    assert_received {:reader_replies, ^scope, "1795020000.000100", _opts}
    assert first["user"] == "UOWNER"
    assert second["user"] == "UALICE"
    assert second["text"] == "Got it, thanks!"

    history_url =
      SlackWebAPI.url("conversations.history", %{
        "channel" => "C_PUBLIC",
        "oldest" => "1795020000.000100",
        "latest" => "1795023600",
        "limit" => 15
      })

    assert {:ok,
            %{"ok" => true, "messages" => [%{"user" => "UOWNER", "text" => "Handled in channel"}]}} =
             SlackLocalMirror.fetch_url("tnt_mirror", "T123", history_url)

    assert_received {:reader_history, ^scope, _opts}

    # Private channels, DMs, and uncovered public channels miss and fall back to Slack HTTP.
    dm_url =
      SlackWebAPI.url("conversations.replies", %{"channel" => "D_DM", "ts" => "1795020000.000100"})

    assert :miss = SlackLocalMirror.fetch_url("tnt_mirror", "T123", dm_url)

    uncovered_url =
      SlackWebAPI.url("conversations.replies", %{
        "channel" => "C_UNCOVERED",
        "ts" => "1795020000.000100"
      })

    assert :miss = SlackLocalMirror.fetch_url("tnt_mirror", "T123", uncovered_url)
  end

  test "thread_news reads covered public threads from local ClickHouse without calling conversations.replies" do
    scope = %{
      "tenant_id" => "tnt_mirror2",
      "workspace_id" => "T123",
      "channel_id" => "C_PUBLIC2"
    }

    assert {:ok, _} = SlackMirrorBackfillLedger.claim_channel(scope, 60_000)
    assert :ok = SlackMirrorBackfillLedger.mark_exhausted(scope)

    request = fn "GET", url, _opts ->
      cond do
        String.contains?(url, "auth.test") ->
          {:ok, %{"ok" => true, "user_id" => "UOWNER", "team_id" => "T123"}}

        String.contains?(url, "conversations.replies") ->
          flunk("expected covered public thread to read locally, not hit Slack HTTP: #{url}")

        true ->
          {:error, :unexpected_url}
      end
    end

    assert {:ok, %{"th1" => [%{"from" => "other", "text" => "Got it, thanks!"}]}} =
             RecommendationSlackMemberSource.thread_news(
               request,
               %{"th1" => {"C_PUBLIC2", "1795020000.000100", "1795020000.000100"}},
               tenant_id: "tnt_mirror2",
               workspace_id: "T123",
               user_id: "UOWNER",
               token_fingerprint: "fp_owner_1"
             )
  end

  test "user_name caches resolved display names per workspace and does not cache nil" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    bump = fn result ->
      fn ->
        Agent.update(counter, &(&1 + 1))
        result
      end
    end

    assert "Alice" == SlackLocalMirror.user_name("T123", "UALICE", bump.("Alice"))
    assert "Alice" == SlackLocalMirror.user_name("T123", "UALICE", bump.("ShouldNotRun"))
    assert Agent.get(counter, & &1) == 1

    assert nil == SlackLocalMirror.user_name("T123", "UMISS", bump.(nil))
    assert "Recovered" == SlackLocalMirror.user_name("T123", "UMISS", bump.("Recovered"))
    assert Agent.get(counter, & &1) == 3
  end

  test "refuses private C-prefixed channels, missing is_private, and bare C... bypasses even when exhausted" do
    priv_scope = %{
      "tenant_id" => "tnt_priv",
      "workspace_id" => "T123",
      "channel_id" => "C_PRIV"
    }

    missing_flag_scope = %{
      "tenant_id" => "tnt_priv",
      "workspace_id" => "T123",
      "channel_id" => "C_MISSING_FLAG"
    }

    assert {:ok, _} = SlackMirrorBackfillLedger.claim_channel(priv_scope, 60_000)
    assert :ok = SlackMirrorBackfillLedger.mark_exhausted(priv_scope)
    assert {:ok, _} = SlackMirrorBackfillLedger.claim_channel(missing_flag_scope, 60_000)
    assert :ok = SlackMirrorBackfillLedger.mark_exhausted(missing_flag_scope)

    SlackLocalMirror.register_channels("T123", "UOWNER", [
      %{
        "channel" => %{
          "id" => "C_PRIV",
          "name" => "secret-ops",
          "is_channel" => true,
          "is_private" => true
        },
        "permalink" => "https://acme.slack.com/archives/C_PRIV/p1795020900000100"
      },
      %{
        "channel" => %{
          "id" => "C_MISSING_FLAG",
          "name" => "ambiguous-ops",
          "is_channel" => true
        },
        "permalink" => "https://acme.slack.com/archives/C_MISSING_FLAG/p1795020900000100"
      }
    ])

    assert :miss =
             SlackLocalMirror.fetch_target_search(
               "tnt_priv",
               "T123",
               "UOWNER",
               "secret-ops",
               ~D[2026-11-18]
             )

    assert :miss =
             SlackLocalMirror.fetch_target_search(
               "tnt_priv",
               "T123",
               "UOWNER",
               "ambiguous-ops",
               ~D[2026-11-18]
             )

    # Direct C... channel ID bypass must also miss.
    assert :miss =
             SlackLocalMirror.fetch_target_search(
               "tnt_priv",
               "T123",
               "UOWNER",
               "C_PRIV",
               ~D[2026-11-18]
             )
  end

  test "isolates registered public channels per user and serves thread replies with ClickHouseReader.search/2" do
    scope = %{
      "tenant_id" => "tnt_target",
      "workspace_id" => "T123",
      "channel_id" => "C_PUB"
    }

    assert {:ok, _} = SlackMirrorBackfillLedger.claim_channel(scope, 60_000)
    assert :ok = SlackMirrorBackfillLedger.mark_exhausted(scope)

    # Pre-populate cached display name for UALICE so format_target_match fills username without HTTP.
    assert "Alice" == SlackLocalMirror.user_name("T123", "UALICE", fn -> "Alice" end)

    SlackLocalMirror.register_channels("T123", "UUSERA", [
      %{
        "channel" => %{
          "id" => "C_PUB",
          "name" => "prod-alerts",
          "is_channel" => true,
          "is_private" => false,
          "is_group" => false,
          "is_im" => false,
          "is_mpim" => false
        },
        "permalink" => "https://acme.slack.com/archives/C_PUB/p1795020900000100"
      }
    ])

    # User B must not see User A's registered channel.
    assert :miss =
             SlackLocalMirror.fetch_target_search(
               "tnt_target",
               "T123",
               "UUSERB",
               "prod-alerts",
               ~D[2026-11-18],
               limit: 20
             )

    # User A hits local ClickHouseReader.search/2 with next-day UTC boundary (after:2026-11-18 -> 2026-11-19).
    assert {:ok, [reply_match, top_match]} =
             SlackLocalMirror.fetch_target_search(
               "tnt_target",
               "T123",
               "UUSERA",
               "prod-alerts",
               ~D[2026-11-18],
               limit: 20
             )

    {:ok, next_day_dt} = DateTime.new(~D[2026-11-19], ~T[00:00:00], "Etc/UTC")
    expected_after_us = DateTime.to_unix(next_day_dt, :second) * 1_000_000

    assert_received {:reader_search, %{"tenant_id" => "tnt_target", "workspace_id" => "T123"},
                     search_opts}

    assert Keyword.get(search_opts, :channel_id) == "C_PUB"
    assert Keyword.get(search_opts, :after_date) == "2026-11-19"
    assert Keyword.get(search_opts, :after_us) == expected_after_us
    assert Keyword.get(search_opts, :sort_dir) == :desc
    assert Keyword.get(search_opts, :limit) == 20

    assert reply_match["channel"] == %{"id" => "C_PUB", "name" => "prod-alerts"}
    assert reply_match["username"] == "Alice"

    assert reply_match["permalink"] ==
             "https://acme.slack.com/archives/C_PUB/p1795021500000200?thread_ts=1795020900.000100&cid=C_PUB"

    assert top_match["channel"] == %{"id" => "C_PUB", "name" => "prod-alerts"}
    assert top_match["username"] == "AlertBot"
    assert top_match["permalink"] == "https://acme.slack.com/archives/C_PUB/p1795020900000100"
  end

  test "auth_test caches by token_fingerprint, misses on new fingerprint, and never caches bot responses" do
    {:ok, auth_calls} = Agent.start_link(fn -> 0 end)
    subject = %{"provider_user_id" => "UOWNER", "provider_workspace_id" => "T123"}

    fetcher = fn ->
      Agent.update(auth_calls, &(&1 + 1))
      {:ok, %{"ok" => true, "user_id" => "UOWNER", "team_id" => "T123"}}
    end

    assert {:ok, %{"user_id" => "UOWNER"}} =
             SlackLocalMirror.auth_test("tnt_auth", subject, "fp_1", fetcher)

    assert {:ok, %{"user_id" => "UOWNER"}} =
             SlackLocalMirror.auth_test("tnt_auth", subject, "fp_1", fetcher)

    assert Agent.get(auth_calls, & &1) == 1

    # Different token_fingerprint immediately bypasses the old cache entry.
    assert {:ok, %{"user_id" => "UOWNER"}} =
             SlackLocalMirror.auth_test("tnt_auth", subject, "fp_2", fetcher)

    assert Agent.get(auth_calls, & &1) == 2

    # Missing fingerprint never caches.
    assert {:ok, %{"user_id" => "UOWNER"}} =
             SlackLocalMirror.auth_test("tnt_auth", subject, nil, fetcher)

    assert {:ok, %{"user_id" => "UOWNER"}} =
             SlackLocalMirror.auth_test("tnt_auth", subject, "", fetcher)

    assert Agent.get(auth_calls, & &1) == 4

    # Bot responses are never cached.
    bot_fetcher = fn ->
      Agent.update(auth_calls, &(&1 + 1))
      {:ok, %{"ok" => true, "user_id" => "UOWNER", "team_id" => "T123", "bot_id" => "B123"}}
    end

    assert {:ok, %{"bot_id" => "B123"}} =
             SlackLocalMirror.auth_test("tnt_auth", subject, "fp_bot", bot_fetcher)

    assert {:ok, %{"bot_id" => "B123"}} =
             SlackLocalMirror.auth_test("tnt_auth", subject, "fp_bot", bot_fetcher)

    assert Agent.get(auth_calls, & &1) == 6
  end

  test "RecommendationSlackMemberSource.read/4 serves registered public target channels locally and falls back to Slack HTTP for private channels" do
    pub_scope = %{
      "tenant_id" => "tnt_e2e",
      "workspace_id" => "T123",
      "channel_id" => "C_PUB_E2E"
    }

    priv_scope = %{
      "tenant_id" => "tnt_e2e",
      "workspace_id" => "T123",
      "channel_id" => "C_PRIV_E2E"
    }

    assert {:ok, _} = SlackMirrorBackfillLedger.claim_channel(pub_scope, 60_000)
    assert :ok = SlackMirrorBackfillLedger.mark_exhausted(pub_scope)
    assert {:ok, _} = SlackMirrorBackfillLedger.claim_channel(priv_scope, 60_000)
    assert :ok = SlackMirrorBackfillLedger.mark_exhausted(priv_scope)

    test_pid = SystemsRuntime.Proc.self()

    request = fn "GET", url, _opts ->
      uri = URI.parse(url)
      method = Path.basename(uri.path || "")
      params = URI.decode_query(uri.query || "")

      case method do
        "auth.test" ->
          {:ok, %{"ok" => true, "user_id" => "UOWNER", "team_id" => "T123"}}

        "search.messages" ->
          query = params["query"] || ""
          send(test_pid, {:slack_search, query})

          cond do
            String.starts_with?(query, "<@UOWNER>") ->
              {:ok,
               %{
                 "ok" => true,
                 "messages" => %{
                   "matches" => [
                     %{
                       "text" => "<@UOWNER> heads up in pub",
                       "ts" => "1795020100.000100",
                       "user" => "UALICE",
                       "username" => "alice",
                       "permalink" =>
                         "https://acme.slack.com/archives/C_PUB_E2E/p1795020100000100",
                       "channel" => %{
                         "id" => "C_PUB_E2E",
                         "name" => "pub",
                         "is_channel" => true,
                         "is_private" => false
                       }
                     },
                     %{
                       "text" => "<@UOWNER> heads up in priv",
                       "ts" => "1795020101.000100",
                       "user" => "UALICE",
                       "username" => "alice",
                       "permalink" =>
                         "https://acme.slack.com/archives/C_PRIV_E2E/p1795020101000100",
                       "channel" => %{
                         "id" => "C_PRIV_E2E",
                         "name" => "priv",
                         "is_channel" => true,
                         "is_private" => true
                       }
                     }
                   ]
                 }
               }}

            String.starts_with?(query, "in:#pub ") ->
              flunk("expected verified public channel #pub to be served locally, not via HTTP")

            String.starts_with?(query, "in:#priv ") ->
              {:ok,
               %{
                 "ok" => true,
                 "messages" => %{
                   "matches" => [
                     %{
                       "text" => "Can you review the private release?",
                       "ts" => "1795021900.000100",
                       "user" => "UBOB",
                       "username" => "bob",
                       "permalink" =>
                         "https://acme.slack.com/archives/C_PRIV_E2E/p1795021900000100",
                       "channel" => %{
                         "id" => "C_PRIV_E2E",
                         "name" => "priv",
                         "is_channel" => true,
                         "is_private" => true
                       }
                     }
                   ]
                 }
               }}

            true ->
              {:ok, %{"ok" => true, "messages" => %{"matches" => []}}}
          end

        "users.info" ->
          {:ok, %{"ok" => true, "user" => %{"name" => "owner"}}}

        _ ->
          {:error, :unexpected_url}
      end
    end

    assert {:ok, %{"messages" => %{"matches" => matches}}, _subject} =
             RecommendationSlackMemberSource.read(
               request,
               ~U[2026-11-19 10:00:00Z],
               %{"provider_user_id" => "UOWNER", "provider_workspace_id" => "T123"},
               tenant_id: "tnt_e2e",
               token_fingerprint: "fp_e2e_1",
               targets: %{"channels" => ["pub", "priv"]}
             )

    # ClickHouse search was used for #pub, Slack HTTP was used for #priv.
    assert_received {:reader_search, %{"tenant_id" => "tnt_e2e", "workspace_id" => "T123"},
                     search_opts}

    assert Keyword.get(search_opts, :channel_id) == "C_PUB_E2E"
    assert_received {:slack_search, "in:#priv after:2026-11-18"}

    permalinks = Enum.map(matches, & &1["permalink"])

    assert "https://acme.slack.com/archives/C_PUB_E2E/p1795021500000200?thread_ts=1795020900.000100&cid=C_PUB_E2E" in permalinks
    assert "https://acme.slack.com/archives/C_PRIV_E2E/p1795021900000100" in permalinks
  end
end
