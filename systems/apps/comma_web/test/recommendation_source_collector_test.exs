defmodule CommaWeb.RecommendationSourceCollectorTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  alias CommaWeb.RecommendationSourceCollector

  defmodule Settings do
    def settings(_tenant_id), do: {:ok, %{"api_key" => "test"}}
  end

  defmodule Client do
    def execute_tool(_settings, tool_slug, group_id, arguments, opts) do
      test_pid = SystemsRuntime.fetch_env!(:comma_web, :recommendation_collector_test_pid)
      SystemsRuntime.Proc.send(test_pid, {:execute, tool_slug, group_id, arguments, opts})

      responses = SystemsRuntime.fetch_env!(:comma_web, :recommendation_collector_test_responses)

      case Map.fetch!(responses, tool_slug) do
        {:sleep, delay_ms, response} ->
          SystemsRuntime.Proc.send(test_pid, {:collector_worker, SystemsRuntime.Proc.self()})
          SystemsClock.sleep(delay_ms)
          response

        :crash ->
          SystemsRuntime.Proc.exit(SystemsRuntime.Proc.self(), :kill)

        response ->
          response
      end
    end
  end

  setup do
    keys = [
      :recommendation_composio_client_mod,
      :recommendation_composio_settings_mod,
      :recommendation_collector_test_pid,
      :recommendation_collector_test_responses
    ]

    previous = Map.new(keys, &{&1, SystemsRuntime.get_env(:comma_web, &1)})
    SystemsRuntime.put_env(:comma_web, :recommendation_composio_client_mod, Client)
    SystemsRuntime.put_env(:comma_web, :recommendation_composio_settings_mod, Settings)

    SystemsRuntime.put_env(
      :comma_web,
      :recommendation_collector_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> SystemsRuntime.delete_env(:comma_web, key)
        {key, value} -> SystemsRuntime.put_env(:comma_web, key, value)
      end)
    end)

    :ok
  end

  test "collects each enabled Composio source once with a pinned account and bounded recipe" do
    SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER" =>
        {:ok, %{"successful" => true, "data" => %{"notifications" => [1]}}},
      "LINEAR_RUN_QUERY_OR_MUTATION" =>
        {:ok, %{"successful" => true, "data" => %{"issues" => %{"nodes" => [2]}}}},
      "NOTION_FETCH_DATA" => {:ok, %{"successful" => true, "data" => %{"pages" => [3]}}}
    })

    assert {:ok, %{facts: facts, failures: []}} =
             RecommendationSourceCollector.collect(
               workspace(),
               [
                 source("github", "ca-github"),
                 source("linear", "ca-linear"),
                 source("notion", "ca-notion")
               ],
               now: ~U[2026-08-17 01:00:00Z]
             )

    assert Enum.map(facts, & &1["sourceId"]) == ["ca-github", "ca-linear", "ca-notion"]

    settle_receive(
      {:execute, "GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER", "grp-1",
       %{"per_page" => 12}, [connected_account_id: "ca-github", error_mode: :structured]}
    )

    settle_receive(
      {:execute, "LINEAR_RUN_QUERY_OR_MUTATION", "grp-1",
       %{
         "query_or_mutation" => linear_query,
         "variables" => %{"first" => 12}
       }, [connected_account_id: "ca-linear", error_mode: :structured]}
    )

    assert linear_query =~ "identifier"
    assert linear_query =~ "url"
    refute linear_query =~ "description"

    settle_receive(
      {:execute, "NOTION_FETCH_DATA", "grp-1", %{"get_pages" => true, "page_size" => 12},
       [connected_account_id: "ca-notion", error_mode: :structured]}
    )
  end

  test "keeps successful facts and reports provider and unsupported-source failures" do
    SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "LINEAR_RUN_QUERY_OR_MUTATION" =>
        {:ok, %{"successful" => true, "data" => %{"issues" => %{"nodes" => []}}}},
      "NOTION_FETCH_DATA" => {:ok, %{"successful" => false, "error" => "missing scope"}}
    })

    unsupported =
      source("feishu", "im-feishu")
      |> Map.merge(%{"kind" => "im_connect", "provider" => "feishu"})

    assert {:ok, %{facts: [fact], failures: failures}} =
             RecommendationSourceCollector.collect(workspace(), [
               source("linear", "ca-linear"),
               source("notion", "ca-notion"),
               unsupported
             ])

    assert fact["sourceId"] == "ca-linear"
    assert Enum.map(failures, & &1["sourceId"]) == ["ca-notion", "im-feishu"]
    assert Enum.any?(failures, &String.contains?(&1["message"], "missing scope"))
  end

  test "a crashed source does not discard healthy sources" do
    SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "LINEAR_RUN_QUERY_OR_MUTATION" =>
        {:ok, %{"successful" => true, "data" => %{"issues" => %{"nodes" => []}}}},
      "NOTION_FETCH_DATA" => :crash
    })

    assert {:ok, %{facts: [%{"sourceId" => "ca-linear"}], failures: [failure]}} =
             RecommendationSourceCollector.collect(workspace(), [
               source("linear", "ca-linear"),
               source("notion", "ca-notion")
             ])

    assert failure["sourceId"] == "ca-notion"
  end

  test "cancelling generation stops its in-flight source read" do
    SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "NOTION_FETCH_DATA" => {:sleep, 30_000, {:error, :unexpected_completion}}
    })

    owner =
      SystemsRuntime.Proc.spawn(fn ->
        RecommendationSourceCollector.collect(workspace(), [source("notion", "ca-notion")])
      end)

    settle_receive({:collector_worker, worker})
    monitor = SystemsRuntime.Proc.monitor(worker)
    SystemsRuntime.Proc.exit(owner, :kill)
    settle_receive({:DOWN, ^monitor, :process, ^worker, _})
  end

  test "derives stable Gmail web links so emails become citable inline-link evidence" do
    SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "GMAIL_FETCH_EMAILS" =>
        {:ok,
         %{
           "successful" => true,
           "data" => %{
             "messages" => [
               %{
                 "messageId" => "198f2ab4c7d3e011",
                 "messageText" => String.duplicate("body ", 400),
                 "payload" => %{"mimeType" => "text/html"},
                 "subject" => "Launch approval"
               },
               %{"threadId" => "198f2ab4c7d3e012"},
               %{"messageId" => "bad id with spaces"},
               %{"webUrl" => "https://provider.example/kept", "messageId" => "198f2ab4c7d3e013"},
               "not-a-map"
             ]
           }
         }}
    })

    assert {:ok, %{facts: [%{"data" => data}], failures: []}} =
             RecommendationSourceCollector.collect(workspace(), [source("gmail", "ca-gmail")])

    assert [by_message_id, by_thread_id, invalid_id, provider_url, "not-a-map"] =
             data["messages"]

    assert by_message_id["webUrl"] == "https://mail.google.com/mail/#all/198f2ab4c7d3e011"
    assert by_thread_id["webUrl"] == "https://mail.google.com/mail/#all/198f2ab4c7d3e012"
    refute Map.has_key?(invalid_id, "webUrl")
    assert provider_url["webUrl"] == "https://provider.example/kept"

    refute Map.has_key?(by_message_id, "payload")
    assert String.length(by_message_id["messageText"]) == 301
    assert String.ends_with?(by_message_id["messageText"], "…")
  end

  test "derives citable web links for Notion pages, GitHub notifications, and Drive files" do
    SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "NOTION_FETCH_DATA" =>
        {:ok,
         %{
           "successful" => true,
           "data" => %{
             "values" => [
               %{"id" => "4B8E7D0D-9f1a-4ed8-9d6b-a8d11080a812", "title" => "Q3 plan"},
               %{"id" => "not-a-uuid", "title" => "Broken"}
             ]
           }
         }},
      "GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER" =>
        {:ok,
         %{
           "successful" => true,
           "data" => %{
             "details" => [
               %{
                 "subject" => %{"url" => "https://api.github.com/repos/AFK-surf/Comma/pulls/884"}
               },
               %{
                 "subject" => %{"url" => "https://api.github.com/repos/AFK-surf/Comma/issues/12"}
               },
               %{
                 "subject" => %{"url" => "https://api.github.com/repos/AFK-surf/Comma/releases/9"}
               }
             ]
           }
         }},
      "GOOGLEDRIVE_LIST_FILES" =>
        {:ok,
         %{
           "successful" => true,
           "data" => %{
             "files" => [
               %{"id" => "1AbC_dEf-9", "name" => "Launch brief"},
               %{
                 "id" => "2XyZ",
                 "name" => "Spec",
                 "webViewLink" => "https://docs.google.com/document/d/2XyZ/edit"
               }
             ]
           }
         }}
    })

    assert {:ok, %{facts: facts, failures: []}} =
             RecommendationSourceCollector.collect(workspace(), [
               source("notion", "ca-notion"),
               source("github", "ca-github"),
               source("googledrive", "ca-drive")
             ])

    facts = Map.new(facts, &{&1["toolkit"], &1["data"]})

    assert [page, broken_page] = facts["notion"]["values"]
    assert page["webUrl"] == "https://www.notion.so/4b8e7d0d9f1a4ed89d6ba8d11080a812"
    refute Map.has_key?(broken_page, "webUrl")

    assert [pull, issue, release] = facts["github"]["details"]
    assert pull["webUrl"] == "https://github.com/AFK-surf/Comma/pull/884"
    assert issue["webUrl"] == "https://github.com/AFK-surf/Comma/issues/12"
    refute Map.has_key?(release, "webUrl")

    assert [plain_file, doc_file] = facts["googledrive"]["files"]
    assert plain_file["webUrl"] == "https://drive.google.com/open?id=1AbC_dEf-9"
    refute Map.has_key?(doc_file, "webUrl")
  end

  test "structurally bounds oversized provider data and retains only visible URL evidence" do
    visible_url = "https://linear.app/comma/issue/COMMA-143"
    excluded_url = "https://linear.app/comma/issue/COMMA-999"

    SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "LINEAR_RUN_QUERY_OR_MUTATION" =>
        {:ok,
         %{
           "successful" => true,
           "data" => %{
             "issues" => %{
               "nodes" => [
                 %{"identifier" => "COMMA-143", "url" => visible_url},
                 %{"description" => String.duplicate("x", 30_000) <> excluded_url}
               ]
             }
           }
         }}
    })

    assert {:ok, %{facts: [%{"data" => data}]}} =
             RecommendationSourceCollector.collect(workspace(), [source("linear", "ca-linear")])

    assert data["_comma"]["truncated"] == true
    assert get_in(data, ["value", "issues", "nodes", Access.at(0), "url"]) == visible_url
    assert Jason.encode!(data) =~ visible_url
    refute Jason.encode!(data) =~ excluded_url
    assert byte_size(Jason.encode!(data)) <= 12_000
  end

  test "slims Slack search matches to citable fields and keeps each permalink" do
    permalink = "https://comma-local.slack.com/archives/C01234567/p1786900000000200"

    SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "SLACK_SEARCH_FOR_MESSAGES_WITH_QUERY" =>
        {:ok,
         %{
           "successful" => true,
           "data" => %{
             "ok" => true,
             "messages" => %{
               "total" => 1,
               "matches" => [
                 %{
                   "channel" => %{
                     "id" => "C01234567",
                     "name" => "release",
                     "is_channel" => true,
                     "is_private" => false
                   },
                   "user" => "U_COMMA_DANA",
                   "username" => "dana",
                   "ts" => "1786900000.000200",
                   "text" => String.duplicate("decision ", 200),
                   "permalink" => permalink,
                   "blocks" => [%{"type" => "rich_text", "elements" => []}],
                   "attachments" => [%{"fallback" => String.duplicate("a", 2_000)}],
                   "previous" => %{"text" => "earlier context"},
                   "score" => 0.99
                 }
               ]
             }
           }
         }}
    })

    assert {:ok, %{facts: [%{"data" => data}]}} =
             RecommendationSourceCollector.collect(workspace(), [source("slack", "ca-slack")])

    assert [match] = get_in(data, ["messages", "matches"])
    assert match["permalink"] == permalink
    assert match["channel"] == %{"id" => "C01234567", "name" => "release"}
    assert match["username"] == "dana"
    assert match["ts"] == "1786900000.000200"
    assert String.ends_with?(match["text"], "…")
    refute Map.has_key?(match, "blocks")
    refute Map.has_key?(match, "attachments")
    refute Map.has_key?(match, "previous")
    assert get_in(data, ["messages", "total"]) == 1
  end

  test "truncation admits record links before prose so citable URLs survive" do
    # "description" sorts before "url" alphabetically; without link-priority
    # admission the oversized description would exhaust the record's budget
    # and truncation would drop its only citable URL.
    visible_url = "https://linear.app/comma/issue/COMMA-143"

    SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "LINEAR_RUN_QUERY_OR_MUTATION" =>
        {:ok,
         %{
           "successful" => true,
           "data" => %{
             "issues" => %{
               "nodes" => [
                 %{
                   "description" => String.duplicate("x", 30_000),
                   "identifier" => "COMMA-143",
                   "url" => visible_url
                 }
               ]
             }
           }
         }}
    })

    assert {:ok, %{facts: [%{"data" => data}]}} =
             RecommendationSourceCollector.collect(workspace(), [source("linear", "ca-linear")])

    assert data["_comma"]["truncated"] == true
    assert get_in(data, ["value", "issues", "nodes", Access.at(0), "url"]) == visible_url
  end

  test "a fact reports how many provider records the byte bound dropped" do
    issue = fn index ->
      %{
        "title" => String.duplicate("x", 1_000),
        "url" => "https://linear.app/comma/issue/COMMA-#{index}"
      }
    end

    respond = fn issues ->
      SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
        "LINEAR_RUN_QUERY_OR_MUTATION" =>
          {:ok, %{"successful" => true, "data" => %{"issues" => %{"nodes" => issues}}}}
      })
    end

    respond.([issue.(1)])

    assert {:ok, %{facts: [%{"bound" => bound}]}} =
             RecommendationSourceCollector.collect(workspace(), [source("linear", "ca-linear")])

    assert %{"truncated" => false, "kept" => 1, "dropped" => 0} = bound

    respond.(Enum.map(1..20, issue))

    assert {:ok, %{facts: [%{"bound" => bound, "data" => data}]}} =
             RecommendationSourceCollector.collect(workspace(), [source("linear", "ca-linear")])

    # The cut can leave a last record with only its link. That record is dropped.
    whole =
      data
      |> get_in(["value", "issues", "nodes"])
      |> Enum.count(&(String.length(&1["title"] || "") == 1_000))

    assert whole in 1..19
    assert bound["truncated"] == true
    assert bound["originalBytes"] > 12_000
    assert bound["kept"] == whole
    assert bound["dropped"] == 20 - whole
  end

  test "a member fact keeps every record's link and IDs outside the byte bound" do
    source = %{"appId" => "outlook", "appName" => "Outlook", "connectionId" => "ms-mail"}
    now = SystemsClock.utc_now()

    # Graph message IDs run to about 150 characters, and each link repeats one.
    mail = fn n, subject ->
      id = "AQMkADAwATM0MDAAMS1iNTcw" <> String.duplicate("A", 120) <> "#{1000 + n}"

      %{
        "messageId" => id,
        "threadId" => "AQMkADAwATM0MDAAMS1" <> String.duplicate("B", 96) <> "#{1000 + n}",
        "subject" => subject,
        "sender" => "sender#{n}@example.com",
        "messageTimestamp" => "2026-10-19T08:00:00Z",
        "webUrl" => "https://outlook.live.com/owa/?ItemID=#{URI.encode_www_form(id)}&exvsurl=1"
      }
    end

    messages = for n <- 1..40, do: mail.(n, "Matter #{n}")
    data = %{"messages" => messages, "memberRelation" => "your_recent_inbox"}

    assert {:ok, fact, []} = RecommendationSourceCollector.member_fact(source, data, %{}, now)
    assert fact["data"] == data
    assert %{"truncated" => false, "kept" => 40, "dropped" => 0} = fact["bound"]

    # Facts beyond the bound still drop from the tail. Each kept record keeps its
    # identity, and the source reports the cut as a partial read.
    long = for n <- 1..40, do: mail.(n, "Matter #{n} " <> String.duplicate("x", 600))
    data = %{"messages" => long, "memberRelation" => "your_recent_inbox"}

    assert {:ok, fact, [:member_source_truncated]} =
             RecommendationSourceCollector.member_fact(source, data, %{}, now)

    kept = get_in(fact["data"], ["value", "messages"])
    whole = 40 - fact["bound"]["dropped"]
    assert whole in 1..39
    assert Enum.take(kept, whole) == Enum.take(long, whole)

    # No partial tail record survives: every kept record stays intact so shifting
    # the byte boundary never drifts a record's facts or fingerprint.
    assert kept == Enum.take(long, whole)
  end

  test "the collection sub-deadline bounds a multi-wave provider fan-out" do
    SystemsRuntime.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER" =>
        {:sleep, 500, {:ok, %{"successful" => true, "data" => %{"notifications" => []}}}}
    })

    sources = for id <- 1..5, do: source("github", "ca-github-#{id}")
    started_at = SystemsClock.monotonic_time(:millisecond)

    assert {:ok, %{facts: [], failures: failures}} =
             RecommendationSourceCollector.collect(workspace(), sources,
               collection_timeout_ms: 50,
               max_concurrency: 2,
               source_timeout_ms: 1_000
             )

    elapsed_ms = SystemsClock.monotonic_time(:millisecond) - started_at
    # The terminal deadline outcome is the discriminating contract; the broad
    # wall-clock cap catches a hang without depending on scheduler precision.
    assert elapsed_ms < 2_000
    assert Enum.map(failures, & &1["sourceId"]) == Enum.map(sources, & &1["connectionId"])
    assert Enum.all?(failures, &String.contains?(&1["message"], "collection_deadline_exceeded"))
  end

  test "Slack member collection keeps direct messages, thread replies, and buried mentions intact when bot mentions carry multi-kilobyte text" do
    now = ~U[2026-11-20 02:45:00Z]
    slack_source = %{"appId" => "slack", "appName" => "Slack", "connectionId" => "slack-member"}

    mentions =
      for i <- 1..27 do
        text =
          if i <= 10 do
            String.duplicate("诊断日志输出行 #{i} — build step output details.\n", 80) <>
              "<@UME1> 请确认发布第 #{i} 批次"
          else
            "<@UME1> review item #{i}"
          end

        %{
          "text" => text,
          "user" => "UBOT#{i}",
          "username" => "bot-#{i}",
          "ts" => "1795140#{String.pad_leading("#{i}", 3, "0")}.000100",
          "channel" => %{"id" => "C100"},
          "permalink" => "https://team.slack.com/archives/C100/p1795140#{i}"
        }
      end

    direct =
      for d <- 1..2 do
        %{
          "text" => "私信确认事项 #{d}：今天能批一下吗？",
          "user" => "UDM#{d}",
          "username" => "colleague-#{d}",
          "ts" => "1795130#{String.pad_leading("#{d}", 3, "0")}.000100",
          "channel" => %{"id" => "D#{d}", "is_im" => true},
          "permalink" => "https://team.slack.com/archives/D#{d}/p1795130#{d}"
        }
      end

    threads =
      for t <- 1..20 do
        text =
          if t == 20,
            do: "PR #6140 已合并上线，无需继续跟进",
            else: "参与线程回复 #{t}：" <> String.duplicate("上下文说明", 40)

        %{
          "text" => text,
          "user" => "UTH#{t}",
          "username" => "peer-#{t}",
          "ts" => "1795120#{String.pad_leading("#{t}", 3, "0")}.000100",
          "channel" => %{"id" => "C200"},
          "permalink" =>
            "https://team.slack.com/archives/C200/p1795120#{t}?thread_ts=1795100#{String.pad_leading("#{t}", 3, "0")}.000100"
        }
      end

    request = fn "GET", url, _opts ->
      uri = URI.parse(url)
      params = URI.decode_query(uri.query || "")

      case {uri.path, params["query"]} do
        {"/api/auth.test", _} ->
          {:ok, %{"ok" => true, "user_id" => "UME1", "team_id" => "T1"}}

        {"/api/search.messages", "<@UME1>" <> _} ->
          {:ok,
           %{"ok" => true, "messages" => %{"matches" => mentions, "paging" => %{"pages" => 1}}}}

        {"/api/search.messages", "to:me" <> _} ->
          {:ok,
           %{"ok" => true, "messages" => %{"matches" => direct, "paging" => %{"pages" => 1}}}}

        {"/api/search.messages", "is:thread" <> _} ->
          {:ok,
           %{"ok" => true, "messages" => %{"matches" => threads, "paging" => %{"pages" => 1}}}}

        {"/api/users.info", _} ->
          {:ok, %{"ok" => true, "user" => %{"name" => "peng", "profile" => %{}}}}
      end
    end

    assert {:ok, data, subject} = CommaWeb.RecommendationSlackMemberSource.read(request, now)

    first_relations =
      data["messages"]["matches"] |> Enum.take(3) |> Enum.map(& &1["memberRelation"])

    assert first_relations == ~w(mentioned_you direct_message_to_you replied_in_your_thread)

    assert {:ok, fact, []} =
             RecommendationSourceCollector.member_fact(slack_source, data, subject, now)

    assert %{"truncated" => false, "kept" => 49, "dropped" => 0} = fact["bound"]

    candidates = CommaWeb.MemberSourceIngest.items([fact])["slack-member"]
    assert length(candidates) == 49

    by_rel = Enum.group_by(candidates, & &1["relationship"])
    assert length(by_rel["mentioned_you"]) == 27
    assert length(by_rel["direct_message_to_you"]) == 2
    assert length(by_rel["replied_in_your_thread"]) == 20

    buried_first =
      Enum.find(candidates, &(&1["url"] == "https://team.slack.com/archives/C100/p17951401"))

    assert buried_first["title"] =~ "请确认发布第 1 批次"
    assert buried_first["excerpt"] =~ "请确认发布第 1 批次"

    merged_reply =
      Enum.find(
        candidates,
        &(&1["url"] ==
            "https://team.slack.com/archives/C200/p179512020?thread_ts=1795100020.000100")
      )

    assert merged_reply["excerpt"] =~ "PR #6140 已合并上线"
  end

  test "a Slack mention also posted where the member's work is keeps its relation and full text" do
    now = ~U[2026-11-20 02:45:00Z]
    long = String.duplicate("Release log line. ", 40) <> "<@UME1> please approve release 42."
    assert String.length(long) > 700
    first = slack_match("1", "<@UME1> short note")
    buried = slack_match("2", long)

    request =
      slack_request(%{"<@UME1>" => [first, buried], "in:#releases" => [buried]})

    assert {:ok, data, _subject} =
             CommaWeb.RecommendationSlackMemberSource.read(request, now, nil,
               targets: %{"channels" => ["releases"]}
             )

    matches = data["messages"]["matches"]
    assert [match] = Enum.filter(matches, &(&1["permalink"] == buried["permalink"]))
    assert match["memberRelation"] == "mentioned_you"
    assert match["text"] == long
  end

  test "a Slack mention at the end of one long line keeps the mention after the preamble" do
    now = ~U[2026-11-20 02:45:00Z]
    long = "Report header\n" <> String.duplicate("a", 1_500) <> "<@UME1> please approve"
    request = slack_request(%{"<@UME1>" => [slack_match("1", long)]})

    assert {:ok, data, _subject} = CommaWeb.RecommendationSlackMemberSource.read(request, now)
    assert [%{"text" => text}] = data["messages"]["matches"]
    assert String.length(text) <= 1_200
    assert [head, tail] = String.split(text, "\n…\n")
    assert head == String.slice(long, 0, String.length(head))
    # The tail is the message's end, apart from the head.
    assert String.ends_with?(tail, "<@UME1> please approve")
    assert String.ends_with?(long, tail)
    assert String.length(head) + String.length(tail) <= String.length(long)
  end

  test "unrelated Outlook mail or calendar churn does not drift surviving items' context or prompt_context" do
    source = %{"appId" => "outlook", "appName" => "Outlook", "connectionId" => "ms-mail"}
    now = ~U[2026-11-25 08:30:00Z]

    mail = fn n ->
      id = "msg-#{n}"

      body =
        "Apple Developer invite #{n}. " <> String.duplicate("Details about access and role. ", 50)

      %{
        "messageId" => id,
        "threadId" => "thread-#{n}",
        "subject" => "Invite #{n}",
        "sender" => "noreply@example.com",
        "messageTimestamp" => "2026-11-25T02:23:43Z",
        "webUrl" => "https://outlook.office365.com/owa/?ItemID=#{id}",
        "context" =>
          CommaWeb.RecommendationSourceContext.attach(%{"body" => body}, ["body"])["context"]
          |> Map.put("attachments", "unread")
      }
    end

    event = fn n ->
      %{
        "id" => "evt-#{n}",
        "subject" => "Standup #{n}",
        "webUrl" => "https://outlook.office365.com/owa/?itemid=evt-#{n}",
        "context" =>
          CommaWeb.RecommendationSourceContext.attach(%{"bodyPreview" => "Room #{n}"}, [
            "bodyPreview"
          ])["context"]
      }
    end

    data_before = %{
      "messages" => Enum.map(1..40, mail),
      "items" => Enum.map(1..20, event),
      "memberRelation" => "your_recent_inbox_and_upcoming_events"
    }

    # One new mail arrives and one calendar event passes `now`.
    data_after = %{
      "messages" => [mail.(41) | Enum.map(1..40, mail)],
      "items" => Enum.map(2..20, event),
      "memberRelation" => "your_recent_inbox_and_upcoming_events"
    }

    assert {:ok, fact_before, []} =
             RecommendationSourceCollector.member_fact(source, data_before, %{}, now)

    assert {:ok, fact_after, []} =
             RecommendationSourceCollector.member_fact(source, data_after, %{}, now)

    items_before =
      Map.new(CommaWeb.MemberSourceIngest.items([fact_before])["ms-mail"], &{&1["url"], &1})

    items_after =
      Map.new(CommaWeb.MemberSourceIngest.items([fact_after])["ms-mail"], &{&1["url"], &1})

    for n <- 1..40 do
      url = "https://outlook.office365.com/owa/?ItemID=msg-#{n}"
      assert items_before[url] == items_after[url]
      assert items_before[url]["context"]["attachments"] == "unread"
    end
  end

  test "unrelated long multi-byte Slack messages do not drift surviving items' excerpt or Routine budget" do
    source = %{"appId" => "slack", "appName" => "Slack", "connectionId" => "slack-cjk"}
    now = ~U[2026-11-25 08:30:00Z]

    long_match = fn n ->
      text =
        "第#{n}条中文长消息：" <> String.duplicate("这是一段用于验证多字节消息体稳定性的上下文内容。", 48)

      %{
        "text" => text,
        "ts" => "1795140#{String.pad_leading("#{n}", 3, "0")}.000100",
        "permalink" => "https://team.slack.com/archives/C100/p1795140#{n}",
        "memberRelation" => "mentioned_you"
      }
    end

    # 70 long CJK messages exceed 196,608 encoded bytes; adding 10 more must not
    # alter the stored excerpt or prompt_context of surviving messages.
    before_matches = Enum.map(1..70, long_match)
    after_matches = Enum.map(1..80, long_match)

    assert {:ok, fact_before, []} =
             RecommendationSourceCollector.member_fact(
               source,
               %{
                 "messages" => %{"matches" => before_matches},
                 "memberRelation" => "involves_you"
               },
               %{"provider_user_id" => "UME1"},
               now
             )

    assert {:ok, fact_after, []} =
             RecommendationSourceCollector.member_fact(
               source,
               %{"messages" => %{"matches" => after_matches}, "memberRelation" => "involves_you"},
               %{"provider_user_id" => "UME1"},
               now
             )

    items_before =
      Map.new(CommaWeb.MemberSourceIngest.items([fact_before])["slack-cjk"], &{&1["url"], &1})

    items_after =
      Map.new(CommaWeb.MemberSourceIngest.items([fact_after])["slack-cjk"], &{&1["url"], &1})

    for n <- 1..70 do
      url = "https://team.slack.com/archives/C100/p1795140#{n}"
      assert items_before[url] == items_after[url]
    end

    # Routine model_candidates still bounds total per-source excerpt bytes to 196,608.
    context =
      Comma.RecommendationDraft.prepare(
        [fact_after],
        Comma.Recommendations.source_evidence([fact_after]),
        "member"
      )

    model_candidates = Comma.RecommendationMemberSelection.model_candidates(context)

    total_excerpt_bytes =
      Enum.reduce(model_candidates, 0, fn item, acc ->
        acc + max(byte_size(Jason.encode!(item["excerpt"] || "")) - 2, 0)
      end)

    assert total_excerpt_bytes <= 196_608
  end

  defp slack_match(id, text) do
    %{
      "text" => text,
      "user" => "UBOT#{id}",
      "username" => "bot-#{id}",
      "ts" => "1795140#{String.pad_leading(id, 3, "0")}.000100",
      "channel" => %{"id" => "C100"},
      "permalink" => "https://team.slack.com/archives/C100/p1795140#{id}"
    }
  end

  # Slack's search answers each query that starts with a key of `results`.
  defp slack_request(results) do
    fn "GET", url, _opts ->
      uri = URI.parse(url)
      params = URI.decode_query(uri.query || "")

      case uri.path do
        "/api/auth.test" ->
          {:ok, %{"ok" => true, "user_id" => "UME1", "team_id" => "T1"}}

        "/api/search.messages" ->
          matches =
            Enum.find_value(results, [], fn {prefix, matches} ->
              if String.starts_with?(params["query"], prefix), do: matches
            end)

          {:ok,
           %{"ok" => true, "messages" => %{"matches" => matches, "paging" => %{"pages" => 1}}}}

        "/api/users.info" ->
          {:ok, %{"ok" => true, "user" => %{"name" => "peng", "profile" => %{}}}}
      end
    end
  end

  defp workspace,
    do: %{"default_group_id" => "grp-1", "salix_tenant_id" => "ten-1"}

  defp source(toolkit, connection_id) do
    %{
      "appId" => toolkit,
      "appName" => String.capitalize(toolkit),
      "connectionId" => connection_id,
      "enabled" => true,
      "kind" => "composio",
      "toolkit" => toolkit
    }
  end
end
