defmodule CommaWeb.ProactiveTriggersTest do
  use SystemsClock.Case, async: true

  alias CommaWeb.{
    Proactive,
    ProactiveMeetingPrep,
    ProactiveWatch,
    ProactiveWebRadar,
    RecommendationGoogleMemberSource,
    RecommendationOutlookMemberSource
  }

  alias SalixAgent.Tools.Web
  alias SalixStore.ProactiveKernel

  @now ~U[2026-11-25 05:40:00Z]
  @now_ms DateTime.to_unix(@now, :millisecond)

  describe "ProactiveKernel.upcoming_meetings/3" do
    test "selects non-solo confirmed meetings starting in 5..35 minutes sorted by start time" do
      events = [
        %{
          "id" => "later",
          "summary" => "Review",
          "start" => %{"dateTime" => "2026-11-25T06:05:00Z"},
          "end" => %{"dateTime" => "2026-11-25T06:35:00Z"},
          "status" => "confirmed",
          "attendeeCount" => 2
        },
        %{
          "id" => "sooner",
          "summary" => "Sync",
          "start" => %{"dateTime" => "2026-11-25T05:55:00Z"},
          "end" => %{"dateTime" => "2026-11-25T06:25:00Z"},
          "status" => "confirmed",
          "attendees" => ["Lena Wu <lena@acme.example>"]
        },
        %{
          "id" => "solo_count",
          "summary" => "Focus block",
          "start" => %{"dateTime" => "2026-11-25T05:55:00Z"},
          "end" => %{"dateTime" => "2026-11-25T06:55:00Z"},
          "status" => "confirmed",
          "attendeeCount" => 0
        },
        %{
          "id" => "solo_empty_list",
          "summary" => "Empty attendees",
          "start" => %{"dateTime" => "2026-11-25T05:55:00Z"},
          "end" => %{"dateTime" => "2026-11-25T06:55:00Z"},
          "attendees" => []
        },
        %{
          "id" => "too_soon",
          "summary" => "Starting in 2m",
          "start" => %{"dateTime" => "2026-11-25T05:42:00Z"},
          "end" => %{"dateTime" => "2026-11-25T06:12:00Z"},
          "attendeeCount" => 1
        },
        %{
          "id" => "too_far",
          "summary" => "Starting in 50m",
          "start" => %{"dateTime" => "2026-11-25T06:30:00Z"},
          "end" => %{"dateTime" => "2026-11-25T07:00:00Z"},
          "attendeeCount" => 1
        },
        %{
          "id" => "cancelled",
          "summary" => "Cancelled",
          "start" => %{"dateTime" => "2026-11-25T06:00:00Z"},
          "end" => %{"dateTime" => "2026-11-25T06:30:00Z"},
          "status" => "cancelled",
          "attendeeCount" => 2
        },
        %{
          "id" => "declined",
          "summary" => "Declined",
          "start" => %{"dateTime" => "2026-11-25T06:00:00Z"},
          "end" => %{"dateTime" => "2026-11-25T06:30:00Z"},
          "responseStatus" => "declined",
          "attendeeCount" => 2
        },
        %{
          "id" => "all_day",
          "summary" => "All day",
          "start" => %{"date" => "2026-11-25"},
          "end" => %{"date" => "2026-11-26"},
          "allDay" => true,
          "attendeeCount" => 2
        }
      ]

      selected = ProactiveKernel.upcoming_meetings(events, @now_ms)
      assert Enum.map(selected, & &1.event["id"]) == ["sooner", "later"]
      assert Enum.map(selected, & &1.starts_in_min) == [15, 25]
    end
  end

  describe "ProactiveMeetingPrep.from_events/3" do
    test "builds synthetic meeting prep candidates with attendees and timing" do
      events = [
        %{
          "id" => "evt_1",
          "summary" => "Medalsmith x Acme",
          "htmlLink" => "https://calendar.google.com/event/evt_1",
          "start" => %{"dateTime" => "2026-11-25T06:00:00Z"},
          "end" => %{"dateTime" => "2026-11-25T06:45:00Z"},
          "attendees" => ["Lena Wu <lena@acme.example>"],
          "attendeeCount" => 1,
          "description" => "Discuss 2048px export"
        },
        %{
          "id" => "evt_solo",
          "summary" => "Focus",
          "htmlLink" => "https://calendar.google.com/event/evt_solo",
          "start" => %{"dateTime" => "2026-11-25T05:55:00Z"},
          "end" => %{"dateTime" => "2026-11-25T06:55:00Z"},
          "attendees" => [],
          "attendeeCount" => 0
        }
      ]

      [candidate] = ProactiveMeetingPrep.from_events(events, @now_ms)
      assert candidate["meeting_prep"] == true
      assert candidate["relationship"] == "upcoming_meeting_prep"
      assert candidate["title"] == "Medalsmith x Acme"
      assert candidate["excerpt"] =~ "Starts in 20 minutes"
      assert candidate["excerpt"] =~ "Lena Wu <lena@acme.example>"
      assert candidate["excerpt"] =~ "Discuss 2048px export"
      assert candidate["facts"]["startsInMinutes"] == 20
      assert length(candidate["members"]) == 1

      # Synthetic meeting prep items must never raid the emergency reserve pool.
      refute CommaWeb.ProactiveCheck.reserve_eligible?(
               Map.merge(candidate, %{
                 "role" => "act",
                 "assessment" => %{"cost" => "Meeting in 20m", "due" => "2026-11-25T06:00:00Z"}
               }),
               @now
             )
    end
  end

  describe "ProactiveWebRadar" do
    test "keeps only public HTTPS content URLs that literally mention the watched term, deduplicated and capped" do
      search_fun = fn
        "Medalsmith" ->
          {:ok,
           [
             %{
               "url" => "https://indiehacker.example/posts/medalsmith-review",
               "title" => "Medalsmith 3D badge maker review",
               "text" => "Designers love Medalsmith for enamel 3D badges."
             },
             %{
               "url" => "https://indiehacker.example/posts/medalsmith-review",
               "title" => "Duplicate URL",
               "text" => "Medalsmith duplicate"
             },
             %{
               "url" => "https://unrelated.example/posts/other-app",
               "title" => "Some other tool",
               "text" => "Does not mention the watched term at all."
             },
             %{
               "url" => "https://127.0.0.1/internal/medalsmith",
               "title" => "Medalsmith internal",
               "text" => "Private IP must be dropped."
             },
             %{
               "url" => "https://github.com/org/repo/issues/1",
               "title" => "Medalsmith GitHub issue",
               "text" => "Provider host dropped from web radar."
             }
           ]}

        _ ->
          {:ok, []}
      end

      hits = ProactiveWebRadar.candidates(["Medalsmith", ""], search_fun, @now)
      assert length(hits) == 1
      [hit] = hits
      assert hit["web_radar"] == true
      assert hit["relationship"] == "web_mention_of_your_work"
      assert hit["url"] == "https://indiehacker.example/posts/medalsmith-review"
      assert hit["context"]["watchedTerm"] == "Medalsmith"
      assert ProactiveWebRadar.matter_key(hit["url"]) =~ "web_radar"
    end

    test "Web.search/2 forwards start_published_date to Exa /search payload" do
      prev_key = SystemsRuntime.get_env(:salix_agent, :exa_api_key)

      try do
        SystemsRuntime.put_env(:salix_agent, :exa_api_key, "test-exa-key")

        plug = fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          body = Jason.decode!(raw)
          assert conn.request_path == "/search"
          assert body["query"] == ~s("Medalsmith")
          assert body["startPublishedDate"] == "2026-11-23T05:40:00Z"

          Req.Test.json(conn, %{
            "results" => [
              %{
                "url" => "https://indiehacker.example/posts/medalsmith",
                "title" => "Medalsmith",
                "text" => "Medalsmith review."
              }
            ]
          })
        end

        assert {:ok, [%{"url" => "https://indiehacker.example/posts/medalsmith"}]} =
                 Web.search(~s("Medalsmith"),
                   start_published_date: "2026-11-23T05:40:00Z",
                   plug: plug
                 )
      after
        if is_nil(prev_key),
          do: SystemsRuntime.delete_env(:salix_agent, :exa_api_key),
          else: SystemsRuntime.put_env(:salix_agent, :exa_api_key, prev_key)
      end
    end
  end

  describe "ProactiveWatch public web bindings" do
    @workspace %{"id" => "ws_1"}

    test "admits bounded web.search and web.read_pages with public URLs and rejects SSRF or extra keys" do
      assert {:ok, %{"toolkit" => "web", "workspace_id" => "ws_1", "user_id" => "u_1"}} =
               ProactiveWatch.source_binding(
                 %{"tool" => "web.search", "arguments" => %{"query" => "Medalsmith release"}},
                 @workspace,
                 "u_1"
               )

      assert {:error, :proactive_source_required} =
               ProactiveWatch.source_binding(
                 %{"tool" => "web.search", "arguments" => %{"query" => ""}},
                 @workspace,
                 "u_1"
               )

      assert {:error, :proactive_source_required} =
               ProactiveWatch.source_binding(
                 %{
                   "tool" => "web.search",
                   "arguments" => %{"query" => "ok", "extra" => "forbidden"}
                 },
                 @workspace,
                 "u_1"
               )

      assert {:ok, %{"toolkit" => "web"}} =
               ProactiveWatch.source_binding(
                 %{
                   "tool" => "web.read_pages",
                   "arguments" => %{"urls" => ["https://status.stripe.com/current"]}
                 },
                 @workspace,
                 "u_1"
               )

      assert {:error, :proactive_source_required} =
               ProactiveWatch.source_binding(
                 %{
                   "tool" => "web.read_pages",
                   "arguments" => %{"url" => "https://a.example,http://127.0.0.1/admin"}
                 },
                 @workspace,
                 "u_1"
               )

      assert {:error, :proactive_source_required} =
               ProactiveWatch.source_binding(
                 %{
                   "tool" => "web.read_pages",
                   "arguments" => %{
                     "url" => "https://a.example",
                     "urls" => ["http://127.0.0.1/admin"]
                   }
                 },
                 @workspace,
                 "u_1"
               )

      assert {:error, :proactive_source_required} =
               ProactiveWatch.source_binding(
                 %{
                   "tool" => "web.read_pages",
                   "arguments" => %{"urls" => ["https://a.example,http://127.0.0.1/admin"]}
                 },
                 @workspace,
                 "u_1"
               )

      assert {:error, :proactive_source_required} =
               ProactiveWatch.source_binding(
                 %{
                   "tool" => "web.read_pages",
                   "arguments" => %{
                     "urls" => [
                       "https://a.example/1",
                       "https://b.example/2",
                       "https://c.example/3",
                       "https://d.example/4"
                     ]
                   }
                 },
                 @workspace,
                 "u_1"
               )

      assert :ok = ProactiveWatch.current_consent(%{"toolkit" => "web"})
      assert "Web" == ProactiveWatch.provider(%{"tool" => "web.search"})
      assert "Web" == ProactiveWatch.provider(%{"tool" => "web.read_pages"})
      assert "web" == Proactive.source_account(%{"tool" => "web.search", "arguments" => %{}})
      assert "web" == Proactive.source_account(%{"tool" => "web.read_pages", "arguments" => %{}})
    end

    test "preview formats web.read_pages results list cleanly" do
      spec = %{
        "tool" => "web.read_pages",
        "arguments" => %{"urls" => ["https://status.example/now"]}
      }

      result = %{
        "count" => 1,
        "results" => [
          %{
            "url" => "https://status.example/now",
            "title" => "Service Status",
            "text" => "All systems operational."
          }
        ]
      }

      preview = ProactiveWatch.preview(result, spec)
      assert [%{"body" => body}] = preview["messages"]
      assert body =~ "Service Status"
      assert body =~ "All systems operational."
    end

    test "project_result strips volatile Exa fields and detects tail changes past truncation via content_sha256" do
      web_watch_row = %{"config" => %{"comma_proactive" => %{"toolkit" => "web"}}}
      ordinary_row = %{"config" => %{}}

      md_up = "# Search results\n" <> String.duplicate("Medalsmith release update. ", 400) <> "UP"

      md_down =
        "# Search results\n" <> String.duplicate("Medalsmith release update. ", 400) <> "DOWN"

      projected_search_up = ProactiveWatch.project_result(web_watch_row, "web.search", md_up)
      projected_search_down = ProactiveWatch.project_result(web_watch_row, "web.search", md_down)
      assert byte_size(projected_search_up) <= 3_200
      assert %{"text" => text, "content_sha256" => h_up} = Jason.decode!(projected_search_up)
      assert %{"content_sha256" => h_down} = Jason.decode!(projected_search_down)
      assert text =~ "Medalsmith release update."
      assert h_up != h_down
      assert projected_search_up != projected_search_down
      assert ProactiveWatch.project_result(ordinary_row, "web.search", md_up) == md_up

      read_1 =
        Jason.encode!(%{
          "requestId" => "req_1",
          "costDollars" => %{"total" => 0.001},
          "count" => 1,
          "results" => [%{"url" => "https://status.example/now", "title" => "OK", "text" => "Up"}]
        })

      read_2 =
        Jason.encode!(%{
          "requestId" => "req_2",
          "costDollars" => %{"total" => 0.002},
          "count" => 1,
          "results" => [%{"url" => "https://status.example/now", "title" => "OK", "text" => "Up"}]
        })

      p1 = ProactiveWatch.project_result(web_watch_row, "web.read_pages", read_1)
      p2 = ProactiveWatch.project_result(web_watch_row, "web.read_pages", read_2)
      assert p1 == p2
      refute p1 =~ "requestId"
      refute p1 =~ "costDollars"

      # Tail change past the 1000-byte per-string projection truncation must produce a different projection.
      prefix = String.duplicate("A", 1_100)

      long_up =
        Jason.encode!(%{
          "count" => 1,
          "results" => [
            %{
              "url" => "https://status.example/now",
              "title" => "Status",
              "text" => prefix <> "UP"
            }
          ]
        })

      long_down =
        Jason.encode!(%{
          "count" => 1,
          "results" => [
            %{
              "url" => "https://status.example/now",
              "title" => "Status",
              "text" => prefix <> "DOWN"
            }
          ]
        })

      p_up = ProactiveWatch.project_result(web_watch_row, "web.read_pages", long_up)
      p_down = ProactiveWatch.project_result(web_watch_row, "web.read_pages", long_down)
      assert p_up != p_down
    end
  end

  describe "Synthetic trigger enforcement and Web Radar guards" do
    test "ProactiveCheck.decide/5 enforces signal-only and code=false for meeting_prep and web_radar" do
      for synth <- [
            %{
              "id" => "mp:1",
              "url" => "https://calendar.google.com/event/1",
              "meeting_prep" => true,
              "relationship" => "upcoming_meeting_prep"
            },
            %{
              "id" => "wr:1",
              "url" => "https://indiehacker.example/posts/medalsmith",
              "web_radar" => true,
              "relationship" => "web_mention_of_your_work"
            }
          ] do
        interrupt_ans = %{
          "id" => synth["id"],
          "repeats" => false,
          "code" => true,
          "role" => "act",
          "link" => "portrait",
          "cost" => "Urgent",
          "due" => "2026-11-25T06:00:00Z",
          "reversible" => false,
          "decision" => "interrupt",
          "reason" => "Attempted escalation",
          "message" => "Interrupting now."
        }

        assert {:ok, {:settle, "briefing", assessment}} =
                 CommaWeb.ProactiveCheck.decide(interrupt_ans, synth, @now, [])

        assert assessment["code"] == false

        ask_ans = Map.put(interrupt_ans, "decision", "ask")

        assert {:ok, {:settle, "briefing", ask_assessment}} =
                 CommaWeb.ProactiveCheck.decide(ask_ans, synth, @now, [])

        assert ask_assessment["code"] == false

        signal_ans = Map.merge(interrupt_ans, %{"decision" => "signal", "role" => "reference"})

        assert {:ok, {:handoff, item, "Interrupting now."}} =
                 CommaWeb.ProactiveCheck.decide(signal_ans, synth, @now, [])

        assert item["assessment"]["code"] == false
        assert item["assessment"]["signal"] == true
      end
    end

    test "ProactiveWebRadar requires word-boundary ASCII match, caps at 3 hits, and defaults off" do
      search_fun = fn _term ->
        {:ok,
         [
           %{
             "url" => "https://blog.example/rescue-story",
             "title" => "Mountain rescue story",
             "text" => "A barbecue and rescue tale without the product."
           },
           %{
             "url" => "https://blog.example/cue-1",
             "title" => "Cue app launch",
             "text" => "Testing Cue on iOS."
           },
           %{
             "url" => "https://blog.example/cue-2",
             "title" => "Cue review",
             "text" => "Cue works fast."
           },
           %{
             "url" => "https://blog.example/cue-3",
             "title" => "Cue 3",
             "text" => "Cue third post."
           },
           %{
             "url" => "https://blog.example/cue-4",
             "title" => "Cue 4",
             "text" => "Cue fourth post exceeds cap."
           }
         ]}
      end

      hits = ProactiveWebRadar.candidates(["Cue"], search_fun, @now)
      assert length(hits) == 3
      refute Enum.any?(hits, &(&1["url"] =~ "rescue-story"))

      prev_flag = SystemsRuntime.get_env(:comma_web, :proactive_web_radar_enabled)
      prev_key = SystemsRuntime.get_env(:salix_agent, :exa_api_key)

      try do
        SystemsRuntime.delete_env(:comma_web, :proactive_web_radar_enabled)
        SystemsRuntime.put_env(:salix_agent, :exa_api_key, "test-key")
        refute ProactiveWebRadar.enabled?()

        SystemsRuntime.put_env(:comma_web, :proactive_web_radar_enabled, true)
        assert ProactiveWebRadar.enabled?()
      after
        if is_nil(prev_flag),
          do: SystemsRuntime.delete_env(:comma_web, :proactive_web_radar_enabled),
          else: SystemsRuntime.put_env(:comma_web, :proactive_web_radar_enabled, prev_flag)

        if is_nil(prev_key),
          do: SystemsRuntime.delete_env(:salix_agent, :exa_api_key),
          else: SystemsRuntime.put_env(:salix_agent, :exa_api_key, prev_key)
      end

      # Redis dedup marks settled URLs seen for 72h when Redis is reachable, and fails open otherwise.
      url = "https://blog.example/seen-check-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      if match?({:ok, "PONG"}, Redix.command(Comma.MiniApps.RateLimit.Redis, ["PING"])) do
        refute ProactiveWebRadar.seen?("prof_test", url)
        assert :ok = ProactiveWebRadar.mark_seen("prof_test", url)
        assert ProactiveWebRadar.seen?("prof_test", url)
      else
        assert :ok = ProactiveWebRadar.mark_seen("prof_test", url)
        refute ProactiveWebRadar.seen?("prof_test", url)
      end
    end

    test "ProactiveWebRadar.search_query/2 disambiguates short single-word terms with allowlisted category hints only" do
      # Short single-word English names append at most two static public category hints without leaking private names.
      assert ProactiveWebRadar.search_query("Comma", [
               "duty: Owns Comma AI personal assistant for SecretCustomerX"
             ]) == ~s("Comma" AI assistant)

      assert ProactiveWebRadar.search_query("Cue", [
               "职责: 开发 Cue 的 iOS 客户端、聊天界面"
             ]) == ~s("Cue" iOS app)

      # Already-distinctive terms stay exact quoted queries.
      assert ProactiveWebRadar.search_query("Medalsmith", ["duty: 3D SVG medal app"]) ==
               ~s("Medalsmith")

      assert ProactiveWebRadar.search_query("PinShot", ["duty: screenshot tool"]) ==
               ~s("PinShot")

      assert ProactiveWebRadar.search_query("still.fail", ["duty: AI workspace"]) ==
               ~s("still.fail")

      # Without matching category hints, short words fall back cleanly to the quoted term.
      assert ProactiveWebRadar.search_query("Comma", ["duty: SecretProjectAlpha"]) ==
               ~s("Comma")
    end
  end

  describe "Calendar attendee metadata preservation" do
    test "Google Calendar preserves non-self non-declined attendeeCount and attendeesSummary" do
      routes = fn "GET", url, _opts ->
        cond do
          String.ends_with?(url, "/calendars/primary") ->
            {:ok, %{"id" => "member@example.com"}}

          String.contains?(url, "/calendars/primary/events") ->
            {:ok,
             %{
               "items" => [
                 %{
                   "id" => "e_group",
                   "summary" => "Design Sync",
                   "htmlLink" => "https://calendar.google.com/event/e_group",
                   "status" => "confirmed",
                   "start" => %{"dateTime" => "2026-11-25T06:00:00Z"},
                   "end" => %{"dateTime" => "2026-11-25T06:30:00Z"},
                   "attendees" => [
                     %{
                       "email" => "member@example.com",
                       "self" => true,
                       "responseStatus" => "accepted"
                     },
                     %{
                       "email" => "lena@acme.example",
                       "displayName" => "Lena Wu",
                       "responseStatus" => "accepted"
                     },
                     %{
                       "email" => "declined@acme.example",
                       "displayName" => "Skipped",
                       "responseStatus" => "declined"
                     }
                   ]
                 },
                 %{
                   "id" => "e_solo",
                   "summary" => "Focus Time",
                   "htmlLink" => "https://calendar.google.com/event/e_solo",
                   "status" => "confirmed",
                   "start" => %{"dateTime" => "2026-11-25T07:00:00Z"},
                   "end" => %{"dateTime" => "2026-11-25T08:00:00Z"},
                   "attendees" => [
                     %{
                       "email" => "member@example.com",
                       "self" => true,
                       "responseStatus" => "accepted"
                     }
                   ]
                 }
               ]
             }}
        end
      end

      assert {:ok, %{"items" => [group, solo]}, _} =
               RecommendationGoogleMemberSource.read("googlecalendar", routes, @now)

      assert group["attendeeCount"] == 1
      assert group["attendeesSummary"] =~ "Lena Wu <lena@acme.example>"
      refute group["attendeesSummary"] =~ "declined@acme.example"
      assert solo["attendeeCount"] == 0
      refute Map.has_key?(solo, "attendeesSummary")
    end

    test "Outlook Calendar preserves non-self non-declined attendeeCount and attendeesSummary" do
      routes = fn "GET", url, _opts ->
        case URI.parse(url).path do
          "/v1.0/me" ->
            {:ok, %{"id" => "user-1", "mail" => "member@example.com"}}

          "/v1.0/me/calendarView" ->
            {:ok,
             %{
               "value" => [
                 %{
                   "id" => "o_group",
                   "subject" => "Q4 Sync",
                   "webLink" => "https://outlook.office.com/calendar/o_group",
                   "start" => %{"dateTime" => "2026-11-25T06:00:00", "timeZone" => "UTC"},
                   "end" => %{"dateTime" => "2026-11-25T06:30:00", "timeZone" => "UTC"},
                   "organizer" => %{"emailAddress" => %{"address" => "member@example.com"}},
                   "attendees" => [
                     %{
                       "emailAddress" => %{"name" => "Member", "address" => "member@example.com"},
                       "status" => %{"response" => "accepted"}
                     },
                     %{
                       "emailAddress" => %{"name" => "Alex Chen", "address" => "alex@example.com"},
                       "status" => %{"response" => "accepted"}
                     },
                     %{
                       "emailAddress" => %{"name" => "NoShow", "address" => "no@example.com"},
                       "status" => %{"response" => "declined"}
                     }
                   ]
                 }
               ]
             }}

          _ ->
            {:ok, %{"value" => []}}
        end
      end

      assert {:ok, %{"items" => [event]}, _} =
               RecommendationOutlookMemberSource.read(routes, @now)

      assert event["attendeeCount"] == 1
      assert event["attendeesSummary"] =~ "Alex Chen <alex@example.com>"
      refute event["attendeesSummary"] =~ "no@example.com"
    end

    test "ProactiveWebRadar.collect_candidates propagates search errors and filters seen URLs before capping at 3" do
      assert {:error, :timeout} ==
               ProactiveWebRadar.collect_candidates(
                 ["Medalsmith"],
                 fn _term -> {:error, :timeout} end,
                 @now
               )

      assert {:error, :rate_limited} ==
               ProactiveWebRadar.collect_candidates(
                 ["Medalsmith", "HarborQL"],
                 fn
                   "Medalsmith" -> {:ok, []}
                   "HarborQL" -> {:error, :rate_limited}
                 end,
                 @now
               )

      # Top 3 hits are already seen; the 4th fresh hit must NOT be starved by taking 3 before filtering seen.
      search_fun = fn "Medalsmith" ->
        {:ok,
         for i <- 1..4 do
           %{
             "url" => "https://blog.example/post-#{i}",
             "title" => "Medalsmith review ##{i}",
             "text" => "Hands-on review of Medalsmith 3D badge maker."
           }
         end}
      end

      seen_urls = MapSet.new(for i <- 1..3, do: "https://blog.example/post-#{i}")

      assert {:ok, [fresh]} =
               ProactiveWebRadar.collect_candidates(
                 ["Medalsmith"],
                 search_fun,
                 @now,
                 &MapSet.member?(seen_urls, &1)
               )

      assert fresh["url"] == "https://blog.example/post-4"
    end
  end
end
