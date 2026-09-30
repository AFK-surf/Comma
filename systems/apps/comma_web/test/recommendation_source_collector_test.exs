defmodule CommaWeb.RecommendationSourceCollectorTest do
  use ExUnit.Case, async: false

  alias CommaWeb.RecommendationSourceCollector

  defmodule Settings do
    def settings(_tenant_id), do: {:ok, %{"api_key" => "test"}}
  end

  defmodule Client do
    def execute_tool(_settings, tool_slug, group_id, arguments, opts) do
      test_pid = Application.fetch_env!(:comma_web, :recommendation_collector_test_pid)
      send(test_pid, {:execute, tool_slug, group_id, arguments, opts})

      responses = Application.fetch_env!(:comma_web, :recommendation_collector_test_responses)

      case Map.fetch!(responses, tool_slug) do
        {:sleep, delay_ms, response} ->
          send(test_pid, {:collector_worker, self()})
          Process.sleep(delay_ms)
          response

        :crash ->
          Process.exit(self(), :kill)

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

    previous = Map.new(keys, &{&1, Application.get_env(:comma_web, &1)})
    Application.put_env(:comma_web, :recommendation_composio_client_mod, Client)
    Application.put_env(:comma_web, :recommendation_composio_settings_mod, Settings)
    Application.put_env(:comma_web, :recommendation_collector_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:comma_web, key)
        {key, value} -> Application.put_env(:comma_web, key, value)
      end)
    end)

    :ok
  end

  test "collects each enabled Composio source once with a pinned account and bounded recipe" do
    Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
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

    assert_receive {:execute, "GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER", "grp-1",
                    %{"per_page" => 12},
                    [connected_account_id: "ca-github", error_mode: :structured]}

    assert_receive {:execute, "LINEAR_RUN_QUERY_OR_MUTATION", "grp-1",
                    %{
                      "query_or_mutation" => linear_query,
                      "variables" => %{"first" => 12}
                    }, [connected_account_id: "ca-linear", error_mode: :structured]}

    assert linear_query =~ "identifier"
    assert linear_query =~ "url"
    refute linear_query =~ "description"

    assert_receive {:execute, "NOTION_FETCH_DATA", "grp-1",
                    %{"get_pages" => true, "page_size" => 12},
                    [connected_account_id: "ca-notion", error_mode: :structured]}
  end

  test "keeps successful facts and reports provider and unsupported-source failures" do
    Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
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
    Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
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
    Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "NOTION_FETCH_DATA" => {:sleep, 30_000, {:error, :unexpected_completion}}
    })

    owner =
      spawn(fn ->
        RecommendationSourceCollector.collect(workspace(), [source("notion", "ca-notion")])
      end)

    assert_receive {:collector_worker, worker}, 1_000
    monitor = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
  end

  test "derives stable Gmail web links so emails become citable inline-link evidence" do
    Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
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
    Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
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

    Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
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

    Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
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

    Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
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
      Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
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

  test "the collection sub-deadline bounds a multi-wave provider fan-out" do
    Application.put_env(:comma_web, :recommendation_collector_test_responses, %{
      "GITHUB_LIST_NOTIFICATIONS_FOR_THE_AUTHENTICATED_USER" =>
        {:sleep, 500, {:ok, %{"successful" => true, "data" => %{"notifications" => []}}}}
    })

    sources = for id <- 1..5, do: source("github", "ca-github-#{id}")
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{facts: [], failures: failures}} =
             RecommendationSourceCollector.collect(workspace(), sources,
               collection_timeout_ms: 50,
               max_concurrency: 2,
               source_timeout_ms: 1_000
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    # The terminal deadline outcome is the discriminating contract; the broad
    # wall-clock cap catches a hang without depending on scheduler precision.
    assert elapsed_ms < 2_000
    assert Enum.map(failures, & &1["sourceId"]) == Enum.map(sources, & &1["connectionId"])
    assert Enum.all?(failures, &String.contains?(&1["message"], "collection_deadline_exceeded"))
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
