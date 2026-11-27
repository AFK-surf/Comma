defmodule CommaWeb.ProactiveResearchTest do
  use SystemsClock.Case, async: true

  alias CommaWeb.{MemberPortrait, ProactiveCheck, ProactiveEvidence, ProactiveResearch}
  alias SalixAgent.Tools.Web

  test "Web.public_url?/1 rejects private, loopback, internal names and userinfo URLs" do
    assert Web.public_url?("https://developer.apple.com/testflight/in-app-purchases")
    assert Web.public_url?("https://dexweekly.example/issues/373")

    refute Web.public_url?("http://localhost:8080/secret")
    refute Web.public_url?("https://127.0.0.1/admin")
    refute Web.public_url?("https://169.254.169.254/latest/meta-data/")
    refute Web.public_url?("https://10.0.0.5/internal")
    refute Web.public_url?("https://192.168.1.1/")
    refute Web.public_url?("https://service.internal/api")
    refute Web.public_url?("https://user:pass@example.com/path")
    refute Web.public_url?("ftp://example.com/file")
    refute Web.public_url?("")
  end

  test "Web.contents/2 returns :not_configured without API key and parses mocked Exa responses" do
    assert {:error, :invalid} = Web.contents(["https://127.0.0.1/nope"])

    prev_key = SystemsRuntime.get_env(:salix_agent, :exa_api_key)

    try do
      SystemsRuntime.delete_env(:salix_agent, :exa_api_key)
      assert {:error, :not_configured} = Web.contents(["https://dexweekly.example/issues/373"])

      SystemsRuntime.put_env(:salix_agent, :exa_api_key, "test-exa-key")

      plug = fn conn ->
        assert conn.request_path == "/contents"
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-exa-key"]

        Req.Test.json(conn, %{
          "results" => [
            %{
              "url" => "https://dexweekly.example/issues/373",
              "title" => "  DEX #373  ",
              "text" => "  Medalsmith featured by dingyi.  "
            }
          ]
        })
      end

      assert {:ok,
              [
                %{
                  "url" => "https://dexweekly.example/issues/373",
                  "title" => "DEX #373",
                  "text" => "Medalsmith featured by dingyi."
                }
              ]} =
               Web.contents(["https://dexweekly.example/issues/373"], plug: plug)
    after
      if is_nil(prev_key),
        do: SystemsRuntime.delete_env(:salix_agent, :exa_api_key),
        else: SystemsRuntime.put_env(:salix_agent, :exa_api_key, prev_key)
    end
  end

  test "ProactiveEvidence.external_urls/1 keeps content links and drops query, capability, provider, root, asset and tracking URLs" do
    text = """
    Check <https://dexweekly.example/issues/373|DEX #373> and https://developer.apple.com/testflight/in-app-purchases).
    Ignore https://api.bridge.example https://github.com/acme/repo/pull/1
    https://example.slack.com/archives/C1/p123 https://cdn.example.com/logo.png
    https://newsletter.example/unsubscribe?id=1 https://10.0.0.1/internal
    https://docs.example.com/report?token=secret123
    https://app.example.com/auth/magic-link/abc
    https://app.example.com/reset/9a8b7c6d5e4f3a2b1c0d9e8f1234
    https://billing.example.com/invoices/2026-11
    https://vendor.example.com/invite/team-secret
    https://vendor.example.com/share/Ab12Cd34Ef56Gh78Ij90Kl12Mn34
    """

    assert ProactiveEvidence.external_urls(text) == [
             "https://dexweekly.example/issues/373",
             "https://developer.apple.com/testflight/in-app-purchases"
           ]
  end

  test "ProactiveEvidence.targets/1 unfurls Slack and mentions_your_work items only, never private mail or junk" do
    slack_matter = %{
      "toolkit" => "slack",
      "url" => "https://example.slack.com/archives/C0WATER01/p1795575600000100",
      "relationship" => "posted_where_your_work_is",
      "excerpt" => "Share <https://dexweekly.example/issues/373>"
    }

    assert Enum.any?(
             ProactiveEvidence.targets(slack_matter),
             &match?({:web, "https://dexweekly.example/issues/373", :web_page}, &1)
           )

    newsletter = %{
      "toolkit" => "gmail",
      "url" => "https://mail.google.com/mail/u/0/#inbox/n1",
      "relationship" => "mentions_your_work",
      "excerpt" => "Featured in https://dexweekly.example/issues/373"
    }

    assert Enum.any?(
             ProactiveEvidence.targets(newsletter),
             &match?({:web, "https://dexweekly.example/issues/373", :web_page}, &1)
           )

    # Private emails (awaiting_your_reply, direct mail, etc.) must never send links to third-party Exa.
    private_mail = %{
      "toolkit" => "gmail",
      "url" => "https://mail.google.com/mail/u/0/#inbox/p1",
      "relationship" => "awaiting_your_reply",
      "excerpt" => "Please review https://dexweekly.example/issues/373 before signing."
    }

    refute Enum.any?(ProactiveEvidence.targets(private_mail), &match?({:web, _, :web_page}, &1))

    junk = Map.put(slack_matter, "relationship", "in_your_junk_folder")

    refute Enum.any?(ProactiveEvidence.targets(junk), &match?({:web, _, :web_page}, &1))
  end

  test "ProactiveResearch.normalize_queries/1 enforces source allowlist, SSRF guard, and max 3 cap" do
    queries = [
      %{"source" => "memory", "query" => "Comma 1.0.4 sandbox 规则"},
      %{"source" => "memory", "query" => "comma 1.0.4 sandbox 规则"},
      %{"source" => "pool", "query" => "cue.surf credit fulfillment"},
      %{"source" => "web_read", "query" => "https://127.0.0.1/secret"},
      %{"source" => "shell", "query" => "rm -rf /"},
      %{"source" => "web_search", "query" => "TestFlight in-app purchases sandbox billing"},
      %{"source" => "web_read", "query" => "https://developer.apple.com/testflight/help"}
    ]

    assert ProactiveResearch.normalize_queries(queries) == [
             %{"source" => "memory", "query" => "Comma 1.0.4 sandbox 规则"},
             %{"source" => "pool", "query" => "cue.surf credit fulfillment"},
             %{"source" => "web_search", "query" => "TestFlight in-app purchases sandbox billing"}
           ]
  end

  test "ProactiveResearch.run/3 searches Chinese and English memory, pool, web_search and web_read deterministically" do
    kase = %{
      "memory" => [
        %{
          "path" => "/memory/episodes/2026-11-23.md",
          "text" => "Comma 1.0.4 沙盒积分规则：仅 cue.surf 或 comma.surf 邮箱工作区入账。"
        },
        %{
          "path" => "/memory/scoped/private.md",
          "text" => "Scoped secret cue.surf should never leak."
        }
      ],
      "pool_items" => [
        %{
          "app" => "GitHub",
          "title" => "feat(billing): gate TestFlight sandbox credits to cue.surf",
          "url" => "https://github.com/AFK-surf/Cue/pull/5590",
          "excerpt" => "Only @cue.surf or @comma.surf workspace owners receive sandbox credits."
        }
      ],
      "web" => [
        %{
          "url" => "https://dexweekly.example/issues/373",
          "title" => "DEX #373",
          "text" => "Medalsmith 3D medal app featured."
        }
      ],
      "web_search" => [
        %{
          "match" => ["testflight", "sandbox"],
          "results" => [
            %{
              "title" => "Apple TestFlight IAP",
              "url" => "https://developer.apple.com/testflight/in-app-purchases",
              "text" => "TestFlight purchases are free in sandbox."
            }
          ]
        }
      ]
    }

    env = ProactiveResearch.from_replay(kase, "https://outlook.office.com/mail/inbox/id/current")

    findings =
      ProactiveResearch.run(
        [
          %{"source" => "memory", "query" => "Comma 沙盒 积分 规则"},
          %{"source" => "pool", "query" => "TestFlight sandbox credit"},
          %{"source" => "web_search", "query" => "TestFlight sandbox billing"}
        ],
        env
      )

    assert [
             %{
               "source" => "memory",
               "matches" => [%{"path" => "/memory/episodes/2026-11-23.md", "excerpt" => mem_text}]
             },
             %{
               "source" => "pool",
               "matches" => [%{"url" => "https://github.com/AFK-surf/Cue/pull/5590"}]
             },
             %{
               "source" => "web_search",
               "matches" => [
                 %{"url" => "https://developer.apple.com/testflight/in-app-purchases"}
               ]
             }
           ] = findings

    assert mem_text =~ "cue.surf"
    refute Jason.encode!(findings) =~ "Scoped secret"

    # Zero-cost local_context matches specific overlapping items and stays empty for unrelated or junk arrivals.
    tf_matches =
      ProactiveResearch.local_context(
        %{
          "title" => "TestFlight: Comma 1.0.4 (23) is ready to test",
          "excerpt" => "Usage page subscriptions and credit pack purchases in TestFlight sandbox."
        },
        env
      )

    assert Enum.any?(tf_matches, &(&1["source"] == "memory" and &1["excerpt"] =~ "cue.surf"))

    assert Enum.any?(
             tf_matches,
             &(&1["source"] == "pool" and &1["url"] == "https://github.com/AFK-surf/Cue/pull/5590")
           )

    assert ProactiveResearch.local_context(
             %{
               "title" => "TestFlight: WeatherNotes 3.2.0 is ready to test",
               "excerpt" => "Minor widget bug fixes."
             },
             env
           ) == []

    assert ProactiveResearch.local_context(
             %{
               "relationship" => "in_your_junk_folder",
               "title" => "TestFlight: Comma 1.0.4 (23)",
               "excerpt" => "Usage credit pack sandbox"
             },
             env
           ) == []
  end

  test "ProactiveCheck.decide/5 admits investigate only when allow_investigate is true and terminates otherwise" do
    matter = %{"id" => "i1", "url" => "https://outlook.office.com/mail/1"}

    answer = %{
      "id" => "i1",
      "repeats" => false,
      "code" => false,
      "role" => "act",
      "link" => "portrait",
      "cost" => "",
      "due" => nil,
      "reversible" => true,
      "decision" => "investigate",
      "reason" => "Need backend sandbox rule before notifying.",
      "message" => nil,
      "queries" => [%{"source" => "memory", "query" => "Comma sandbox"}]
    }

    assert {:ok, {:investigate, [%{"source" => "memory", "query" => "Comma sandbox"}]}} =
             ProactiveCheck.decide(answer, matter, SystemsClock.utc_now(), [],
               allow_investigate: true
             )

    # Round 2 (allow_investigate: false) must never loop.
    assert {:ok, :unclear} =
             ProactiveCheck.decide(answer, matter, SystemsClock.utc_now(), [],
               allow_investigate: false
             )

    # Empty or invalid queries cannot trigger research.
    assert {:ok, :unclear} =
             ProactiveCheck.decide(
               Map.put(answer, "queries", []),
               matter,
               SystemsClock.utc_now(),
               [],
               allow_investigate: true
             )
  end

  test "MemberPortrait grounds term: targets, rejects generic words, and honors exclusions" do
    input =
      MemberPortrait.input(
        [],
        [],
        [],
        "kai",
        [],
        %{
          "memory" => [
            %{
              "path" => "/memory/episodes/2026-11-24.md",
              "text" => "Maintains Medalsmith app and works on Comma release in #watercooler."
            }
          ]
        }
      )

    {:ok, entries} =
      MemberPortrait.build(
        %{
          "entries" => [
            %{
              "kind" => "duty",
              "text" => "maintains Medalsmith",
              "evidence" => ["memory"],
              "watch" => ["term:Medalsmith", "term:app", "term:UnmentionedProduct"]
            },
            %{
              "kind" => "place",
              "text" => "watches #watercooler",
              "evidence" => ["memory"],
              "watch" => ["#watercooler", "term:Comma"]
            },
            %{
              "kind" => "exclusion",
              "text" => "ignores Comma promo noise",
              "evidence" => ["memory"],
              "watch" => ["term:Comma"]
            }
          ]
        },
        input,
        ~D[2026-11-25]
      )

    note = MemberPortrait.render_note("", entries, "en")
    targets = note |> MemberPortrait.statements() |> MemberPortrait.targets()

    assert targets["channels"] == ["watercooler"]
    assert targets["terms"] == ["Medalsmith"]

    # Hourly target injection attaches terms to both Slack (when channels exist) and Gmail.
    now = ~U[2026-11-25 03:05:00Z]

    assert %{"memberTargets" => %{"terms" => ["Medalsmith"]}} =
             MemberPortrait.with_targets(%{"appId" => "gmail"}, targets, now)

    assert %{"memberTargets" => %{"channels" => ["watercooler"], "terms" => ["Medalsmith"]}} =
             MemberPortrait.with_targets(%{"appId" => "slack"}, targets, now)
  end

  test "MemberPortrait degrades cleanly when Slack fails, preserves watch targets across normalized text, and maps term contexts" do
    # A broken or missing-scope Slack grant must degrade to empty Slack messages rather than aborting refresh.
    assert {:ok, [], nil} =
             MemberPortrait.resolve_own_messages(
               [%{"connectionId" => "s1"}],
               fn _source -> {:error, :member_identity_unavailable} end
             )

    assert {:ok, [%{"text" => "hi"}], "kai"} =
             MemberPortrait.resolve_own_messages(
               [%{"connectionId" => "broken"}, %{"connectionId" => "healthy"}],
               fn
                 %{"connectionId" => "broken"} ->
                   {:error, {:member_provider_error, "missing_scope"}}

                 %{"connectionId" => "healthy"} ->
                   {:ok, [%{"text" => "hi"}], %{"handle" => "kai"}}
               end
             )

    input =
      MemberPortrait.input(
        [],
        [],
        [],
        "kai",
        [
          %{
            "app" => "GitHub",
            "title" => "Comma proactive engine",
            "url" => "https://github.com/AFK-surf/Cue/pull/5665",
            "relationship" => "authored_by_you"
          }
        ],
        %{
          "memory" => [
            %{
              "path" => "/memory/episodes/2026-11-25.md",
              "text" =>
                "Owns Comma AI assistant in #comma-app and #still-fail with repo AFK-surf/Cue and AFK-surf/monoid."
            }
          ]
        }
      )

    {:ok, entries} =
      MemberPortrait.build(
        %{
          "entries" => [
            %{
              "kind" => "duty",
              "text" => "Owns Comma  AI\nassistant client",
              "evidence" => ["memory"],
              "watch" => [
                "repo:AFK-surf/Cue",
                "repo:AFK-surf/monoid",
                "#comma-app",
                "term:Comma",
                "#still-fail"
              ]
            },
            %{
              "kind" => "exclusion",
              "text" => "Ignores monoid noise",
              "evidence" => ["memory"],
              "watch" => ["term:monoid"]
            }
          ]
        },
        input,
        ~D[2026-11-26]
      )

    note = MemberPortrait.render_note("", entries, "en")
    statements = MemberPortrait.statements(note)
    targets = MemberPortrait.targets(statements)

    # Whitespace-normalized text still keeps its watch list, and up to four targets survive per entry.
    assert targets["repos"] == ["AFK-surf/Cue", "AFK-surf/monoid"]
    assert targets["channels"] == ["comma-app"]
    assert targets["terms"] == ["Comma"]

    contexts = MemberPortrait.term_contexts(statements)
    assert %{"comma" => [line]} = contexts
    assert line =~ "Owns Comma AI assistant client"
    refute Map.has_key?(contexts, "monoid")
  end

  test "ProactiveResearch.local_context/2 rejects noisy English/Chinese boilerplate and free-mail domains" do
    kase = %{
      "memory" => [
        %{
          "path" => "/memory/episodes/2026-11-24.md",
          "text" => "今天我们确认了系统更新的通知和方案，请大家通过 gmail.com 邮件回复确认。"
        },
        %{
          "path" => "/memory/semantic/notes.md",
          "text" =>
            "Weekly team update sent via outlook.com: please check the report and message."
        }
      ],
      "pool_items" => [
        %{
          "app" => "Gmail",
          "title" => "Re: Weekly update from alice@gmail.com",
          "url" => "https://mail.google.com/mail/u/0/#inbox/other1",
          "excerpt" => "Please check the system update and reply today."
        }
      ]
    }

    env = ProactiveResearch.from_replay(kase, "https://mail.google.com/mail/u/0/#inbox/current")

    assert ProactiveResearch.local_context(
             %{
               "title" => "Re: 今天我们确认了系统更新通知方案",
               "excerpt" => "请大家通过 gmail.com 和 outlook.com 查看最新系统更新报告。"
             },
             env
           ) == []
  end

  test "ProactiveCheck.attach_portrait_terms/2 grounds signal handoffs even when link is subscribed, never junk" do
    matter =
      %{
        "id" => "i1",
        "title" => "DEX Weekly #373",
        "url" => "https://mail.google.com/mail/u/0/#inbox/dex",
        "relationship" => "mentions_your_work",
        "excerpt" => "Weekly newsletter issue 373",
        "linked" => [
          %{
            "kind" => "web_page",
            "url" => "https://dexweekly.example/issues/373",
            "title" => "DEX #373",
            "text" => "Medalsmith was featured this week."
          }
        ]
      }
      |> ProactiveCheck.attach_portrait_terms(["Medalsmith", "Comma"])

    assert matter["matchedPortraitTerms"] == ["Medalsmith"]

    answer = %{
      "id" => "i1",
      "repeats" => false,
      "code" => false,
      "role" => "reference",
      "link" => "subscribed",
      "cost" => "",
      "due" => nil,
      "reversible" => true,
      "decision" => "signal",
      "reason" => "Medalsmith featured in DEX #373.",
      "message" =>
        "Medalsmith was featured in [DEX #373](https://dexweekly.example/issues/373) and [PR](https://github.com/AFK-surf/Cue/pull/5590)."
    }

    assert {:ok, {:handoff, _item, cleaned}} =
             ProactiveCheck.decide(answer, matter, SystemsClock.utc_now(), [],
               related_context: [%{"url" => "https://github.com/AFK-surf/Cue/pull/5590"}]
             )

    assert cleaned =~ "[DEX #373](https://dexweekly.example/issues/373)"
    assert cleaned =~ "[PR](https://github.com/AFK-surf/Cue/pull/5590)"

    # Junk mail is never routed as signal even if a portrait term appears.
    junk = Map.put(matter, "relationship", "in_your_junk_folder")

    assert {:ok, {:settle, "briefing", _}} =
             ProactiveCheck.decide(answer, junk, SystemsClock.utc_now(), [])
  end

  test "RecommendationSlackMemberSource prioritizes bots, asks, and watched terms over casual link-only posts" do
    now = ~U[2026-11-25 03:05:00Z]

    matches = [
      %{
        "user" => "U_PEER1",
        "ts" => "1795575601.000100",
        "channel" => %{"id" => "C1", "name" => "eng"},
        "text" => "Cool article https://blog.example/post-1",
        "permalink" => "https://example.slack.com/archives/C1/p1795575601000100"
      },
      %{
        "user" => "U_PEER2",
        "ts" => "1795575602.000100",
        "channel" => %{"id" => "C1", "name" => "eng"},
        "text" => "Another link https://blog.example/post-2",
        "permalink" => "https://example.slack.com/archives/C1/p1795575602000100"
      },
      %{
        "user" => "U_PEER3",
        "ts" => "1795575603.000100",
        "channel" => %{"id" => "C1", "name" => "eng"},
        "text" => "Third link https://blog.example/post-3",
        "permalink" => "https://example.slack.com/archives/C1/p1795575603000100"
      },
      %{
        "user" => "U_PEER4",
        "ts" => "1795575604.000100",
        "channel" => %{"id" => "C1", "name" => "eng"},
        "text" => "Fourth link https://blog.example/post-4",
        "permalink" => "https://example.slack.com/archives/C1/p1795575604000100"
      },
      %{
        "user" => "U_PEER5",
        "ts" => "1795575605.000100",
        "channel" => %{"id" => "C1", "name" => "eng"},
        "text" => "Fifth link https://blog.example/post-5",
        "permalink" => "https://example.slack.com/archives/C1/p1795575605000100"
      },
      %{
        "bot_id" => "B_ALERT",
        "ts" => "1795575606.000100",
        "channel" => %{"id" => "C1", "name" => "eng"},
        "text" => "Deploy monitor alert: api errors spiked",
        "permalink" => "https://example.slack.com/archives/C1/p1795575606000100"
      },
      %{
        "user" => "U_PEER6",
        "ts" => "1795575607.000100",
        "channel" => %{"id" => "C1", "name" => "eng"},
        "text" => "Medalsmith hit #1 today!",
        "permalink" => "https://example.slack.com/archives/C1/p1795575607000100"
      },
      %{
        "user" => "U_PEER7",
        "ts" => "1795575608.000100",
        "channel" => %{"id" => "C1", "name" => "eng"},
        "text" => "Can someone review the billing PR?",
        "permalink" => "https://example.slack.com/archives/C1/p1795575608000100"
      }
    ]

    request = fn "GET", url, _opts ->
      uri = URI.parse(url)
      params = URI.decode_query(uri.query || "")

      case uri.path do
        "/api/auth.test" ->
          {:ok, %{"ok" => true, "user_id" => "U0OWNER01", "team_id" => "T0TEAM001"}}

        "/api/search.messages" ->
          if String.starts_with?(params["query"] || "", "in:#eng") do
            {:ok, %{"ok" => true, "messages" => %{"matches" => matches}}}
          else
            {:ok, %{"ok" => true, "messages" => %{"matches" => []}}}
          end

        _ ->
          {:ok, %{"ok" => false}}
      end
    end

    {:ok, data, _subject} =
      CommaWeb.RecommendationSlackMemberSource.read(request, now, nil,
        targets: %{"channels" => ["eng"], "terms" => ["Medalsmith"]}
      )

    urls = Enum.map(data["messages"]["matches"], & &1["permalink"])
    assert length(urls) == 5
    # All 3 priority items (bot, watched term, ask) survive despite 5 earlier link-only posts.
    assert "https://example.slack.com/archives/C1/p1795575606000100" in urls
    assert "https://example.slack.com/archives/C1/p1795575607000100" in urls
    assert "https://example.slack.com/archives/C1/p1795575608000100" in urls
    # At most 2 link-only posts fill the remaining slots.
    link_only_kept =
      Enum.count(urls, &(&1 in Enum.map(Enum.take(matches, 5), fn m -> m["permalink"] end)))

    assert link_only_kept == 2
  end

  test "ProactiveEvidence.sanitize_public_fetch_url/1 normalizes trailing dots, strips fragments, and blocks encoded sensitive paths" do
    # Percent-encoded auth path, trailing-dot provider host, double encoding, and query strings are all rejected.
    assert :error ==
             ProactiveEvidence.sanitize_public_fetch_url("https://example.com/%61uth/secret")

    assert :error ==
             ProactiveEvidence.sanitize_public_fetch_url("https://example.com/%2561uth/secret")

    assert :error ==
             ProactiveEvidence.sanitize_public_fetch_url(
               "https://docs.google.com./document/d/private123"
             )

    assert :error ==
             ProactiveEvidence.sanitize_public_fetch_url(
               "https://example.com/auth/reset?token=private"
             )

    assert :error ==
             ProactiveEvidence.sanitize_public_fetch_url("https://user@example.com/article")

    # Fragments are stripped before reaching Exa; benign paths like /authors/jane remain allowed.
    assert {:ok, "https://example.com/article"} ==
             ProactiveEvidence.sanitize_public_fetch_url(
               "https://example.com/article#token=secret"
             )

    assert {:ok, "https://blog.example/authors/jane"} ==
             ProactiveEvidence.sanitize_public_fetch_url("https://blog.example./authors/jane")

    # ProactiveResearch.normalize_queries enforces the same shared policy for web_read.
    assert ProactiveResearch.normalize_queries([
             %{"source" => "web_read", "query" => "https://example.com/auth/reset?token=private"},
             %{"source" => "web_read", "query" => "https://example.com/%61uth/secret"},
             %{
               "source" => "web_read",
               "query" => "https://docs.google.com./document/d/private123"
             },
             %{"source" => "web_read", "query" => "https://example.com/article#token=secret"}
           ]) == [
             %{"source" => "web_read", "query" => "https://example.com/article"}
           ]

    # Private mail matters reject web_read entirely in ProactiveCheck.decide/5.
    private_mail = %{
      "id" => "m_priv",
      "toolkit" => "gmail",
      "url" => "https://mail.google.com/mail/u/0/#inbox/m_priv",
      "relationship" => "awaiting_your_reply"
    }

    answer = %{
      "id" => "m_priv",
      "decision" => "investigate",
      "queries" => [
        %{"source" => "web_read", "query" => "https://example.com/article"},
        %{"source" => "memory", "query" => "Comma billing rule"}
      ]
    }

    assert {:ok, {:investigate, [%{"source" => "memory", "query" => "Comma billing rule"}]}} =
             CommaWeb.ProactiveCheck.decide(answer, private_mail, ~U[2026-11-25 06:00:00Z], [],
               allow_investigate: true
             )
  end

  test "local_context does not false-trigger on a single shared 3-character CJK phrase" do
    env =
      ProactiveResearch.from_replay(%{
        "memory" => [
          %{"path" => "/memory/episodes/2026-11-24.md", "text" => "下周一有空一起吃午饭"}
        ]
      })

    matter = %{
      "title" => "下周一安排",
      "excerpt" => "下周一记得带工牌"
    }

    assert ProactiveResearch.local_context(matter, env) == []
  end

  test "MemberPortrait grounds personal interests from personalSignals, enforces caps/work priority/Chinese colons, and isolates Slack and Web Radar" do
    # Real MemberSourceItem pool filtering: reads context["text"], excludes Outlook calendar,
    # excludes OTP/login/2FA/financial/alert cues in title OR body, sorts by receipt timestamp.
    pool_items = [
      %Comma.Data.MemberSourceItem{
        toolkit: "outlook",
        app: "",
        relationship: "your_recent_inbox_and_upcoming_events",
        title: "《海贼王》Whole Cake Island ⑧ 现已上线",
        excerpt: "《海贼王》Whole Cake Island ⑧ 现已上线",
        context: %{"text" => "One Piece full-color volume 8 is now available."},
        url: "https://outlook.office.com/mail/inbox/id/one-piece",
        facts: %{"messageTimestamp" => "2026-11-27T02:00:00Z"},
        first_seen_at: ~U[2026-11-27 02:05:00.000000Z]
      },
      %Comma.Data.MemberSourceItem{
        toolkit: "outlook",
        app: "Outlook",
        relationship: "your_recent_inbox_and_upcoming_events",
        title: "1:1 with Legal",
        excerpt: "1:1 with Legal",
        context: %{"text" => "Quarterly contract review"},
        url: "https://outlook.office.com/calendar/item/cal-1",
        facts: %{"start" => "2026-11-27T04:00:00Z", "attendeeCount" => 1},
        first_seen_at: ~U[2026-11-27 02:10:00.000000Z]
      },
      %Comma.Data.MemberSourceItem{
        toolkit: "gmail",
        app: "Gmail",
        relationship: "awaiting_your_reply",
        title: "Steam Guard",
        excerpt: "Steam Guard",
        context: %{"text" => "Use 849201 to access your account."},
        url: "https://mail.google.com/mail/u/0/#inbox/otp-body",
        facts: %{"messageTimestamp" => "2026-11-27T02:12:00Z"},
        first_seen_at: ~U[2026-11-27 02:12:00.000000Z]
      },
      %Comma.Data.MemberSourceItem{
        toolkit: "gmail",
        app: "Gmail",
        relationship: "awaiting_your_reply",
        title: "Sign in to Example",
        excerpt: "Sign in to Example",
        context: %{
          "text" =>
            "sender: Example Account Security <no-reply-notifications@security.example.com>\n" <>
              "to: engineering-alerts@company.com\n" <>
              "messageText: Hi Kai, enter 849201 to continue. This one-time verification code expires in 10 minutes."
        },
        url: "https://mail.google.com/mail/u/0/#inbox/otp-past-160",
        facts: %{"messageTimestamp" => "2026-11-27T02:12:30Z"},
        first_seen_at: ~U[2026-11-27 02:12:30.000000Z]
      },
      %Comma.Data.MemberSourceItem{
        toolkit: "gmail",
        app: "Gmail",
        relationship: "awaiting_your_reply",
        title: "Your sign-in link",
        excerpt: "Your sign-in link",
        context: %{"text" => "Use this magic link to access your workspace."},
        url: "https://mail.google.com/mail/u/0/#inbox/magic-link",
        facts: %{"messageTimestamp" => "2026-11-27T02:13:00Z"},
        first_seen_at: ~U[2026-11-27 02:13:00.000000Z]
      },
      %Comma.Data.MemberSourceItem{
        toolkit: "gmail",
        app: "Gmail",
        relationship: "awaiting_your_reply",
        title: "HSBC Debit Card Transaction Alert",
        excerpt: "HSBC Debit Card Transaction Alert",
        context: %{"text" => "SGD 17.95 spent on debit card ending 4251."},
        url: "https://mail.google.com/mail/u/0/#inbox/bank-alert",
        facts: %{"messageTimestamp" => "2026-11-27T02:14:00Z"},
        first_seen_at: ~U[2026-11-27 02:14:00.000000Z]
      },
      %Comma.Data.MemberSourceItem{
        toolkit: "gmail",
        app: "Gmail",
        relationship: "awaiting_your_reply",
        title: "Steam: 你的愿望单上有 2 款游戏史低特卖",
        excerpt: "Steam: 你的愿望单上有 2 款游戏史低特卖",
        context: %{"text" => "Hollow Knight and Hades II are on historical low sale."},
        url: "https://mail.google.com/mail/u/0/#inbox/steam-sale?authuser=kai@example.com",
        facts: %{"messageTimestamp" => "2026-11-27T02:15:00Z"},
        first_seen_at: ~U[2026-11-27 02:01:00.000000Z]
      }
    ]

    signals = MemberPortrait.personal_signals_from_items(pool_items)

    assert Enum.map(signals, & &1["title"]) == [
             "Steam: 你的愿望单上有 2 款游戏史低特卖",
             "《海贼王》Whole Cake Island ⑧ 现已上线"
           ]

    assert Enum.at(signals, 0)["excerpt"] =~ "Hollow Knight"
    assert Enum.at(signals, 1)["app"] == "outlook"
    assert Enum.at(signals, 1)["excerpt"] =~ "One Piece"

    input =
      MemberPortrait.input(
        [],
        [],
        [],
        "kai",
        [],
        %{
          "memory" => [
            %{
              "path" => "/memory/episodes/2026-11-26.md",
              "text" =>
                "Maintains Medalsmith 3D medal app in #eng. Also tracks Switch, Zelda, Nintendo, Celeste, Balatro, Factorio."
            }
          ],
          "personalSignals" => signals
        }
      )

    {:ok, entries} =
      MemberPortrait.build(
        %{
          "entries" => [
            %{
              "kind" => "interest",
              "text" => "关注 Steam 独立游戏史低折扣",
              "evidence" => [
                "https://mail.google.com/mail/u/0/#inbox/steam-sale?authuser=kai@example.com"
              ],
              "watch" => [
                "term:Steam",
                "term:sale",
                "term:折扣",
                "term:游戏",
                "term:Hollow Knight",
                "term:mail.google.com"
              ]
            },
            %{
              "kind" => "interest",
              "text" => "追更海贼王（One Piece）漫画",
              "evidence" => ["personalSignals"],
              "watch" => ["term:海贼王", "term:One Piece", "#eng"]
            },
            %{
              "kind" => "interest",
              "text" => "关注 Switch",
              "evidence" => ["memory"],
              "watch" => ["term:Switch"]
            },
            %{
              "kind" => "interest",
              "text" => "关注 Zelda",
              "evidence" => ["memory"],
              "watch" => ["term:Zelda"]
            },
            %{
              "kind" => "interest",
              "text" => "关注 Celeste",
              "evidence" => ["memory"],
              "watch" => ["term:Celeste"]
            },
            %{
              "kind" => "interest",
              "text" => "关注 Factorio",
              "evidence" => ["memory"],
              "watch" => ["term:Factorio"]
            },
            %{
              "kind" => "duty",
              "text" => "维护 Medalsmith 应用",
              "evidence" => ["memory"],
              "watch" => ["#eng", "term:Medalsmith"]
            }
          ]
        },
        input,
        ~D[2026-11-27]
      )

    # At most 5 interest entries survive; duty entry is preserved; interest drops #eng at build time.
    assert Enum.count(entries, &(&1["kind"] == "interest")) == 5
    assert Enum.any?(entries, &(&1["kind"] == "duty" and &1["text"] =~ "Medalsmith"))

    one_piece_entry = Enum.find(entries, &(&1["text"] =~ "海贼王"))
    refute "#eng" in (one_piece_entry["watch"] || [])

    note = MemberPortrait.render_note("", entries, "zh-CN")
    statements = MemberPortrait.statements(note)
    targets = MemberPortrait.targets(statements)

    # Work term "Medalsmith" ranks first and is never displaced by 5 earlier interest terms.
    # English and Chinese generic retail/hobby words and mail URL hosts are rejected.
    assert hd(targets["terms"]) == "Medalsmith"
    assert "Steam" in targets["terms"]
    refute "sale" in targets["terms"]
    refute "折扣" in targets["terms"]
    refute "游戏" in targets["terms"]
    refute "mail.google.com" in targets["terms"]

    # Slack and Web Radar receive work terms only; Gmail receives work + interest terms.
    now = ~U[2026-11-27 03:05:00Z]
    assert MemberPortrait.web_radar_terms(statements) == ["Medalsmith"]
    assert Map.keys(MemberPortrait.term_contexts(statements)) == ["medalsmith"]

    assert %{"memberTargets" => %{"channels" => ["eng"], "terms" => ["Medalsmith"]}} =
             MemberPortrait.with_targets(%{"appId" => "slack"}, targets, now)

    assert %{"memberTargets" => %{"terms" => ["Medalsmith", "Steam" | _]}} =
             MemberPortrait.with_targets(%{"appId" => "gmail"}, targets, now)

    # Router-edited Chinese full-width colons ("：") preserve interest filtering and exclusions.
    fullwidth_statements = [
      %{"text" => "关于你 · 兴趣：关注 Steam 独立游戏 · 2026-11-27 · watch: term:Steam"},
      %{"text" => "关于你 · 职责：维护 Medalsmith · 2026-11-27 · watch: term:Medalsmith"},
      %{"text" => "关于你 · 不归你：屏蔽 Steam 促销 · 2026-11-27 · watch: term: Steam"}
    ]

    assert MemberPortrait.web_radar_terms(fullwidth_statements) == ["Medalsmith"]
    assert MemberPortrait.targets(fullwidth_statements)["terms"] == ["Medalsmith"]

    # Interest entries persist past the 60-day expiration window like exclusions and preferences.
    later_input = MemberPortrait.input([], [], statements, "kai")

    {:ok, kept_entries} =
      MemberPortrait.build(
        %{
          "entries" => [
            %{"kind" => "duty", "text" => "维护 Medalsmith 应用", "evidence" => ["previous"]},
            %{
              "kind" => "interest",
              "text" => "关注 Steam 独立游戏史低折扣",
              "evidence" => ["previous"]
            }
          ]
        },
        later_input,
        ~D[2027-02-20]
      )

    assert Enum.map(kept_entries, & &1["kind"]) == ["interest"]
  end
end
