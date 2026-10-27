defmodule CommaWeb.LocalRecommendationFlowTest do
  require SystemsRuntime.Proc

  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  use Oban.Testing, repo: Comma.Repo
  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test
  alias Comma.Recommendations
  alias Comma.Workers.RecommendationGenerate
  alias CommaWeb.{RecommendationRuntime, RecommendationSourceCollector}

  defmodule DraftLLM do
    use Agent

    def start_link(owner),
      do:
        Agent.start_link(fn -> %{owner: owner, mode: :normal, requests: [], archives: []} end,
          name: __MODULE__
        )

    def mode(mode), do: Agent.update(__MODULE__, &Map.put(&1, :mode, mode))
    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    def archives, do: Agent.get(__MODULE__, & &1.archives)

    def record(fact),
      do: Agent.update(__MODULE__, &Map.update!(&1, :archives, fn all -> [fact | all] end))

    # A published briefing wakes the Router, whose turn reaches this model too,
    # as an encoded provider request, whenever it gets to run. Only Comma's own
    # model calls (message lists) are recorded, so `requests/0` does not depend
    # on whether that turn ran before the test reads it.
    def complete_stream(messages, tools, _delta, opts) do
      state =
        Agent.get_and_update(__MODULE__, fn state ->
          if is_list(messages),
            do: {state, %{state | requests: [{messages, tools, opts} | state.requests]}},
            else: {state, state}
        end)

      if state.mode == :hold do
        SystemsRuntime.Proc.send(state.owner, {:model_waiting, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
          :continue -> :ok
        end
      end

      case state.mode do
        :deepseek_chat ->
          transport = fn _url, request ->
            body = Jason.decode!(request[:body])
            SystemsRuntime.Proc.send(state.owner, {:routine_provider_request, body})

            {status, payload} =
              if get_in(body, ["response_format", "type"]) in [nil, "text", "json_object"] do
                delta = %{
                  "choices" => [%{"delta" => %{"content" => Jason.encode!(draft(messages))}}]
                }

                {200, "data: " <> Jason.encode!(delta) <> "\n\ndata: [DONE]\n\n"}
              else
                {400, Jason.encode!(%{"error" => %{"message" => "Unsupported response_format"}})}
              end

            {:cont, {_, response}} =
              request[:into].({:data, payload}, {Req.new(), Req.Response.new(status: status)})

            {:ok, response}
          end

          SalixLlm.OpenAIChat.complete_stream(
            messages,
            tools,
            fn _ -> :ok end,
            Map.put(opts, "transport", transport)
          )

        :reordered ->
          {:final, Jason.encode!(Map.update!(draft(messages), "selected", &Enum.reverse/1))}

        :malformed_rows ->
          [first | rest] = draft(messages)["selected"]

          rows =
            [first, %{"id" => "unknown", "recommendation" => "Review unknown work"}] ++
              [%{first | "recommendation" => "Review it again"}] ++
              Enum.map(rest, fn row ->
                if row["recommendation"] == "Review Second",
                  do: %{row | "recommendation" => "Review https://example.com/second"},
                  else: row
              end)

          {:final, Jason.encode!(%{"selected" => rows})}

        :unknown_rows ->
          {:final,
           Jason.encode!(%{
             "selected" => [%{"id" => "unknown", "recommendation" => "Review unknown work"}]
           })}

        :invalid ->
          {:final, "not JSON"}

        # MiniMax writes its reasoning into the answer before the object.
        :thinking ->
          {:final, "<think>Rank the work.</think>\n\n" <> Jason.encode!(draft(messages))}

        :fenced ->
          {:final, "```json\n" <> Jason.encode!(draft(messages)) <> "\n```"}

        :failed ->
          {:error, %{"category" => "transport"}}

        :unrelated ->
          input = Jason.decode!(List.last(messages).content)
          candidate = hd(input["candidates"])

          parts = [
            %{"text" => "Organize a birthday party using "},
            %{"reference" => candidate["id"], "label" => "PAY-1"}
          ]

          {:final,
           Jason.encode!(%{
             "title" => "Your work",
             "paragraphs" => [parts],
             "routines" => [
               %{
                 "source" => candidate["source"],
                 "layout" => "text",
                 "items" => [
                   %{
                     "parts" => parts,
                     "action" => %{
                       "type" => "open_task_form",
                       "label" => "Plan party",
                       "prompt" => "Organize a birthday party"
                     }
                   }
                 ]
               }
             ]
           })}

        _ ->
          {:final, Jason.encode!(draft(messages))}
      end
    end

    # The Router's judgment: work items become suggestions, "No work" is omitted.
    # An attention judgment rates an approval due today critical and a review
    # request without a deadline high.
    defp draft(messages) do
      input = Jason.decode!(List.last(messages).content)

      cond do
        Map.has_key?(input["contentSchema"]["properties"], "entries") -> portrait(input)
        Map.has_key?(input["contentSchema"]["properties"], "most_urgent") -> attention(input)
        true -> member_or_generic(input)
      end
    end

    # The portrait cites the member's first own message; an entry with made-up
    # evidence must not survive.
    defp portrait(input) do
      [own | _] = input["ownMessages"]

      %{
        "entries" => [
          %{
            "kind" => "duty",
            "text" => "renews the patrol token",
            "evidence" => [own["permalink"]]
          },
          %{
            "kind" => "duty",
            "text" => "approves payroll",
            "evidence" => ["https://example.com/x"]
          }
        ]
      }
    end

    defp attention(input) do
      if true do
        rated =
          Enum.map(input["candidates"], fn candidate ->
            cond do
              # A notice that names no request: the evidence cannot tell
              # whether the member must act, and the model names it first.
              candidate["excerpt"] =~ "status changed" ->
                {"unclear", candidate}

              # A GitHub notification with only its reason: like the real
              # model, the judge cannot tell whether the member must act.
              (get_in(candidate, ["context", "text"]) || "") =~ "reason: author" and
                  not ((get_in(candidate, ["context", "text"]) || "") =~ "state:") ->
                {"unclear", candidate}

              # A deletion notice: the judge needs the deadline, which only
              # the full text holds.
              candidate["excerpt"] =~ "Account notice" ->
                if (get_in(candidate, ["context", "text"]) || "") =~ "permanently deleted",
                  do: {"critical", candidate},
                  else: {"unclear", candidate}

              candidate["excerpt"] =~ "approve" or
                  (get_in(candidate, ["context", "text"]) || "") =~ "approval tomorrow" ->
                {"critical", candidate}

              candidate["excerpt"] =~ "review" ->
                {"high", candidate}

              true ->
                {"low", candidate}
            end
          end)

        case Enum.min_by(rated, fn {level, _} -> level_rank(level) end, fn -> nil end) do
          nil ->
            %{"most_urgent" => nil}

          {level, candidate} ->
            # A reminder is a later step of the newest earlier matter.
            continues =
              if candidate["excerpt"] =~ "Reminder:",
                do: get_in(input, ["matters", Access.at(0), "id"])

            %{
              "most_urgent" => %{
                "id" => candidate["id"],
                "continues" => continues,
                "urgency" => level,
                "message" =>
                  "Milo is waiting for your launch approval today. Want me to draft the reply?"
              }
            }
        end
      end
    end

    defp level_rank("unclear"), do: -1

    defp level_rank(level),
      do: Enum.find_index(CommaWeb.RecommendationRenderer.attention_urgencies(), &(&1 == level))

    defp member_or_generic(input) do
      if Map.has_key?(input["contentSchema"]["properties"], "selected") do
        %{
          "selected" =>
            for candidate <- input["candidates"], candidate["title"] != "No work" do
              %{
                "id" => candidate["id"],
                "recommendation" => "Review " <> String.slice(candidate["title"], 0, 60)
              }
            end
            |> Enum.take(18)
        }
      else
        source = Enum.find(input["sources"], &(&1["app"] == "Slack")) || hd(input["sources"])
        reference = hd(source["references"])["id"]

        %{
          "title" => "Good morning",
          "paragraphs" => [
            [
              %{"text" => "Review "},
              %{"reference" => reference, "label" => "Q3 plan"},
              %{"text" => " before the next discussion."}
            ]
          ],
          "routines" => [
            %{
              "source" => source["source"],
              "layout" => "text",
              "items" => [
                %{
                  "parts" => [
                    %{"text" => "Review "},
                    %{"reference" => reference, "label" => "Q3 plan"}
                  ],
                  "action" => %{
                    "type" => "open_task_form",
                    "label" => "Review Q3 plan",
                    "prompt" => "Review the Q3 plan before the next discussion."
                  }
                }
              ]
            }
          ]
        }
      end
    end
  end

  defmodule CrashedSource do
    def execute_tool(_settings, "NOTION_FETCH_DATA", _group, _args, _opts),
      do: SystemsRuntime.Proc.exit(SystemsRuntime.Proc.self(), :kill)

    def execute_tool(settings, tool, group, args, opts),
      do: SalixWeb.LocalComposioMock.execute_tool(settings, tool, group, args, opts)
  end

  defmodule AllCrashedSources do
    def execute_tool(_settings, _tool, _group, _args, _opts),
      do: SystemsRuntime.Proc.exit(SystemsRuntime.Proc.self(), :kill)
  end

  defmodule MemberGmail do
    def get(_tenant) do
      state = SystemsRuntime.get_env(:comma_web, :member_gmail_test, %{})
      {:ok, if(state[:webhook], do: %{"webhook_configured" => true}, else: %{})}
    end

    def get_connected_account(_settings, id, _opts \\ []) do
      %{workspace: workspace} = SystemsRuntime.fetch_env!(:comma_web, :member_gmail_test)

      {:ok,
       %{
         "id" => id,
         "user_id" => workspace["default_group_id"],
         "toolkit" => %{"slug" => "gmail"},
         "status" => "ACTIVE"
       }}
    end

    def upsert_trigger(_settings, group, account, slug, config) do
      state = SystemsRuntime.fetch_env!(:comma_web, :member_gmail_test)
      SystemsRuntime.Proc.send(state.owner, {:upsert_trigger, group, account, slug, config})
      {:ok, %{"trigger_id" => "ti_member_gmail"}}
    end

    def create_proxy_session(_settings, group, account, "gmail", _opts) do
      state = SystemsRuntime.fetch_env!(:comma_web, :member_gmail_test)
      true = state.account == account and state.workspace["default_group_id"] == group
      {:ok, "member-gmail-session"}
    end

    def delete_proxy_session(_settings, "member-gmail-session"), do: :ok

    def proxy_execute(_settings, "member-gmail-session", request, _opts) do
      %{"toolkit_slug" => "gmail", "method" => "GET", "endpoint" => endpoint} = request
      "https://gmail.googleapis.com/gmail/v1/users/me" <> path = endpoint
      state = SystemsRuntime.fetch_env!(:comma_web, :member_gmail_test)

      message = fn id, subject, body ->
        %{
          "id" => id,
          "threadId" => id,
          "internalDate" => "1000",
          "labelIds" => ~w(INBOX UNREAD IMPORTANT),
          "payload" => %{
            "mimeType" => "text/plain",
            "headers" => [%{"name" => "Subject", "value" => subject}],
            "body" => %{"data" => Base.url_encode64(body, padding: false)}
          }
        }
      end

      data =
        case URI.parse(path).path do
          "/profile" ->
            %{"emailAddress" => "member@example.com"}

          "/threads" ->
            stalled = if state[:stalled], do: "stalled", else: "missing"
            arrived = Enum.map(Map.get(state, :arrived, []), &%{"id" => &1.id})
            %{"threads" => arrived ++ [%{"id" => "readable"}, %{"id" => stalled}]}

          "/threads/stalled" ->
            SystemsClock.sleep(2_000)
            %{"id" => "stalled", "messages" => [message.("stalled", "Late", "Late mail")]}

          "/threads/readable" ->
            %{
              "id" => "readable",
              "messages" => [
                message.("readable", "Review release", "Please review the release plan.")
              ]
            }

          "/threads/missing" ->
            %{"id" => "missing", "messages" => [message.("missing", "Context missing", "")]}

          "/threads/" <> id ->
            mail = Enum.find(state.arrived, &(&1.id == id))
            %{"id" => id, "messages" => [message.(id, mail.subject, mail.body)]}

          # The full read of one message, with its thread above.
          "/messages/" <> id ->
            if state[:full_reads], do: SystemsRuntime.Proc.send(state.owner, {:full_read, id})
            mail = Enum.find(state.arrived, &(&1.id == id))
            message.(id, mail.subject, mail.body)
        end

      {:ok, %{"status" => 200, "data" => data}}
    end
  end

  defmodule MemberSlack do
    def get(_tenant), do: {:ok, %{}}
    def list_connected_accounts(_settings, _group), do: {:ok, []}
    def list_connected_accounts_all(_settings, _group, _opts \\ []), do: {:ok, []}

    def get_connected_account(_settings, id) do
      %{workspace: workspace} = SystemsRuntime.fetch_env!(:comma_web, :member_slack_test)

      {:ok,
       %{
         "id" => id,
         "user_id" => workspace["default_group_id"],
         "toolkit" => %{"slug" => "slack"},
         "status" => "ACTIVE"
       }}
    end

    # The managed Slack member read, over Req, answered by this test's state.
    # Each request reports its Web API path to the test when asked.
    def call(conn) do
      conn = Plug.Conn.fetch_query_params(conn)
      path = "/api/" <> List.last(String.split(conn.request_path, "/"))
      state = SystemsRuntime.fetch_env!(:comma_web, :member_slack_test)
      if state[:reads], do: SystemsRuntime.Proc.send(state.reads, {:slack_read, path})

      case data(path, conn.query_params["query"], state) do
        :unavailable -> Plug.Conn.send_resp(conn, 502, "")
        data -> Req.Test.json(conn, data)
      end
    end

    defp data(path, query, state) do
      case {path, query} do
        {"/api/auth.test", nil} ->
          Map.merge(
            %{"ok" => true, "user_id" => "UCOMMALOCAL", "team_id" => "TCOMMALOCAL"},
            Map.get(state, :auth, %{})
          )

        {"/api/users.info", nil} ->
          %{"ok" => true, "user" => %{"name" => "comma-local-user"}}

        {"/api/search.messages", _query} when is_map_key(state, :search_error) ->
          %{"ok" => false, "error" => state.search_error}

        {"/api/search.messages", "<@UCOMMALOCAL> after:" <> _} ->
          search([
            %{
              "text" => "https://example.com/plan\n<@UCOMMALOCAL> review the plan",
              "next" => %{"text" => "The revised plan is ready for review.", "ts" => "101"},
              "user" => "U999",
              "permalink" => "https://team.slack.com/archives/C123/p100"
            },
            %{
              "text" => "Unrelated team chatter",
              "user" => "U999",
              "permalink" => "https://team.slack.com/archives/C123/p200"
            }
          ])

        {"/api/search.messages", "to:me after:" <> _} when is_map_key(state, :direct_error) ->
          :unavailable

        {"/api/search.messages", "to:me after:" <> _} ->
          if owner = state[:hold] do
            SystemsRuntime.Proc.send(owner, {:source_waiting, SystemsRuntime.Proc.self()})

            SystemsRuntime.Proc.receive do
              :continue -> :ok
            end
          end

          search(Map.get(state, :direct, []))

        {"/api/search.messages", "is:thread with:<@UCOMMALOCAL> after:" <> _} ->
          search(Map.get(state, :threads, []))

        # The member's own messages name the channels where they work.
        {"/api/search.messages", "from:<@UCOMMALOCAL> after:" <> _} ->
          search(Map.get(state, :own, []))

        {"/api/search.messages", "in:#" <> _} ->
          search(Map.get(state, :channel, []))
      end
    end

    defp search(matches), do: %{"ok" => true, "messages" => %{"matches" => matches}}
  end

  # The member's GitHub reads, answered by this test's state: no assigned
  # work, review requests, mentions or open pull requests, only the inbox
  # and the issues and pull requests that it names.
  defmodule MemberGitHub do
    def call(conn) do
      state = SystemsRuntime.fetch_env!(:comma_web, :member_github_test)

      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, %{"id" => 1, "login" => "comma-local-user"})

        "/issues" ->
          Req.Test.json(conn, [])

        "/search/issues" ->
          Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})

        "/notifications" ->
          Req.Test.json(conn, state.notifications)

        "/graphql" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"query" => query} = request = Jason.decode!(body)
          variables = request["variables"] || %{}

          if query =~ "search(" do
            Req.Test.json(conn, %{"data" => %{"search" => %{"nodes" => []}}})
          else
            data =
              variables
              |> Map.keys()
              |> Enum.flat_map(fn
                "k" <> index ->
                  key =
                    "#{variables["o" <> index]}/#{variables["n" <> index]}#" <>
                      "#{variables["k" <> index]}"

                  [{"s" <> index, %{"issueOrPullRequest" => state[:subjects][key]}}]

                _ ->
                  []
              end)
              |> Map.new()

            Req.Test.json(conn, %{"data" => data})
          end
      end
    end
  end

  # Collection tests observe the durable handoff, not a second LLM turn.
  defmodule RouterDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(_agent, _payload, _opts), do: {:ok, :queued}
  end

  defmodule NoCredits do
    def before_llm_call(_fact),
      do: {:error, {:billing_unavailable, %{reason: "insufficient_credits"}}}
  end

  defmodule UnavailableBilling do
    def before_llm_call(_fact),
      do: {:error, {:billing_unavailable, %{reason: "fee_control_error"}}}
  end

  setup do
    previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, RouterDelivery)
    on_exit(fn -> restore_env(:salix_im, :agent_delivery_mod, previous_delivery) end)
    # A scheduled briefing wakes the Router. Its turn is out of scope here and
    # must not run into the next test's model fixture.
    on_exit(fn -> SalixAgent.TestSupport.stop_all_agents() end)
    Req.Test.set_req_test_to_shared()
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)
    :ok
  end

  test "Gmail partial context publishes readable work and a source warning" do
    {user, workspace, profile, token} = generation_fixture!()
    # The local account fixture already exposes Gmail through Composio discovery.
    # Gmail is not a native PluginStore definition.
    source = Enum.find(profile.sources, &(&1["toolkit"] == "gmail"))
    assert source
    account = source["connectionId"]

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, SystemsRuntime.get_env(:salix_web, key)}

    for {key, _} <- previous, do: SystemsRuntime.put_env(:salix_web, key, MemberGmail)

    SystemsRuntime.put_env(:comma_web, :member_gmail_test, %{
      workspace: workspace,
      account: account
    })

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      SystemsRuntime.delete_env(:comma_web, :member_gmail_test)
    end)

    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "gmail", account)

    assert {:ok, %{facts: [fact], failures: [failure]}} =
             RecommendationSourceCollector.collect(workspace, [source],
               member_user_id: user["id"]
             )

    assert [%{"messageId" => "readable"}] = fact["data"]["messages"]
    assert failure["sourceId"] == account
    assert failure["message"] =~ "member_source_context_unavailable"
    refute inspect(fact) =~ "source_warnings"
    refute inspect(fact) =~ "member_source_context_unavailable"

    response = request(:post, workspace, token, "/refresh")
    run_id = Jason.decode!(response.resp_body)["run"]["id"]
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run_id}})
    envelope = request(:get, workspace, token, "") |> then(&Jason.decode!(&1.resp_body))
    assert envelope["snapshot"]["cards"] != []

    assert [%{"code" => "partial_sources", "sourceIds" => [^account]}] =
             envelope["snapshot"]["warnings"]

    assert [{messages, [], _opts}] = DraftLLM.requests()
    assert [candidate] = Jason.decode!(List.last(messages).content)["candidates"]
    assert candidate["context"]["text"] =~ "Please review the release plan."
    refute inspect(messages) =~ "source_warnings"
    refute inspect(messages) =~ "member_source_context_unavailable"
  end

  test "a stalled Gmail read ends at the source deadline and keeps readable mail" do
    {user, workspace, profile, _token} = generation_fixture!()
    source = Enum.find(profile.sources, &(&1["toolkit"] == "gmail"))
    account = source["connectionId"]

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, SystemsRuntime.get_env(:salix_web, key)}

    for {key, _} <- previous, do: SystemsRuntime.put_env(:salix_web, key, MemberGmail)

    SystemsRuntime.put_env(:comma_web, :member_gmail_test, %{
      workspace: workspace,
      account: account,
      stalled: true
    })

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      SystemsRuntime.delete_env(:comma_web, :member_gmail_test)
    end)

    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "gmail", account)

    # The stalled thread outlasts the source budget; the readable one is kept.
    assert {:ok, %{facts: [fact], failures: [failure]}} =
             RecommendationSourceCollector.collect(workspace, [source],
               member_user_id: user["id"],
               source_timeout_ms: 1_000
             )

    assert [%{"messageId" => "readable"}] = fact["data"]["messages"]
    assert failure["sourceId"] == account
    assert failure["message"] =~ "member_source_context_unavailable"
  end

  test "one source crash publishes healthy work with a warning through the HTTP boundary" do
    {_user, workspace, profile, token} = generation_fixture!()
    previous = SystemsRuntime.get_env(:comma_web, :recommendation_composio_client_mod)
    SystemsRuntime.put_env(:comma_web, :recommendation_composio_client_mod, CrashedSource)
    on_exit(fn -> restore_env(:comma_web, :recommendation_composio_client_mod, previous) end)

    failed = %{
      "appId" => "notion",
      "appName" => "Notion",
      "toolkit" => "notion",
      "kind" => "composio",
      "connectionId" => "crashed-notion",
      "label" => "Notion",
      "enabled" => true
    }

    {:ok, _} =
      Recommendations.reconcile_discovered_sources(profile.id, profile.sources ++ [failed])

    response = request(:post, workspace, token, "/refresh")
    run_id = Jason.decode!(response.resp_body)["run"]["id"]
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run_id}})
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run_id)
    envelope = request(:get, workspace, token, "") |> then(&Jason.decode!(&1.resp_body))
    assert envelope["snapshot"]["cards"] != []

    assert [%{"code" => "partial_sources", "sourceIds" => ["crashed-notion"]}] =
             envelope["snapshot"]["warnings"]

    assert length(DraftLLM.requests()) == 1

    # Every source fails: the Composio ones through the client, the managed
    # Slack one at the Web API.
    SystemsRuntime.put_env(:comma_web, :recommendation_composio_client_mod, AllCrashedSources)
    previous_http = SystemsRuntime.get_env(:comma_web, :recommendation_oauth_http_options)
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(AllCrashedSources, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

    SystemsRuntime.put_env(:comma_web, :recommendation_oauth_http_options,
      plug: {Req.Test, AllCrashedSources}
    )

    on_exit(fn ->
      restore_env(:comma_web, :recommendation_oauth_http_options, previous_http)
    end)

    retry = request(:post, workspace, token, "/refresh")
    retry_id = Jason.decode!(retry.resp_body)["run"]["id"]
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => retry_id}})
    retained = request(:get, workspace, token, "") |> then(&Jason.decode!(&1.resp_body))
    assert retained["state"] == "stale"
    assert retained["lastError"] == "source_collection_failed"
    assert retained["snapshot"] == envelope["snapshot"]
    assert length(DraftLLM.requests()) == 1
  end

  test "Responses Routine generation sends its closed content schema in the provider wire shape" do
    {_user, workspace, _profile, token} = generation_fixture!("responses")
    response = request(:post, workspace, token, "/refresh")
    assert response.status == 202
    run_id = Jason.decode!(response.resp_body)["run"]["id"]
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run_id}})
    assert [{messages, [], opts}] = DraftLLM.requests()

    body =
      SalixVerifiedKernel.Provider.body(
        "responses",
        SalixLlm.ProviderConfig.resolve(opts),
        messages,
        [],
        "stream"
      )
      |> Jason.decode!()

    assert body["text"]["format"] == %{
             "type" => "json_schema",
             "name" => "routine_content",
             "strict" => true,
             "schema" => Comma.RecommendationDraft.schema()
           }

    refute Map.has_key?(body, "tools")
  end

  test "HTTP refresh durably queues work before collection and publishes one stateless model response" do
    {user, workspace, profile, token} = generation_fixture!()
    response = request(:post, workspace, token, "/refresh")
    assert response.status == 202
    run_id = Jason.decode!(response.resp_body)["run"]["id"]
    assert DraftLLM.requests() == []
    assert_enqueued(worker: RecommendationGenerate, args: %{run_id: run_id})
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run_id}})

    assert {:ok, %{run: %{status: "published", metrics: metrics}}} =
             Recommendations.run_context(run_id)

    # The settled run keeps the counts of what it read, sent, and published.
    assert %{
             "variant" => "generic",
             "sources" => %{"collected" => collected},
             "model" => %{"inputBytes" => input_bytes},
             "projection" => %{"cards" => 1}
           } = metrics

    assert collected >= 1 and map_size(metrics["bound"]) == collected
    assert Enum.all?(Map.values(metrics["bound"]), &is_integer(&1["kept"]))
    assert input_bytes > 0
    assert [{messages, [], opts}] = DraftLLM.requests()
    assert length(messages) == 2
    assert opts["entrypoint"] == "comma_recommendation"
    assert opts["billing_context"]["product_owner_id"] == workspace["id"]
    assert is_nil(profile.agent_id)
    assert {:ok, envelope} = Recommendations.get(user, %{}, workspace["id"])
    assert Comma.RecommendationContract.validate(envelope["snapshot"]) == :ok
    assert [%{"title" => "Slack", "sourceIds" => [_]}] = envelope["snapshot"]["cards"]
    refute Enum.any?(envelope["snapshot"]["summary"], &String.contains?(&1["text"] || "", "\\n"))
    # Replaying durable work after its commit must not buy another model call.
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run_id}})
    assert length(DraftLLM.requests()) == 1
  end

  test "HTTP refresh exposes exhausted credits and can publish after billing recovers" do
    {_user, workspace, _profile, token} = generation_fixture!()
    previous = SystemsRuntime.get_env(:salix_agent, :llm_metering_mod)
    on_exit(fn -> restore_env(:salix_agent, :llm_metering_mod, previous) end)
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, NoCredits)

    response = request(:post, workspace, token, "/refresh")
    assert response.status == 202
    run_id = Jason.decode!(response.resp_body)["run"]["id"]
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run_id}})
    assert DraftLLM.requests() == []

    envelope = request(:get, workspace, token, "") |> then(&Jason.decode!(&1.resp_body))
    assert envelope["state"] == "error"
    assert envelope["snapshot"] == nil
    assert envelope["lastError"] == "insufficient_credits"

    restore_env(:salix_agent, :llm_metering_mod, previous)
    retry = request(:post, workspace, token, "/refresh") |> then(&Jason.decode!(&1.resp_body))

    assert :ok =
             RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => retry["run"]["id"]}})

    recovered = request(:get, workspace, token, "") |> then(&Jason.decode!(&1.resp_body))
    assert recovered["state"] == "fresh"
    assert recovered["lastError"] == nil
    assert length(DraftLLM.requests()) == 1
  end

  test "HTTP refresh keeps billing outages within the public failure contract" do
    {_user, workspace, _profile, token} = generation_fixture!()
    previous = SystemsRuntime.get_env(:salix_agent, :llm_metering_mod)
    on_exit(fn -> restore_env(:salix_agent, :llm_metering_mod, previous) end)
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, UnavailableBilling)

    response = request(:post, workspace, token, "/refresh")
    assert response.status == 202
    run_id = Jason.decode!(response.resp_body)["run"]["id"]
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run_id}})
    assert DraftLLM.requests() == []

    assert {:ok, %{run: run}} = Recommendations.run_context(run_id)
    assert run.error == inspect({:billing_unavailable, "fee_control_error"})

    response = request(:get, workspace, token, "")
    assert response.status == 200
    envelope = Jason.decode!(response.resp_body)
    assert envelope["state"] == "error"
    assert envelope["lastError"] == "failed"
  end

  test "DeepSeek generic refresh publishes through its supported chat response format" do
    {user, workspace, _profile, token} = generation_fixture!()
    configure_platform_llm!("deepseek-flash", "chat_completions", "https://api.deepseek.com")

    DraftLLM.mode(:deepseek_chat)
    response = request(:post, workspace, token, "/refresh")
    assert response.status == 202
    run_id = Jason.decode!(response.resp_body)["run"]["id"]
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run_id}})

    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run_id)
    assert {:ok, %{"snapshot" => snapshot}} = Recommendations.get(user, %{}, workspace["id"])
    assert Comma.RecommendationContract.validate(snapshot) == :ok
    assert [%{"title" => "Slack"}] = snapshot["cards"]
    assert length(DraftLLM.requests()) == 1
  end

  test "HTTP reads expose expired pending and running work without executing a worker" do
    {_user, workspace, _profile, token} = generation_fixture!()
    response = request(:post, workspace, token, "/refresh")
    assert response.status == 202
    run_id = Jason.decode!(response.resp_body)["run"]["id"]
    assert Jason.decode!(request(:get, workspace, token, "").resp_body)["state"] == "refreshing"

    for status <- ~w(pending running) do
      run = Comma.Repo.get!(Comma.Data.RecommendationRun, run_id)

      run
      |> Ecto.Changeset.change(
        status: status,
        inserted_at: DateTime.add(SystemsClock.utc_now(), -480, :second)
      )
      |> Comma.Repo.update!()

      response = request(:get, workspace, token, "")
      assert response.status == 200
      envelope = Jason.decode!(response.resp_body)
      assert envelope["state"] == "error"
      assert envelope["lastError"] == "timed_out"
      assert envelope["snapshot"] == nil
      # Reads derive expiry, but do not take the worker's durable settlement role.
      assert Comma.Repo.get!(Comma.Data.RecommendationRun, run_id).status == status
      assert DraftLLM.requests() == []
    end

    replacement = request(:post, workspace, token, "/refresh")
    assert replacement.status == 202
    envelope = Jason.decode!(request(:get, workspace, token, "").resp_body)
    assert envelope["state"] == "refreshing"
    assert envelope["lastError"] == nil
  end

  test "HTTP reads retain the valid snapshot as stale when a refresh expires in the queue" do
    {_user, workspace, _profile, token} = generation_fixture!()
    first = request(:post, workspace, token, "/refresh") |> then(&Jason.decode!(&1.resp_body))

    assert :ok =
             RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => first["run"]["id"]}})

    original = Jason.decode!(request(:get, workspace, token, "").resp_body)
    assert original["state"] == "fresh"
    response = request(:post, workspace, token, "/refresh")
    assert response.status == 202
    run_id = Jason.decode!(response.resp_body)["run"]["id"]

    Comma.Repo.get!(Comma.Data.RecommendationRun, run_id)
    |> Ecto.Changeset.change(inserted_at: DateTime.add(SystemsClock.utc_now(), -3_600, :second))
    |> Comma.Repo.update!()

    response = request(:get, workspace, token, "")
    assert response.status == 200
    envelope = Jason.decode!(response.resp_body)
    assert envelope["state"] == "stale"
    assert envelope["lastError"] == "timed_out"
    assert envelope["snapshot"] == original["snapshot"]
    assert Comma.Repo.get!(Comma.Data.RecommendationRun, run_id).status == "pending"
    assert length(DraftLLM.requests()) == 1

    assert :ok =
             Comma.Workers.RecommendationRunTimeout.perform(%Oban.Job{
               args: %{"run_id" => run_id}
             })

    assert Jason.decode!(request(:get, workspace, token, "").resp_body) == envelope
  end

  test "a slow model does not block reads or another refresh and its late result cannot publish" do
    {user, workspace, _profile, token} = generation_fixture!()
    first = request(:post, workspace, token, "/refresh") |> then(&Jason.decode!(&1.resp_body))
    DraftLLM.mode(:hold)

    task =
      SystemsRuntime.Task.async(fn ->
        RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => first["run"]["id"]}})
      end)

    settle_receive({:model_waiting, model})
    assert request(:get, workspace, token, "").status == 200
    second = request(:post, workspace, token, "/refresh")
    assert second.status == 202
    second_id = Jason.decode!(second.resp_body)["run"]["id"]
    SystemsRuntime.Proc.send(model, :continue)
    assert :ok = settled_await(task)

    assert {:ok, %{run: %{status: "superseded"}}} =
             Recommendations.run_context(first["run"]["id"])

    DraftLLM.mode(:normal)
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => second_id}})
    assert {:ok, %{"snapshot" => snapshot}} = Recommendations.get(user, %{}, workspace["id"])
    assert snapshot["generation"] == Jason.decode!(second.resp_body)["run"]["generation"]
    assert Enum.all?(DraftLLM.requests(), fn {messages, _, _} -> length(messages) == 2 end)
  end

  test "invalid model content ends one run and keeps the last valid snapshot" do
    {user, workspace, _profile, token} = generation_fixture!()
    first = request(:post, workspace, token, "/refresh") |> then(&Jason.decode!(&1.resp_body))

    assert :ok =
             RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => first["run"]["id"]}})

    DraftLLM.mode(:invalid)
    second = request(:post, workspace, token, "/refresh") |> then(&Jason.decode!(&1.resp_body))

    assert :ok =
             RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => second["run"]["id"]}})

    assert {:ok, %{run: %{status: "failed", error: ":invalid_briefing_content"}}} =
             Recommendations.run_context(second["run"]["id"])

    assert {:ok, %{"state" => "stale", "snapshot" => snapshot}} =
             Recommendations.get(user, %{}, workspace["id"])

    assert snapshot["generation"] == first["run"]["generation"]
    assert length(DraftLLM.requests()) == 2
  end

  test "queued work cannot read sources or call a model after workspace access is revoked" do
    {_user, workspace, _profile, token} = generation_fixture!()
    response = request(:post, workspace, token, "/refresh")
    assert response.status == 202
    run_id = Jason.decode!(response.resp_body)["run"]["id"]

    Comma.Repo.delete_all(
      from(m in Comma.Data.WorkspaceMembership, where: m.workspace_id == ^workspace["id"])
    )

    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run_id}})
    assert DraftLLM.requests() == []

    assert {:ok, %{run: %{status: "failed", error: ":workspace_unavailable"}}} =
             Recommendations.run_context(run_id)
  end

  test "member generation publishes only assigned work and hides it after account revocation" do
    {user, workspace, profile, token, connection} = member_fixture!()

    preferences = %{
      "autoEnableNewSources" => profile.auto_enable_new_sources,
      "schedule" => %{
        "enabled" => profile.schedule_enabled,
        "hour" => profile.schedule_hour,
        "minute" => profile.schedule_minute,
        "timezone" => profile.timezone
      },
      "relevanceMode" => "member"
    }

    saved = request(:patch, workspace, token, "/settings", preferences)
    assert saved.status == 200

    member_response([
      %{
        "id" => "mine",
        "title" => "My task",
        "url" => "https://linear.app/team/issue/mine",
        "assignee" => %{"id" => "viewer"},
        "state" => %{"type" => "started"},
        "description" => "## Plan\n\nShip  it"
      }
    ])

    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: stored}} = Recommendations.run_context(run["id"])
    assert stored.status == "published"
    assert stored.relevance_mode == "member"
    assert stored.metrics["variant"] == "member"
    assert [{messages, [], opts}] = DraftLLM.requests()
    refute Map.has_key?(opts, "response_format")

    input = Jason.decode!(List.last(messages).content)
    assert [candidate] = input["candidates"]
    assert candidate["title"] == "My task"
    assert candidate["url"] == "https://linear.app/team/issue/mine"
    refute Map.has_key?(candidate, "excerpt")

    assert {:ok, %{"snapshot" => snapshot}} = Recommendations.get(user, %{}, workspace["id"])
    assert snapshot != nil
    refute Map.has_key?(snapshot, "memberSubject")
    assert [card] = snapshot["cards"]
    assert [item] = card["items"]
    prompt_id = item["action"]["promptId"]
    assert [%{"link" => %{"promptId" => ^prompt_id}}] = item["parts"]
    assert snapshot["prompts"][prompt_id]["objective"] == "Review My task"
    # The hover quotes what the issue says, line by line, without markdown marks.
    assert snapshot["prompts"][prompt_id]["context"] == "My task\nPlan\nShip it"

    {:ok, %{run: newer}} = Recommendations.request_refresh(user, %{}, workspace["id"])

    {:ok, collection} =
      RecommendationSourceCollector.collect(workspace, profile.sources,
        member_user_id: user["id"]
      )

    {:ok, _} =
      Recommendations.record_source_evidence(newer["id"], collection.facts, collection.failures)

    newer_snapshot = Map.put(snapshot, "generation", newer["generation"])

    :ok =
      SalixStore.OAuth.put(connection["connection_id"], Map.put(connection, "status", "revoked"))

    assert {:ok, {:superseded, _}} = Recommendations.publish(newer["id"], newer_snapshot)
    assert {:ok, %{"snapshot" => nil}} = Recommendations.get(user, %{}, workspace["id"])
    response = request(:get, workspace, token, "")
    assert Jason.decode!(response.resp_body)["snapshot"] == nil

    assert Comma.Repo.get!(Comma.Data.RecommendationProfile, profile.id).schedule_hour ==
             profile.schedule_hour
  end

  test "the member's Router judges with its own model and identity" do
    {user, workspace, _profile, _token, _connection} = member_fixture!()
    # A stored default Worker with another model must not judge member work.
    workspace = CommaWeb.TestWorkers.with_default_worker!(workspace)
    archive = SystemsRuntime.get_env(:salix_agent, :event_archive_mod)
    SystemsRuntime.put_env(:salix_agent, :event_archive_mod, DraftLLM)
    on_exit(fn -> restore_env(:salix_agent, :event_archive_mod, archive) end)

    # The member's own endpoint serves both models.
    assert {:ok, _profile} =
             SalixAgent.AccountPool.create(workspace["salix_tenant_id"], %{
               "credential_kind" => "provider_api_key",
               "source" => "custom",
               "api_key" => "sk-local-dev-only-0123456789",
               "base_url" => "https://models.example.test/v1",
               "protocol" => "chat_completions",
               "models" => ["router-judge", "worker-model"]
             })

    for {role, model} <- [{"router", "router-judge"}, {"worker", "worker-model"}] do
      assert {:ok, _} =
               Comma.Salix.Client.update_workspace_agent_model(workspace, role, %{
                 "kind" => "catalog",
                 "model" => model,
                 "allow_paid" => true
               })
    end

    # The local mock substitutes one deterministic model for every Agent.
    assert {:ok, %{enabled: false}} = SalixWeb.LocalOAuthMock.set_enabled(false)

    member_response([
      %{
        "id" => "release",
        "title" => "Release checks",
        "url" => "https://linear.app/team/issue/release",
        "assignee" => %{"id" => "viewer"},
        "state" => %{"type" => "started"}
      }
    ])

    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    assert [{_messages, [], opts}] = DraftLLM.requests()
    assert opts["model"] == "router-judge"
    refute Map.has_key?(opts, "response_format")

    assert [_ | _] =
             archived =
             Enum.filter(
               DraftLLM.archives(),
               &(&1.boundary == :llm_request and &1.round_id == run["id"])
             )

    for fact <- archived do
      assert fact.agent_id == workspace["router_agent_id"]
      assert fact.tenant_id == workspace["salix_tenant_id"]
    end
  end

  test "member judgment rejects unrelated prose with a legitimate reference instead of publishing it" do
    {user, workspace, _profile, _token, _connection} = member_fixture!()

    member_response([
      %{
        "id" => "pay",
        "title" => "Fix payment checkout",
        "url" => "https://linear.app/team/issue/PAY-1",
        "assignee" => %{"id" => "viewer"},
        "state" => %{"type" => "started"}
      }
    ])

    DraftLLM.mode(:unrelated)
    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: stored}} = Recommendations.run_context(run["id"])
    assert stored.status == "failed"
    assert {:ok, envelope} = Recommendations.get(user, %{}, workspace["id"])
    assert envelope["snapshot"] == nil
  end

  test "the Router's order is the briefing order and malformed rows drop alone" do
    {user, workspace, _profile, _token, _connection} = member_fixture!()

    member_response(
      Enum.map(~w(First Second Third), fn title ->
        %{
          "id" => title,
          "title" => title,
          "url" => "https://linear.app/team/issue/#{title}",
          "assignee" => %{"id" => "viewer"},
          "state" => %{"type" => "started"}
        }
      end) ++
        [
          %{
            "id" => "skip",
            "title" => "No work",
            "url" => "https://linear.app/team/issue/skip",
            "assignee" => %{"id" => "viewer"},
            "state" => %{"type" => "started"}
          }
        ]
    )

    objectives = fn ->
      assert {:ok, %{"state" => "fresh", "snapshot" => snapshot}} =
               Recommendations.get(user, %{}, workspace["id"])

      Enum.map(hd(snapshot["cards"])["items"], fn item ->
        snapshot["prompts"][item["action"]["promptId"]]["objective"]
      end)
    end

    DraftLLM.mode(:reordered)
    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    assert [{messages, [], _}] = DraftLLM.requests()
    candidates = Jason.decode!(List.last(messages).content)["candidates"]
    assert Enum.map(candidates, & &1["title"]) == ["First", "Second", "Third", "No work"]
    assert objectives.() == ["Review Third", "Review Second", "Review First"]

    # An unknown ID, a repeated ID and a URL title each remove only their row.
    DraftLLM.mode(:malformed_rows)
    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    assert objectives.() == ["Review First", "Review Third"]
  end

  test "a Router answer after inline reasoning or in a code block publishes" do
    {user, workspace, _profile, _token, _connection} = member_fixture!()

    member_response([
      %{
        "id" => "release",
        "title" => "Release checks",
        "url" => "https://linear.app/team/issue/release",
        "assignee" => %{"id" => "viewer"},
        "state" => %{"type" => "started"}
      }
    ])

    for mode <- [:thinking, :fenced] do
      DraftLLM.mode(mode)
      {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
      assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
      assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    end
  end

  test "a dismissed item leaves the briefing at once and is not offered to the Router again" do
    {user, workspace, _profile, _token, _connection} = member_fixture!()

    member_response(
      Enum.map(~w(First Second), fn title ->
        %{
          "id" => title,
          "title" => title,
          "url" => "https://linear.app/team/issue/#{title}",
          "assignee" => %{"id" => "viewer"},
          "state" => %{"type" => "started"}
        }
      end)
    )

    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{"snapshot" => snapshot}} = Recommendations.get(user, %{}, workspace["id"])
    [card] = snapshot["cards"]

    links =
      for item <- card["items"], %{"kind" => "inline-link", "link" => l} <- item["parts"], do: l

    second = Enum.find(links, &(&1["href"] == "https://linear.app/team/issue/Second"))

    assert {:error, :invalid_recommendation_dismissal} =
             Recommendations.dismiss(user, %{}, workspace["id"], second["sourceId"], "")

    assert {:ok, %{"state" => "fresh", "snapshot" => dismissed}} =
             Recommendations.dismiss(
               user,
               %{},
               workspace["id"],
               second["sourceId"],
               second["href"]
             )

    # The row, its prompt and its attention item leave. The summary keeps its
    # lead-in and the other item's clause, now its last.
    assert [%{"items" => [only]}] = dismissed["cards"]

    assert [
             %{
               "kind" => "inline-link",
               "link" => %{"href" => "https://linear.app/team/issue/First"}
             }
           ] =
             only["parts"]

    assert [
             %{"kind" => "markdown", "text" => lead},
             %{
               "kind" => "inline-link",
               "link" => %{"href" => "https://linear.app/team/issue/First"}
             },
             %{"kind" => "markdown", "text" => "."}
           ] = dismissed["summary"]

    [title, _] = String.split(hd(snapshot["summary"])["text"], "\n\n", parts: 2)
    assert String.starts_with?(lead, title <> "\n\n")
    assert String.ends_with?(lead, "Review First ")
    refute lead =~ "Second"
    assert Map.keys(dismissed["prompts"]) == [only["action"]["promptId"]]

    assert Enum.map(dismissed["attentionItems"], & &1["sourceUrl"]) == [
             "https://linear.app/team/issue/First"
           ]

    assert {:ok, %{"snapshot" => ^dismissed}} = Recommendations.get(user, %{}, workspace["id"])

    # The next run offers the Router only the other item.
    DraftLLM.mode(:normal)
    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    {messages, [], _} = List.last(DraftLLM.requests())
    candidates = Jason.decode!(List.last(messages).content)["candidates"]
    assert Enum.map(candidates, & &1["title"]) == ["First"]
  end

  test "an unusable Router answer fails the run and keeps the last briefing" do
    {user, workspace, _profile, _token, _connection} = member_fixture!()

    member_response([
      %{
        "id" => "release",
        "title" => "Release checks",
        "url" => "https://linear.app/team/issue/release",
        "assignee" => %{"id" => "viewer"},
        "state" => %{"type" => "started"}
      }
    ])

    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    {:ok, %{"snapshot" => previous}} = Recommendations.get(user, %{}, workspace["id"])

    # Returned rows that all fail validation, then a failed provider call.
    for mode <- [:unknown_rows, :failed] do
      DraftLLM.mode(mode)
      {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
      assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
      assert {:ok, %{run: %{status: "failed"}}} = Recommendations.run_context(run["id"])

      assert {:ok, %{"state" => "stale", "snapshot" => ^previous}} =
               Recommendations.get(user, %{}, workspace["id"])
    end
  end

  test "the Router can decide that no candidate is work" do
    {user, workspace, _profile, _token, _connection} = member_fixture!()

    member_response([
      %{
        "id" => "none",
        "title" => "No work",
        "url" => "https://linear.app/team/issue/none",
        "assignee" => %{"id" => "viewer"},
        "state" => %{"type" => "started"}
      }
    ])

    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    assert [_request] = DraftLLM.requests()

    assert {:ok, %{"state" => "fresh", "snapshot" => %{"cards" => []}}} =
             Recommendations.get(user, %{}, workspace["id"])
  end

  test "member empty results skip the model and mode changes supersede queued work" do
    {user, workspace, profile, _token, _connection} = member_fixture!()
    member_response([])
    assert :ok = RecommendationRuntime.reconcile_profile(profile.id)
    profile = Comma.Repo.get!(Comma.Data.RecommendationProfile, profile.id)

    {:ok, %{run: run}} =
      Recommendations.begin_schedule_occurrence(profile.id, profile.schedule_id, 1_789_738_000)

    {:ok, %{run: duplicate}} =
      Recommendations.begin_schedule_occurrence(profile.id, profile.schedule_id, 1_789_738_000)

    assert duplicate["id"] == run["id"]
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert DraftLLM.requests() == []

    assert {:ok, %{"snapshot" => %{"cards" => []}}} =
             Recommendations.get(user, %{}, workspace["id"])

    {:ok, %{run: queued}} = Recommendations.request_refresh(user, %{}, workspace["id"])

    assert {:ok, changed} =
             Recommendations.set_relevance_mode(user, %{}, workspace["id"], "generic")

    assert changed.schedule_hour == profile.schedule_hour
    assert changed.timezone == profile.timezone
    assert changed.snapshot == nil
    assert {:ok, %{run: %{status: "superseded"}}} = Recommendations.run_context(queued["id"])
  end

  test "a lost source collection resumes and schedules its successor without replacing live work" do
    {user, workspace, _profile, _token} = generation_fixture!()
    args = %{"group_id" => workspace["default_group_id"], "user_id" => user["id"]}
    worker = "CommaWeb.MemberSourceIngest"
    assert :ok = CommaWeb.MemberSourceIngest.enqueue(user, %{}, args["group_id"])

    query = from(j in Oban.Job, where: j.worker == ^worker and j.args == ^args)
    job = Comma.Repo.one!(query)

    Comma.Repo.update_all(query,
      set: [
        queue: "proactive_recovery",
        state: "executing",
        attempt: 3,
        max_attempts: 3,
        attempted_at: DateTime.add(SystemsClock.utc_now(), -481, :second)
      ]
    )

    # Home entry joins the orphan until the recovery owner releases it.
    assert :ok = CommaWeb.MemberSourceIngest.enqueue(user, %{}, args["group_id"])
    assert Comma.Repo.one!(query).id == job.id

    live =
      %Oban.Job{
        worker: "CommaWeb.ProactiveCheck",
        queue: "comma_external",
        args: %{"profile_id" => SystemsRuntime.Proc.uuid()},
        state: "executing",
        attempted_at: SystemsClock.utc_now(),
        attempt: 1,
        max_attempts: 3
      }
      |> Comma.Repo.insert!()

    assert {1, [%{id: id, max_attempts: 4}]} =
             Comma.ObanPlugins.OperationLifeline.rescue_recommendation_jobs(
               Oban.config(Comma.Oban),
               1
             )

    assert id == job.id
    assert Comma.Repo.get!(Oban.Job, live.id).state == "executing"
    # Oban computes schedule_in from the real wall clock.
    before_drain = DateTime.utc_now()
    assert %{success: 1, failure: 0} = Oban.drain_queue(Comma.Oban, queue: :proactive_recovery)
    after_drain = DateTime.utc_now()
    assert Comma.Repo.get!(Oban.Job, job.id).state == "completed"

    assert [successor] =
             all_enqueued(worker: CommaWeb.MemberSourceIngest, args: args)

    assert successor.state == "scheduled"
    # Scheduled 900 s after the moment the drain completed the job.
    assert DateTime.diff(successor.scheduled_at, before_drain, :microsecond) >= 900_000_000
    assert DateTime.diff(successor.scheduled_at, after_drain, :microsecond) <= 900_000_000
  end

  test "an unclear notice does not hold back the review request that arrived with it" do
    f = withdrawal_fixture!()
    f.collect.([])

    notice = %{
      "text" => "<@UCOMMALOCAL> the deploy status changed",
      "user" => "U777",
      "ts" => "800",
      "channel" => %{"id" => "D800", "is_im" => true},
      "permalink" => "https://team.slack.com/archives/D800/p800"
    }

    review = %{
      notice
      | "text" => "<@UCOMMALOCAL> can you review the notes this week?",
        "ts" => "810",
        "channel" => %{"id" => "D810", "is_im" => true},
        "permalink" => "https://team.slack.com/archives/D810/p810"
    }

    f.collect.([notice, review])

    # One check reaches the Router with the request the owner must act on.
    # The unclear notice keeps waiting for a later judgment.
    assert :ok = f.check.()
    assert [%{"agent_input" => %{"content" => text}}] = f.router_inputs.()
    assert text =~ "p810"
    assert f.pending.() == ["https://team.slack.com/archives/D800/p800"]
  end

  test "the Router reads a handed-over matter that no Routine briefing names yet" do
    f = withdrawal_fixture!()

    review = %{
      "text" => "<@UCOMMALOCAL> can you review the notes this week?",
      "user" => "U777",
      "ts" => "820",
      "channel" => %{"id" => "D820", "is_im" => true},
      "permalink" => "https://team.slack.com/archives/D820/p820"
    }

    f.collect.([review])
    assert :ok = f.check.()
    assert [%{"agent_input" => %{"content" => handoff}}] = f.router_inputs.()
    [_, evidence] = String.split(handoff, "\n", parts: 2)
    handoff = Jason.decode!(evidence)

    {:ok, agent} = SalixAgent.Control.get(f.workspace["router_agent_id"])

    ctx = %{
      agent_id: f.workspace["router_agent_id"],
      session_id: agent["router_session_id"],
      tenant_id: f.workspace["salix_tenant_id"],
      group_id: f.workspace["default_group_id"],
      trusted_origin: %{
        "provider" => "internal",
        "participant_id" => f.user["id"],
        "source_actor_type" => "user"
      }
    }

    assert {:ok, %{"sources" => sources}} = CommaWeb.Proactive.state(%{}, ctx)
    assert %{"read" => read} = Enum.find(sources, &((&1["source_url"] || "") =~ "p820"))

    # The handoff names the source the Router must read before it decides.
    # That read returns the pooled evidence the check judged.
    assert {:ok, item} = CommaWeb.ProactiveRoutine.read(read["arguments"], ctx)
    assert item["url"] == "https://team.slack.com/archives/D820/p820"
    assert item["body"] =~ "review the notes"

    # The Router's decision names the same matter the check handed over.
    assert :ok = CommaWeb.ProactiveRoutine.validate_reference(handoff, item)
  end

  test "a notification on the owner's merged pull request settles in the briefing instead of staying unclear" do
    {user, workspace, profile, _token} = generation_fixture!()
    connect_github!(user, workspace)
    assert :ok = RecommendationRuntime.sync_sources(profile.id)
    assert {:ok, profile} = Recommendations.get_runtime_profile(workspace["id"], user["id"])
    source = Enum.find(profile.sources, &(&1["appId"] == "github"))
    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    member_github_http!(%{notifications: []})
    group = workspace["default_group_id"]

    collect = fn ->
      job = %Oban.Job{args: %{"group_id" => group, "user_id" => user["id"]}}
      assert :ok = CommaWeb.MemberSourceIngest.perform(job)
    end

    url = "https://github.com/AFK-surf/Cue/pull/2718"
    item = fn -> Comma.Repo.one!(from(i in Comma.Data.MemberSourceItem, where: i.url == ^url)) end

    # The first collection is the baseline. GitHub then notifies the author
    # about activity on a pull request that is already merged, so the open
    # pull request read no longer returns it.
    collect.()

    SystemsRuntime.put_env(:comma_web, :member_github_test, %{
      notifications: [
        %{
          "id" => "thread-2718",
          "reason" => "author",
          "updated_at" => DateTime.to_iso8601(SystemsClock.utc_now()),
          "subject" => %{
            "type" => "PullRequest",
            "title" =>
              "fix(release): restart salix_store when a migration leaves it without a Repo",
            "url" => "https://api.github.com/repos/AFK-surf/Cue/pulls/2718",
            "latest_comment_url" => "https://api.github.com/repos/AFK-surf/Cue/issues/comments/9"
          },
          "repository" => %{
            "full_name" => "AFK-surf/Cue",
            "html_url" => "https://github.com/AFK-surf/Cue"
          }
        }
      ],
      subjects: %{
        "AFK-surf/Cue#2718" => %{
          "state" => "MERGED",
          "comments" => %{
            "nodes" => [
              %{
                "author" => %{"login" => "github-actions"},
                "body" => "Deployed to staging.",
                "createdAt" => DateTime.to_iso8601(SystemsClock.utc_now())
              }
            ]
          }
        }
      }
    })

    collect.()
    assert %{baseline: false, attention: nil, relationship: "notified_you"} = item.()

    # The judge sees that the work is resolved and rates it low. The
    # notification stays in the briefing; nothing reaches the Router and
    # nothing waits for another judgment.
    assert :ok = perform_job(CommaWeb.ProactiveCheck, %{"profile_id" => profile.id})
    assert [{messages, [], _opts}] = DraftLLM.requests()
    [candidate] = Jason.decode!(List.last(messages).content)["candidates"]
    assert candidate["context"]["text"] =~ "state: merged"
    assert candidate["context"]["text"] =~ "Deployed to staging."
    assert %{attention: %{"outcome" => "quiet", "urgency" => "low"}} = item.()
    assert Comma.MemberSourceItems.pending(profile.id, 24) == []
  end

  test "a credit refusal keeps arrived work pending until a later collection can judge it" do
    f = withdrawal_fixture!()
    previous = SystemsRuntime.get_env(:salix_agent, :llm_metering_mod)
    on_exit(fn -> restore_env(:salix_agent, :llm_metering_mod, previous) end)
    f.collect.([])
    f.collect.([f.approval.("900")])
    pending = f.pending.()
    assert pending != []

    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, UnavailableBilling)
    assert {:error, {:billing_unavailable, "fee_control_error"}} = f.check.()
    assert f.pending.() == pending

    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, NoCredits)

    # The refusal names whose check it was, so an operator finds the owner.
    # Oban runs each job in a new process; the collection above set its own IDs here.
    Logger.reset_metadata()

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:user_id, :workspace_id]], fn ->
        assert {:cancel, :insufficient_credits} = f.check.()
      end)

    assert log =~ "proactive_check failed reason=:insufficient_credits"
    assert log =~ "user_id=#{f.user["id"]}"
    assert log =~ "workspace_id=#{f.workspace["id"]}"
    assert f.pending.() == pending
    assert f.router_inputs.() == []
    assert DraftLLM.requests() == []

    restore_env(:salix_agent, :llm_metering_mod, previous)
    assert :ok = f.check.()
    assert f.pending.() == []
    assert length(f.router_inputs.()) == 1
  end

  test "the daily portrait lands in the Router's user memory and the check reads it" do
    {user, workspace, profile, _token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, SystemsRuntime.get_env(:salix_web, key)}

    for {key, _} <- previous, do: SystemsRuntime.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      SystemsRuntime.delete_env(:comma_web, :member_slack_test)
    end)

    member_slack_http!()
    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))

    own =
      for ts <- ["300", "301"],
          do: %{
            "text" => "Renewed the patrol token",
            "user" => "UCOMMALOCAL",
            "ts" => ts,
            "channel" => %{"id" => "C9", "name" => "alerts"},
            "permalink" => "https://team.slack.com/archives/C9/p#{ts}"
          }

    SystemsRuntime.put_env(:comma_web, :member_slack_test, %{
      workspace: workspace,
      account: source["connectionId"],
      own: own
    })

    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    agent = workspace["router_agent_id"]

    # What the Router or the owner already wrote stays.
    {:ok, event} =
      SalixAgent.AgentWorkspace.prepare_write(
        agent,
        "/memory/semantic/user.md",
        "- Lives in Shanghai.\n"
      )

    {:ok, _} =
      SalixAgent.AgentActor.commit_workspace_operation(agent, "seed", %{}, [event],
        storage_authorized: true
      )

    # The write is stored in the Router's workspace, which needs credits.
    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: workspace["billing_account_id"],
        credits: 100,
        valid_from: ~U[2026-06-17 00:00:00Z],
        expires_at: DateTime.add(SystemsClock.utc_now(), 30, :day),
        source_type: "manual_contract",
        source_id: "portrait-test:#{workspace["id"]}",
        source_event_id: "portrait-test:#{workspace["id"]}",
        idempotency_key: "portrait-test:#{workspace["id"]}"
      })

    assert :ok = perform_job(CommaWeb.MemberPortrait, %{"profile_id" => profile.id})
    {:ok, note} = SalixAgent.AgentWorkspace.read(agent, "/memory/semantic/user.md")

    assert note =~ "- Lives in Shanghai."
    assert note =~ ~r/renews the patrol token · \d{4}-\d{2}-\d{2}/
    refute note =~ "payroll"

    assert [
             %{"text" => "About you · duty: renews the patrol token · " <> _},
             %{"text" => "Lives in Shanghai."}
           ] =
             CommaWeb.MemberPortrait.statements(Map.put(workspace, "router_agent_id", agent))
  end

  test "collection feeds the item pool and hands arrivals the owner must act on to the Router" do
    {user, workspace, profile, _token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, SystemsRuntime.get_env(:salix_web, key)}

    for {key, _} <- previous, do: SystemsRuntime.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      SystemsRuntime.delete_env(:comma_web, :member_slack_test)
    end)

    member_slack_http!()

    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))
    account = source["connectionId"]
    slack = %{workspace: workspace, account: account}
    SystemsRuntime.put_env(:comma_web, :member_slack_test, slack)
    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    group = workspace["default_group_id"]

    # One collection writes the pool and queues the proactive consumer when
    # items wait; the queued consumer then runs.
    collect = fn ->
      job = %Oban.Job{args: %{"group_id" => group, "user_id" => user["id"]}}
      assert :ok = CommaWeb.MemberSourceIngest.perform(job)

      if Comma.MemberSourceItems.pending?(profile.id) do
        assert_enqueued(worker: CommaWeb.ProactiveCheck, args: %{"profile_id" => profile.id})
        assert :ok = perform_job(CommaWeb.ProactiveCheck, %{"profile_id" => profile.id})
      end
    end

    pool = fn ->
      Comma.Repo.all(
        from(i in Comma.Data.MemberSourceItem,
          where: i.profile_id == ^profile.id,
          order_by: i.url
        )
      )
    end

    router_inputs = fn ->
      {:ok, home} = SalixIM.RouterConversationInput.ensure(group)

      {:ok, messages} =
        SalixIM.Conversations.list_group_conversation_messages(group, home["conversation_id"])

      refute Enum.any?(messages, &(&1["kind"] == "message" and &1["actor_type"] == "agent"))
      Enum.filter(messages, &is_map(&1["agent_input"]))
    end

    direct = fn ts, text ->
      %{
        "text" => text,
        "user" => "U777",
        "ts" => ts,
        "channel" => %{"id" => "D#{ts}", "is_im" => true},
        "permalink" => "https://team.slack.com/archives/D#{ts}/p#{ts}"
      }
    end

    # The first collection records the items the source already holds. Earlier
    # work stays in the Routine briefing and never interrupts the owner.
    collect.()
    assert DraftLLM.requests() == []
    assert router_inputs.() == []
    assert [%{baseline: true, attention: nil, excerpt: excerpt}] = pool.()
    assert excerpt =~ "review the plan"

    # A request without a deadline rates high. The owner personally must act, so
    # the Router receives it as evidence. Nothing has reached the owner yet.
    SystemsRuntime.put_env(
      :comma_web,
      :member_slack_test,
      Map.put(slack, :direct, [
        direct.("200", "<@UCOMMALOCAL> can you review the notes this week?")
      ])
    )

    collect.()
    assert [{messages, [], opts}] = DraftLLM.requests()
    assert opts["entrypoint"] == "comma_proactive"
    input = Jason.decode!(List.last(messages).content)
    assert [%{"relationship" => "direct_message_to_you"} = candidate] = input["candidates"]
    assert candidate["excerpt"] =~ "review the notes"

    assert [%{"agent_input" => %{"content" => text}} = message] = router_inputs.()
    assert message["metadata"]["proactive_automatic"] == true
    assert text =~ ~s("urgency":"high")
    assert text =~ "Want me to draft the reply?"
    assert text =~ "(https://team.slack.com/archives/D200/p200)"

    assert %{attention: %{"outcome" => "routed", "urgency" => "high"}} =
             Enum.find(pool.(), &(&1.url =~ "p200"))

    # The next check hands over the most urgent new item. The other one waits
    # in the pool for a later check.
    SystemsRuntime.put_env(
      :comma_web,
      :member_slack_test,
      Map.put(slack, :direct, [
        direct.("400", "<@UCOMMALOCAL> please review the budget too"),
        direct.("300", "<@UCOMMALOCAL> can you approve the launch today?")
      ])
    )

    collect.()
    assert length(DraftLLM.requests()) == 2
    assert [_, %{"agent_input" => %{"content" => text}}] = router_inputs.()
    assert text =~ ~s("urgency":"critical")

    assert %{attention: %{"outcome" => "routed", "urgency" => "critical"}} =
             Enum.find(pool.(), &(&1.url =~ "p300"))

    assert %{attention: nil, baseline: false} = Enum.find(pool.(), &(&1.url =~ "p400"))

    ctx = %{
      agent_id: workspace["router_agent_id"],
      session_id: nil,
      tenant_id: workspace["salix_tenant_id"],
      group_id: group,
      trusted_origin: %{
        "provider" => "internal",
        "participant_id" => user["id"],
        "source_actor_type" => "user"
      }
    }

    assert {:ok,
            %{
              "automatic_budget" => %{"remaining" => 10, "next_at" => nil},
              "notification_budget" => %{"remaining" => 5, "next_at" => nil},
              "sources" => sources
            }} = CommaWeb.Proactive.state(%{}, ctx)

    key = fn urgency ->
      Enum.find_value(sources, &(&1["automatic"] and &1["urgency"] == urgency and &1["key"]))
    end

    # Only the Router's decision to notify spends the notification budget.
    notify = %{"action" => "notify", "key" => key.("high"), "request_id" => "decide-1"}

    assert {:ok, %{"decision" => %{"decision" => "notify", "decided_at" => decided_at}}} =
             CommaWeb.Proactive.act(notify, ctx)

    assert {:ok, %{"decision" => %{"decided_at" => ^decided_at}}} =
             CommaWeb.Proactive.act(notify, ctx)

    assert {:ok, %{"notification_budget" => %{"remaining" => 0, "next_at" => next_at}}} =
             CommaWeb.Proactive.state(%{}, ctx)

    assert next_at > SystemsClock.system_time(:millisecond)

    assert {:error, :proactive_notification_budget_exhausted} =
             CommaWeb.Proactive.act(%{notify | "request_id" => "decide-2"}, ctx)

    # A critical matter skips the spacing, not the daily cap.
    assert {:ok, %{"decision" => %{"decision" => "notify"}}} =
             CommaWeb.Proactive.act(
               %{"action" => "notify", "key" => key.("critical"), "request_id" => "decide-3"},
               ctx
             )

    assert {:ok,
            %{
              "state" => "quiet",
              "decision" => %{"decision" => "quiet", "reason" => "Already discussed"}
            }} =
             CommaWeb.Proactive.act(
               %{
                 "action" => "quiet",
                 "key" => key.("high"),
                 "request_id" => "decide-4",
                 "reason" => "Already discussed"
               },
               ctx
             )

    # While the notification spacing is closed, a judged non-critical item is
    # not handed to the Router: it could not notify. It waits in the pool.
    SystemsRuntime.put_env(
      :comma_web,
      :member_slack_test,
      Map.put(slack, :direct, [
        direct.("500", "<@UCOMMALOCAL> can you review the slides this week?"),
        direct.("400", "<@UCOMMALOCAL> please review the budget too"),
        direct.("300", "<@UCOMMALOCAL> can you approve the launch today?")
      ])
    )

    inputs = length(router_inputs.())
    requests = length(DraftLLM.requests())
    collect.()
    assert length(DraftLLM.requests()) == requests + 1
    assert length(router_inputs.()) == inputs
    assert %{attention: nil, baseline: false} = Enum.find(pool.(), &(&1.url =~ "p500"))

    # The owner's notebook in the Router's VFS shows what Comma decided and
    # why. The server renders it from the matters and the pool; no model
    # writes it. The Workspace has no Drive device: System Files shows it.
    agent = workspace["router_agent_id"]

    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: workspace["billing_account_id"],
        credits: 100,
        valid_from: ~U[2026-06-17 00:00:00Z],
        expires_at: DateTime.add(SystemsClock.utc_now(), 30, :day),
        source_type: "manual_contract",
        source_id: "notebook-test:#{workspace["id"]}",
        source_event_id: "notebook-test:#{workspace["id"]}",
        idempotency_key: "notebook-test:#{workspace["id"]}"
      })

    render = %{"group_id" => group, "owner_id" => user["id"]}
    assert_enqueued(worker: CommaWeb.ProactiveNotebook, args: render)
    assert :ok = perform_job(CommaWeb.ProactiveNotebook, render)
    {:ok, notebook} = SalixAgent.AgentWorkspace.read(agent, "/Comma/Notebook.md")

    [needs_you, quiet] =
      notebook |> String.split(["## Needs you", "## Did not interrupt you"]) |> tl()

    assert needs_you =~ "approve the launch today"
    assert needs_you =~ "urgent"
    assert needs_you =~ "told you at"
    assert quiet =~ "review the notes"
    assert quiet =~ "stayed quiet at"
    assert quiet =~ "Already discussed"
    assert notebook =~ "Source: Slack — last read around"
    assert notebook =~ "Automatic messages are on. Until "
    assert notebook =~ ", only urgent matters can interrupt you."

    # A render that changes nothing writes no new version, and the Router can
    # point the owner to the notebook.
    {:ok, written} = SalixAgent.AgentWorkspace.entry(agent, "/Comma/Notebook.md")
    assert :ok = perform_job(CommaWeb.ProactiveNotebook, render)
    assert {:ok, ^written} = SalixAgent.AgentWorkspace.entry(agent, "/Comma/Notebook.md")

    assert {:ok, %{"notebook" => "/Comma/Notebook.md"}} =
             CommaWeb.Proactive.state(%{}, ctx)

    # Every member's Router turn reads the Router's VFS. Once another member
    # joins, the owner's private notebook is deleted.
    {:ok, member} =
      Comma.Accounts.create_user(%{
        "email" => "notebook-member-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    Comma.Repo.insert!(%Comma.Data.WorkspaceMembership{
      workspace_id: workspace["id"],
      user_id: member["id"],
      role: "member",
      status: "active"
    })

    assert :ok = perform_job(CommaWeb.ProactiveNotebook, render)
    assert {:error, :not_found} = SalixAgent.AgentWorkspace.entry(agent, "/Comma/Notebook.md")

    # The scheduled Routine reads the same pool. Collection ran within its
    # interval, so the run makes no provider read and offers the pooled items.
    SystemsRuntime.put_env(
      :comma_web,
      :member_slack_test,
      Map.put(slack, :reads, SystemsRuntime.Proc.self())
    )

    assert :ok = RecommendationRuntime.reconcile_profile(profile.id)
    profile = Comma.Repo.get!(Comma.Data.RecommendationProfile, profile.id)

    {:ok, %{run: run}} =
      Recommendations.begin_schedule_occurrence(profile.id, profile.schedule_id, 1_789_738_000)

    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    refute_received {:slack_read, _path}
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    {messages, [], %{"entrypoint" => "comma_recommendation"}} = List.last(DraftLLM.requests())

    # The scheduled briefing reaches the Router once, as evidence it decides on.

    briefing_inputs = fn ->
      Enum.filter(
        router_inputs.(),
        &(&1["metadata"]["mail_source"] == CommaWeb.ProactiveBriefing.key())
      )
    end

    assert [%{"agent_input" => %{"content" => briefing}}] = briefing_inputs.()
    assert briefing =~ "scheduled Routine briefing was published"

    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert length(briefing_inputs.()) == 1

    assert Jason.decode!(List.last(messages).content)["candidates"]
           |> Enum.map(& &1["url"])
           |> Enum.sort() ==
             Enum.sort(
               Enum.map(pool.(), & &1.url) -- ["https://team.slack.com/archives/D200/p200"]
             )

    # Every collection schedules the next one; repeated runs keep one waiting job.
    assert [%{state: "scheduled"}] =
             Enum.filter(
               Comma.Repo.all(Oban.Job),
               &(&1.worker == "CommaWeb.MemberSourceIngest" and &1.state != "completed")
             )
  end

  test "mail that the next collection no longer returns never reaches the owner" do
    f = withdrawal_fixture!()
    f.collect.([f.approval.("300")])
    assert f.pending.() == ["https://team.slack.com/archives/D300/p300"]

    # The owner answered before the check: the next collection no longer
    # returns the request, so nothing is judged or sent.
    f.collect.([])
    assert :ok = f.check.()
    assert DraftLLM.requests() == []
    assert f.router_inputs.() == []
  end

  test "a source turned off loses its waiting items at once" do
    f = withdrawal_fixture!()
    f.collect.([f.approval.("400")])
    assert f.pending.() == ["https://team.slack.com/archives/D400/p400"]

    {:ok, _} =
      Recommendations.update_settings(f.user, %{}, f.workspace["id"], f.settings.(false))

    assert Comma.Repo.aggregate(Comma.Data.MemberSourceItem, :count) == 0
    assert :ok = f.check.()
    assert DraftLLM.requests() == []
    assert f.router_inputs.() == []
  end

  test "a provider read started before source disable cannot restore its items" do
    f = withdrawal_fixture!()
    state = SystemsRuntime.fetch_env!(:comma_web, :member_slack_test)

    SystemsRuntime.put_env(
      :comma_web,
      :member_slack_test,
      Map.merge(state, %{hold: SystemsRuntime.Proc.self(), direct: [f.approval.("450")]})
    )

    collecting =
      SystemsRuntime.Task.async(fn ->
        CommaWeb.MemberSourceIngest.ingest(f.workspace, f.user["id"])
      end)

    settle_receive({:source_waiting, reader})
    {:ok, _} = Recommendations.update_settings(f.user, %{}, f.workspace["id"], f.settings.(false))
    SystemsRuntime.Proc.send(reader, :continue)
    assert {:ok, %{new: 0, changed: 0}} = settled_await(collecting)
    assert Comma.Repo.aggregate(Comma.Data.MemberSourceItem, :count) == 0
    assert Comma.Repo.aggregate(Comma.Data.MemberSourceState, :count) == 0
    assert :ok = f.check.()
    assert DraftLLM.requests() == []
    assert f.router_inputs.() == []
  end

  test "a reminder in another thread continues the earlier matter the owner was told about" do
    f = withdrawal_fixture!()
    f.collect.([f.approval.("470")])
    assert :ok = f.check.()
    assert [_first] = f.router_inputs.()

    reminder =
      f.approval.("480")
      |> Map.put("text", "Reminder: <@UCOMMALOCAL> can you approve the launch today?")

    f.collect.([reminder])
    assert :ok = f.check.()
    assert [_first, %{"agent_input" => %{"content" => handoff}}] = f.router_inputs.()

    # The Router sees the earlier matter with the handoff.
    assert handoff =~ ~s("continues")
    assert handoff =~ "approve the launch"

    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.workspace["default_group_id"])

    {:ok, conversation} =
      SalixIM.Conversations.get_group_conversation_record(
        f.workspace["default_group_id"],
        home["conversation_id"]
      )

    [later] =
      for {_key, value} <- SalixIM.MailInteraction.entries(conversation),
          value["source_url"] =~ "p480",
          do: value

    assert later["continues"]["subject"] =~ "approve the launch"
    assert later["assessment"]["cost"] != nil

    # The notebook shows the two together.
    notebook =
      CommaWeb.ProactiveNotebook.render(%{
        now: SystemsClock.system_time(:millisecond),
        locale: "en",
        timezone: "Etc/UTC",
        automatic: true,
        notifications: {:open, 5},
        urgent: {:open, 5},
        matters: Map.values(SalixIM.MailInteraction.entries(conversation)),
        monitors: [],
        sources: [],
        judged: [],
        briefing: nil,
        portrait: []
      })

    assert notebook =~ "continues: "
  end

  test "changed source context reaches Routine and proactive judgment without a new prompt" do
    f = withdrawal_fixture!()
    request = f.approval.("460") |> Map.put("text", "<@UCOMMALOCAL> can you review the launch?")
    f.collect.([request])
    # A review request without a deadline rates high and reaches the Router.
    assert :ok = f.check.()
    assert [_high] = f.router_inputs.()

    [earlier] =
      Comma.Repo.all(from(i in Comma.Data.MemberSourceItem, where: like(i.url, "%p460")))

    changed =
      Map.put(request, "next", %{"text" => "We need your approval tomorrow", "ts" => "461"})

    f.collect.([changed])
    [pending] = Comma.MemberSourceItems.pending(earlier.profile_id, 24)
    assert pending.prompt_context == earlier.prompt_context
    refute pending.fingerprint == earlier.fingerprint

    # Routine consumes the updated pool, rather than the old shortened prompt.
    {:ok, profile} = Recommendations.get_runtime_profile(f.workspace["id"], f.user["id"])

    {:ok, collection} =
      CommaWeb.MemberSourceIngest.collection(f.workspace, profile, max_age_s: 900)

    context =
      CommaWeb.MemberSourceIngest.context(
        collection,
        Recommendations.source_evidence(collection.facts)
      )

    candidate =
      Enum.find(
        Comma.RecommendationMemberSelection.candidates(context),
        &(&1["url"] == pending.url)
      )

    assert candidate["context"]["text"] =~ "approval tomorrow"
    assert candidate["sourceVersion"] == pending.fingerprint

    assert :ok = f.check.()
    assert length(DraftLLM.requests()) == 2
    # The changed evidence is a new observation of the same matter.
    assert [_high, _critical] = f.router_inputs.()
    {:ok, home} = SalixIM.RouterConversationInput.ensure(f.workspace["default_group_id"])

    {:ok, conversation} =
      SalixIM.Conversations.get_group_conversation_record(
        f.workspace["default_group_id"],
        home["conversation_id"]
      )

    assert Enum.any?(SalixIM.MailInteraction.entries(conversation), fn {_key, value} ->
             value["message_id"] == pending.fingerprint
           end)

    # The same evidence does not spend another judgment or send budget.
    f.collect.([changed])
    assert :ok = f.check.()
    assert length(DraftLLM.requests()) == 2
    assert length(f.router_inputs.()) == 2
  end

  test "a source revoked while the Router judges sends nothing" do
    f = withdrawal_fixture!()
    f.collect.([f.approval.("500")])
    assert f.pending.() == ["https://team.slack.com/archives/D500/p500"]

    # The answer arrives after the revocation, but the item is gone.
    DraftLLM.mode(:hold)
    judging = SystemsRuntime.Task.async(f.check)
    settle_receive({:model_waiting, judge})
    disconnect_slack!(f.user, f.workspace)
    DraftLLM.mode(:normal)
    SystemsRuntime.Proc.send(judge, :continue)
    assert :ok = settled_await(judging)
    assert [_judgment] = DraftLLM.requests()
    assert f.router_inputs.() == []
  end

  test "Routine settings turn automatic messages off, and back on from that moment" do
    {user, workspace, profile, token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, SystemsRuntime.get_env(:salix_web, key)}

    for {key, _} <- previous, do: SystemsRuntime.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      SystemsRuntime.delete_env(:comma_web, :member_slack_test)
    end)

    member_slack_http!()

    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))
    account = source["connectionId"]
    slack = %{workspace: workspace, account: account}
    SystemsRuntime.put_env(:comma_web, :member_slack_test, slack)
    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    group = workspace["default_group_id"]
    {:ok, home} = SalixIM.RouterConversationInput.ensure(group)

    setting = fn method, body ->
      conn =
        conn(method, "/v1/comma/groups/#{group}/proactive", Jason.encode!(body))
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> CommaWeb.Router.call(CommaWeb.Router.init([]))

      {conn.status, Jason.decode!(conn.resp_body)}
    end

    chain = fn ->
      job = %Oban.Job{args: %{"group_id" => group, "user_id" => user["id"]}}
      assert :ok = CommaWeb.MemberSourceIngest.perform(job)
    end

    chain_jobs = fn ->
      Comma.Repo.all(from(j in Oban.Job, where: j.worker == "CommaWeb.MemberSourceIngest"))
    end

    pool = fn ->
      Comma.Repo.all(from(i in Comma.Data.MemberSourceItem, where: i.profile_id == ^profile.id))
    end

    router_inputs = fn ->
      {:ok, messages} =
        SalixIM.Conversations.list_group_conversation_messages(group, home["conversation_id"])

      refute Enum.any?(messages, &(&1["kind"] == "message" and &1["actor_type"] == "agent"))
      Enum.filter(messages, &is_map(&1["agent_input"]))
    end

    direct = fn ts, text ->
      %{
        "text" => text,
        "user" => "U777",
        "ts" => ts,
        "channel" => %{"id" => "D#{ts}", "is_im" => true},
        "permalink" => "https://team.slack.com/archives/D#{ts}/p#{ts}"
      }
    end

    arrive = fn messages ->
      SystemsRuntime.put_env(
        :comma_web,
        :member_slack_test,
        slack |> Map.put(:direct, messages) |> Map.put(:reads, SystemsRuntime.Proc.self())
      )
    end

    # On by default. The first collection records existing work as history.
    assert {200, %{"enabled" => true}} = setting.(:get, %{})
    chain.()

    # Off: the chain stops without reading or scheduling another collection.
    assert {200, %{"enabled" => false}} =
             setting.(:put, %{"enabled" => false, "request_id" => "off-1"})

    urgent = direct.("300", "<@UCOMMALOCAL> can you approve the launch today?")
    arrive.([urgent])
    Comma.Repo.delete_all(from(j in Oban.Job, where: j.worker == "CommaWeb.MemberSourceIngest"))
    chain.()
    refute_received {:slack_read, _path}
    assert chain_jobs.() == []

    # A Routine run still records the arrival. The consumer neither judges nor
    # tells, and the Home Conversation refuses any automatic message.
    assert {:ok, %{new: 1}} = CommaWeb.MemberSourceIngest.ingest(workspace, user["id"])
    assert :ok = perform_job(CommaWeb.ProactiveCheck, %{"profile_id" => profile.id})
    assert DraftLLM.requests() == []
    assert router_inputs.() == []
    assert %{attention: %{"outcome" => "off"}} = Enum.find(pool.(), &(&1.url =~ "p300"))

    assert {:error, :proactive_disabled} =
             SalixIM.ConversationServer.mail_interaction(
               group,
               home["conversation_id"],
               user["id"],
               workspace["router_agent_id"],
               %{
                 "action" => "present",
                 "automatic" => true,
                 "key" => "off-check",
                 "request_id" => "off-check",
                 "message_id" => "m1",
                 "subject" => "Launch approval",
                 "text" => "Needs attention"
               }
             )

    # On again: the pool starts a new baseline and the chain starts again, so
    # what arrived while off stays in the Routine briefing.
    assert {200, %{"enabled" => true}} =
             setting.(:put, %{"enabled" => true, "request_id" => "on-1"})

    assert pool.() == []
    assert_enqueued(worker: CommaWeb.MemberSourceIngest, args: %{"group_id" => group})
    chain.()
    assert Enum.all?(pool.(), & &1.baseline)
    assert DraftLLM.requests() == []

    # A retried request changes nothing and keeps the pool.
    assert {200, %{"enabled" => true}} =
             setting.(:put, %{"enabled" => true, "request_id" => "on-1"})

    assert pool.() != []

    # Work that arrives after that moment interrupts as before.
    arrive.([direct.("400", "<@UCOMMALOCAL> please approve the budget today"), urgent])
    chain.()
    assert_enqueued(worker: CommaWeb.ProactiveCheck, args: %{"profile_id" => profile.id})
    assert :ok = perform_job(CommaWeb.ProactiveCheck, %{"profile_id" => profile.id})
    assert [%{"agent_input" => %{"content" => text}}] = router_inputs.()
    assert text =~ "(https://team.slack.com/archives/D400/p400)"
  end

  test "a Gmail trigger event reads that source at once and the Router receives a critical mail" do
    {user, workspace, profile, _token} = generation_fixture!()
    source = Enum.find(profile.sources, &(&1["toolkit"] == "gmail"))
    account = source["connectionId"]
    group = workspace["default_group_id"]
    tenant = workspace["salix_tenant_id"]

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, SystemsRuntime.get_env(:salix_web, key)}

    for {key, _} <- previous, do: SystemsRuntime.put_env(:salix_web, key, MemberGmail)

    gmail = %{
      workspace: workspace,
      account: account,
      webhook: true,
      owner: SystemsRuntime.Proc.self()
    }

    SystemsRuntime.put_env(:comma_web, :member_gmail_test, gmail)

    # The tenant's Composio webhook. Its secret URL is the ingress credential.
    secret = Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

    SalixStore.ComposioSettings.put(tenant, %{
      "api_key" => "ck_test",
      "enabled" => true,
      "webhook_secret" => secret
    })

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      SystemsRuntime.delete_env(:comma_web, :member_gmail_test)
      SalixStore.ComposioSettings.delete(tenant)
    end)

    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "gmail", account)

    # The first collection records the inbox as history and creates the
    # source's trigger.
    job = %Oban.Job{args: %{"group_id" => group, "user_id" => user["id"]}}
    first_read = SystemsClock.utc_now()
    assert :ok = CommaWeb.MemberSourceIngest.perform(job)
    assert_received {:upsert_trigger, ^group, ^account, "GMAIL_NEW_GMAIL_MESSAGE", %{}}
    refute Comma.MemberSourceItems.pending?(profile.id)

    # Mail arrives. The event also carries mail data, which Comma never uses:
    # the pool stores what the official read returns.
    arrived = %{id: "contract", subject: "Please approve the contract today", body: "Due 5 PM."}
    SystemsRuntime.put_env(:comma_web, :member_gmail_test, Map.put(gmail, :arrived, [arrived]))

    post = fn id ->
      Req.post!(SalixWeb.Application.base_url() <> "/v1/composio-webhooks/" <> secret,
        json: %{
          "type" => "composio.trigger.message",
          "id" => id,
          "metadata" => %{
            "user_id" => group,
            "trigger_id" => "ti_member_gmail",
            "trigger_slug" => "GMAIL_NEW_GMAIL_MESSAGE",
            "connected_account_id" => account
          },
          "data" => %{"subject" => "Wire the payment now", "messageText" => "Forged"}
        },
        retry: false
      )
    end

    assert %{status: 202, body: %{"subscribers" => 1}} = post.("evt-1")
    # A second event joins the read that waits for this source.
    assert %{status: 202} = post.("evt-2")

    assert [%{args: args, scheduled_at: at}] =
             all_enqueued(worker: CommaWeb.MemberSourceIngest, args: %{"source_id" => account})

    # The read waits until a minute after the previous read of the source.
    assert DateTime.diff(at, first_read, :microsecond) >= 60_000_000
    assert :ok = perform_job(CommaWeb.MemberSourceIngest, args)
    assert_enqueued(worker: CommaWeb.ProactiveCheck, args: %{"profile_id" => profile.id})
    assert :ok = perform_job(CommaWeb.ProactiveCheck, %{"profile_id" => profile.id})

    assert [%{url: url, attention: %{"outcome" => "routed", "urgency" => "critical"}}] =
             Comma.Repo.all(
               from(i in Comma.Data.MemberSourceItem,
                 where: i.profile_id == ^profile.id and not i.baseline
               )
             )

    {:ok, home} = SalixIM.RouterConversationInput.ensure(group)

    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(group, home["conversation_id"])

    refute Enum.any?(messages, &(&1["kind"] == "message" and &1["actor_type"] == "agent"))

    assert [%{"agent_input" => %{"content" => text}}] =
             Enum.filter(messages, &is_map(&1["agent_input"]))

    assert text =~ "(#{url})"
    refute text =~ "Wire the payment"
  end

  test "a mail cut off in the pool is read in full when the judgment cannot tell" do
    {user, workspace, profile, _token} = generation_fixture!()
    source = Enum.find(profile.sources, &(&1["toolkit"] == "gmail"))
    account = source["connectionId"]
    group = workspace["default_group_id"]

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, SystemsRuntime.get_env(:salix_web, key)}

    for {key, _} <- previous, do: SystemsRuntime.put_env(:salix_web, key, MemberGmail)

    gmail = %{
      workspace: workspace,
      account: account,
      full_reads: true,
      owner: SystemsRuntime.Proc.self()
    }

    SystemsRuntime.put_env(:comma_web, :member_gmail_test, gmail)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      SystemsRuntime.delete_env(:comma_web, :member_gmail_test)
    end)

    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "gmail", account)

    job = %Oban.Job{args: %{"group_id" => group, "user_id" => user["id"]}}
    assert :ok = CommaWeb.MemberSourceIngest.perform(job)

    # The deadline and the loss come after the pooled excerpt's budget.
    arrived = %{
      id: "deletion",
      subject: "Account notice",
      body:
        String.duplicate("We review inactive accounts regularly. ", 60) <>
          "Sign in within 3 days or your vault is permanently deleted."
    }

    SystemsRuntime.put_env(:comma_web, :member_gmail_test, Map.put(gmail, :arrived, [arrived]))
    assert :ok = CommaWeb.MemberSourceIngest.perform(job)

    [pooled] =
      Comma.Repo.all(
        from(i in Comma.Data.MemberSourceItem,
          where: i.profile_id == ^profile.id and not i.baseline
        )
      )

    assert pooled.context["truncated"]
    refute pooled.context["text"] =~ "permanently deleted"

    assert :ok = perform_job(CommaWeb.ProactiveCheck, %{"profile_id" => profile.id})
    assert_received {:full_read, "deletion"}

    assert [%{attention: %{"outcome" => "routed", "urgency" => "critical"}}] =
             Comma.Repo.all(
               from(i in Comma.Data.MemberSourceItem,
                 where: i.profile_id == ^profile.id and not i.baseline
               )
             )
  end

  test "Slack member runs require the member stamp, exclude chatter, and hide results after disconnect" do
    {user, workspace, profile, _token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, SystemsRuntime.get_env(:salix_web, key)}

    for {key, _} <- previous, do: SystemsRuntime.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      SystemsRuntime.delete_env(:comma_web, :member_slack_test)
    end)

    member_slack_http!()

    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))
    assert source["kind"] == "managed_oauth"
    account = source["connectionId"]

    SystemsRuntime.put_env(:comma_web, :member_slack_test, %{
      workspace: workspace,
      account: account
    })

    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, profile} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")

    # A grant without the member stamp (a connection from before #1919)
    # identifies nobody: the member run fails closed.
    {:ok, oauth} = Salix.Control.OAuthBindings.get(workspace["default_group_id"], account)
    {:ok, stamped} = SalixStore.OAuth.get(oauth["connection_id"])
    :ok = SalixStore.OAuth.put(oauth["connection_id"], Map.delete(stamped, "comma_member"))

    assert {:error, _} =
             CommaWeb.RecommendationOAuthSource.read_member(workspace, user["id"], source)

    {:ok, %{run: missing}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => missing["id"]}})

    assert {:ok, %{"lastError" => "member_identity_required"}} =
             Recommendations.get(user, %{}, workspace["id"])

    :ok = SalixStore.OAuth.put(oauth["connection_id"], stamped)

    assert {:ok, %{facts: [fact]}} =
             RecommendationSourceCollector.collect(workspace, [source],
               member_user_id: user["id"]
             )

    assert [%{"text" => "https://example.com/plan\n<@UCOMMALOCAL> review the plan"}] =
             fact["data"]["messages"]["matches"]

    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    assert [{messages, [], _opts}] = DraftLLM.requests()
    assert [candidate] = Jason.decode!(List.last(messages).content)["candidates"]
    assert candidate["title"] == "review the plan"
    assert candidate["excerpt"] == "https://example.com/plan\n<@UCOMMALOCAL> review the plan"
    assert candidate["recipient"] == "UCOMMALOCAL"
    assert candidate["context"]["scope"] == "search_neighbors"
    assert candidate["context"]["text"] =~ "The revised plan is ready for review."

    # Disconnecting the plugin retires the grant: published results hide.
    disconnect_slack!(user, workspace)

    assert {:ok, %{"snapshot" => nil, "state" => "error"}} =
             Recommendations.get(user, %{}, workspace["id"])

    # A new grant is a new source. Slack reports method errors with HTTP 200;
    # the failure keeps the code.
    reconnected = connect_slack!(user, workspace)
    assert {:ok, [source]} = CommaWeb.RecommendationSources.discover(workspace)
    assert source["connectionId"] == reconnected["binding_id"]
    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])

    SystemsRuntime.put_env(:comma_web, :member_slack_test, %{
      workspace: workspace,
      account: source["connectionId"],
      search_error: "missing_scope"
    })

    assert {:error, {:member_provider_error, "missing_scope"}} =
             CommaWeb.RecommendationOAuthSource.read_member(workspace, user["id"], source)

    # A bot token never identifies the member.
    SystemsRuntime.put_env(:comma_web, :member_slack_test, %{
      workspace: workspace,
      account: source["connectionId"],
      auth: %{"bot_id" => "B123"}
    })

    assert {:error, _} =
             CommaWeb.RecommendationOAuthSource.read_member(workspace, user["id"], source)

    assert profile.relevance_mode == "member"
  end

  test "Slack member reads add direct messages and threads that wait for the member" do
    {user, workspace, profile, _token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, SystemsRuntime.get_env(:salix_web, key)}

    for {key, _} <- previous, do: SystemsRuntime.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      SystemsRuntime.delete_env(:comma_web, :member_slack_test)
    end)

    member_slack_http!()

    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))
    account = source["connectionId"]

    message = fn channel, text, user, permalink ->
      %{"text" => text, "user" => user, "channel" => channel, "permalink" => permalink}
    end

    direct = %{"id" => "D1", "is_im" => true}

    SystemsRuntime.put_env(:comma_web, :member_slack_test, %{
      workspace: workspace,
      account: account,
      direct: [
        message.(
          direct,
          "Can you send the launch checklist today?",
          "U777",
          "https://team.slack.com/archives/D1/p300"
        ),
        message.(direct, "Morning!", "U777", "https://team.slack.com/archives/D1/p290"),
        message.(
          %{"id" => "G1", "is_mpim" => true},
          "Lunch?",
          "U555",
          "https://team.slack.com/archives/G1/p280"
        )
      ],
      threads: [
        message.(
          %{"id" => "C123"},
          "Does Friday still work for the rollout?",
          "U888",
          "https://team.slack.com/archives/C123/p400?thread_ts=350.0"
        ),
        message.(
          %{"id" => "C123"},
          "Shipped, thanks.",
          "UCOMMALOCAL",
          "https://team.slack.com/archives/C123/p500?thread_ts=450.0"
        ),
        message.(
          %{"id" => "C123"},
          "Can you confirm?",
          "U888",
          "https://team.slack.com/archives/C123/p490?thread_ts=450.0"
        )
      ]
    })

    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")

    assert {:ok, %{facts: [fact]}} =
             RecommendationSourceCollector.collect(workspace, [source],
               member_user_id: user["id"]
             )

    # The latest direct message per conversation, and only threads where
    # someone else spoke last. Group conversations need a mention.
    assert Enum.map(fact["data"]["messages"]["matches"], &{&1["text"], &1["memberRelation"]}) == [
             {"https://example.com/plan\n<@UCOMMALOCAL> review the plan", "mentioned_you"},
             {"Can you send the launch checklist today?", "direct_message_to_you"},
             {"Does Friday still work for the rollout?", "replied_in_your_thread"}
           ]

    # An unreadable relationship leaves the others readable and is reported.
    SystemsRuntime.put_env(
      :comma_web,
      :member_slack_test,
      Map.put(SystemsRuntime.fetch_env!(:comma_web, :member_slack_test), :direct_error, true)
    )

    assert {:ok, %{facts: [fact], failures: [failure]}} =
             RecommendationSourceCollector.collect(workspace, [source],
               member_user_id: user["id"]
             )

    assert Enum.map(fact["data"]["messages"]["matches"], & &1["memberRelation"]) ==
             ~w(mentioned_you replied_in_your_thread)

    assert failure["sourceId"] == account
    assert failure["message"] =~ "502"
  end

  test "Notion member runtime finds mentions, open items naming the member and recent drafts without setup" do
    {user, workspace, profile, _token, old_connection} = member_fixture!()
    id = "notion-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    viewer = SystemsRuntime.Proc.uuid()
    now = SystemsClock.utc_now()
    ago = fn hours -> now |> DateTime.add(-hours * 3600) |> DateTime.to_iso8601() end

    connection =
      Map.merge(old_connection, %{
        "connection_id" => id,
        "provider" => "notion",
        "metadata" => %{
          "metadata" => %{
            "workspace_id" => "notion-workspace",
            "owner" => %{"type" => "user", "user" => %{"id" => viewer}}
          }
        }
      })

    :ok = SalixStore.OAuth.put(id, connection)

    {:ok, binding, _} =
      Salix.Control.OAuthBindings.put(
        workspace["salix_tenant_id"],
        workspace["default_group_id"],
        "notion",
        "notion",
        id
      )

    source = %{
      "appId" => "notion",
      "appName" => "Notion",
      "kind" => "managed_oauth",
      "enabled" => true,
      "label" => "Workspace",
      "connectionId" => binding["binding_id"]
    }

    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])

    title = fn text -> %{"Name" => %{"type" => "title", "title" => [%{"plain_text" => text}]}} end

    status = %{
      "id" => "state",
      "type" => "status",
      "status" => %{
        "options" => [
          %{"id" => "todo", "name" => "Not started"},
          %{"id" => "doing", "name" => "In progress"},
          %{"id" => "done", "name" => "Done"}
        ],
        "groups" => [
          %{"name" => "To-do", "option_ids" => ["todo"]},
          %{"name" => "In progress", "option_ids" => ["doing"]},
          %{"name" => "Complete", "option_ids" => ["done"]}
        ]
      }
    }

    task = fn id, person, state ->
      %{
        "id" => id,
        "url" => "https://notion.so/" <> id,
        "parent" => %{"data_source_id" => "tasks-source"},
        "properties" =>
          Map.merge(title.("Work task " <> id), %{
            "Assigned" => %{"id" => "assign", "type" => "people", "people" => [%{"id" => person}]},
            "Status" => %{"id" => "state", "type" => "status", "status" => %{"name" => state}}
          })
      }
    end

    document = fn id, editor, edited ->
      %{
        "id" => id,
        "url" => "https://notion.so/" <> id,
        "parent" => %{"type" => "workspace"},
        "created_by" => %{"id" => "another-user"},
        "created_time" => ago.(24 * 30),
        "last_edited_by" => %{"id" => editor},
        "last_edited_time" => edited,
        "properties" => title.("Doc " <> id)
      }
    end

    text = fn type, value ->
      %{"type" => type, type => %{"rich_text" => [%{"plain_text" => value}]}}
    end

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case {conn.request_path, body != "" && Jason.decode!(body)} do
        {"/v1/users/me", _} ->
          Req.Test.json(conn, %{
            "bot" => %{"owner" => %{"type" => "user", "user" => %{"id" => viewer}}}
          })

        {"/v1/search", %{"filter" => %{"value" => "data_source"}}} ->
          Req.Test.json(conn, %{
            "results" => [
              %{
                "id" => "tasks-source",
                "properties" => %{
                  "Name" => %{"id" => "title", "type" => "title"},
                  "Assigned" => %{"id" => "assign", "type" => "people"},
                  "Status" => status
                }
              },
              %{
                "id" => "notes-source",
                "properties" => %{"Author" => %{"id" => "author", "type" => "people"}}
              }
            ]
          })

        {"/v1/data_sources/tasks-source/query", query} ->
          assert query["filter"]["and"] == [
                   %{"or" => [%{"property" => "assign", "people" => %{"contains" => viewer}}]},
                   %{
                     "or" => [
                       %{"property" => "state", "status" => %{"equals" => "Not started"}},
                       %{"property" => "state", "status" => %{"equals" => "In progress"}}
                     ]
                   }
                 ]

          Req.Test.json(conn, %{
            "results" => [
              task.("mine", viewer, "In progress"),
              task.("other", "another-user", "In progress"),
              task.("done", viewer, "Done")
            ]
          })

        {"/v1/search", %{"filter" => %{"value" => "page"}}} ->
          Req.Test.json(conn, %{
            "results" => [
              document.("draft", viewer, ago.(20)),
              document.("theirs", "another-user", ago.(2)),
              document.("stale", viewer, ago.(24 * 9))
            ]
          })

        {"/v1/comments", _} ->
          comment = fn id, author, text ->
            %{
              "id" => id,
              "discussion_id" => "5a1f0c2e-0000-4000-8000-00000000000" <> id,
              "created_by" => %{"id" => author},
              "created_time" => ago.(3),
              "rich_text" => [
                %{
                  "type" => "mention",
                  "mention" => %{"type" => "user", "user" => %{"id" => viewer}}
                },
                %{"type" => "text", "plain_text" => text}
              ]
            }
          end

          results =
            if Plug.Conn.fetch_query_params(conn).query_params["block_id"] == "draft",
              do: [
                comment.("1", "another-user", " can you add the p95 numbers?"),
                comment.("2", viewer, " noted")
              ],
              else: []

          Req.Test.json(conn, %{"results" => results})

        {"/v1/blocks/draft/children", _} ->
          Req.Test.json(conn, %{
            "results" => [
              text.("heading_2", "Background"),
              text.("paragraph", "The rollout moved every agent to the new runtime."),
              text.("heading_2", "Results"),
              %{
                "type" => "to_do",
                "to_do" => %{
                  "checked" => false,
                  "rich_text" => [%{"plain_text" => "Add latency numbers"}]
                }
              }
            ]
          })
      end
    end)

    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    [{messages, _, _}] = DraftLLM.requests()
    candidates = Jason.decode!(List.last(messages).content)["candidates"]

    assert [
             %{"title" => "Doc draft", "relationship" => "mentioned_you"} = mention,
             %{"title" => "Work task mine", "relationship" => "involves_you"} = task,
             %{"title" => "Doc draft", "relationship" => "edited_by_you"} = draft
           ] = candidates

    assert mention["url"] == "https://notion.so/draft?d=5a1f0c2e000040008000000000000001"
    assert mention["context"]["text"] =~ "can you add the p95 numbers?"

    assert task["context"]["text"] =~ "role: Assigned\nstatus: In progress"
    assert draft["context"]["text"] =~ "outline: Background / Results"
    assert draft["context"]["text"] =~ "[ ] Add latency numbers"

    assert {:ok, %{"state" => "fresh", "snapshot" => %{"warnings" => []}} = envelope} =
             Recommendations.get(user, %{}, workspace["id"])

    refute Map.has_key?(envelope["settings"], "notionTaskRules")
  end

  defp member_fixture! do
    {user, workspace, profile, token} = generation_fixture!()
    previous = SystemsRuntime.get_env(:comma_web, :recommendation_oauth_http_options)

    SystemsRuntime.put_env(:comma_web, :recommendation_oauth_http_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn -> restore_env(:comma_web, :recommendation_oauth_http_options, previous) end)
    id = "member-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    connection = %{
      "connection_id" => id,
      "provider" => "linear",
      "tenant" => workspace["salix_tenant_id"],
      "status" => "active",
      "access_token" => "member-token",
      "scopes" => ["read"],
      "comma_member" => %{"user_id" => user["id"], "workspace_id" => workspace["id"]},
      "metadata" => %{
        "metadata" => %{"actor" => "user", "viewer_id" => "viewer", "workspace_id" => "org"}
      }
    }

    :ok = SalixStore.OAuth.put(id, connection)

    {:ok, binding, _} =
      Salix.Control.OAuthBindings.put(
        workspace["salix_tenant_id"],
        workspace["default_group_id"],
        "linear",
        "linear",
        id
      )

    source = %{
      "appId" => "linear",
      "appName" => "Linear",
      "label" => "Linear",
      "kind" => "managed_oauth",
      "enabled" => true,
      "connectionId" => binding["binding_id"]
    }

    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, profile} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    {user, workspace, profile, token, connection}
  end

  defp member_response(issues) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "organization" => %{"id" => "org"},
          "viewer" => %{"id" => "viewer", "assignedIssues" => %{"nodes" => issues}},
          "notifications" => %{"nodes" => []}
        }
      })
    end)
  end

  defp generation_fixture!(protocol \\ "chat_completions") do
    enable_local_recommendation_mock!()
    configure_local_llm!(protocol)

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "routine-job-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)
    connect_slack!(user, workspace)
    assert {:ok, _} = RecommendationRuntime.ensure(user, %{}, workspace, "UTC")
    # This fixture exercises the retained generic recipe; member tests opt in below.
    assert {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "generic")
    assert {:ok, profile} = Recommendations.get_runtime_profile(workspace["id"], user["id"])
    assert :ok = RecommendationRuntime.sync_sources(profile.id)
    assert {:ok, profile} = Recommendations.get_runtime_profile(workspace["id"], user["id"])
    previous = SystemsRuntime.get_env(:salix_agent, :llm)
    SystemsRuntime.put_env(:salix_agent, :llm, DraftLLM)
    start_supervised!({DraftLLM, SystemsRuntime.Proc.self()})
    on_exit(fn -> restore_env(:salix_agent, :llm, previous) end)
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    {user, workspace, profile, session["token"]}
  end

  defp request(method, workspace, token, suffix, body \\ %{}) do
    conn(
      method,
      "/v1/comma/workspaces/#{workspace["id"]}/recommendations#{suffix}",
      Jason.encode!(body)
    )
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  test "adding an app that already holds an active account leaves one account and one source" do
    enable_local_recommendation_mock!()
    configure_local_llm!()

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" =>
          "local-recommendation-readd-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)
    group_id = workspace["default_group_id"]

    {:ok, composio_fixture} =
      Salix.Control.Plugins.create_definition(
        workspace["salix_tenant_id"],
        workspace["default_group_id"],
        %{
          "name" => "Test messaging",
          "owner_scope" => "group",
          "setup" => %{
            "type" => "integration",
            "default_connection" => "slack-composio",
            "connections" => [
              %{
                "id" => "slack-composio",
                "kind" => "composio",
                "label" => "Slack via Composio",
                "toolkit" => "slack"
              }
            ]
          }
        }
      )

    plugin_id = composio_fixture["plugin_id"]

    slack_accounts = fn ->
      {:ok, accounts} = SalixWeb.LocalComposioMock.list_connected_accounts(%{}, group_id)
      Enum.filter(accounts, &(get_in(&1, ["toolkit", "slug"]) == "slack"))
    end

    # The local world already holds an active Slack account, like a member
    # whose earlier authorization the provider kept.
    assert [%{"id" => earlier_id}] = slack_accounts.()

    # The provider stamps each account's creation on the clock: the member
    # adds the app a second later, so the new account is the newer one.
    SystemsClock.run_for(1_000)

    # Add obtains fresh consent: a second account exists until it completes.
    assert {:ok, install} =
             CommaWeb.PluginConnections.install(user, %{}, workspace["id"], plugin_id)

    state = install["authorization"]["state"]
    assert is_binary(state)
    assert [%{"id" => new_id}, %{"id" => ^earlier_id}] = slack_accounts.()
    assert new_id != earlier_id

    assert {:ok, completed} =
             CommaWeb.PluginConnections.install(user, %{}, workspace["id"], plugin_id, %{
               "authorization_state" => state,
               "verify_only" => true
             })

    assert completed["plugin"]["installed"] == true
    assert [%{"id" => ^new_id}] = slack_accounts.()

    # Account replacement is a plugin fact. Routine discovery never lists a
    # Composio Slack account: Slack reads use the managed binding only.
    assert {:ok, sources} = CommaWeb.RecommendationSources.discover(workspace)
    assert Enum.filter(sources, &(&1["toolkit"] == "slack")) == []
  end

  test "runtime sync excludes an active unsupported Composio account before collection" do
    enable_local_recommendation_mock!()
    configure_local_llm!()

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" =>
          "local-recommendation-unsupported-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)

    assert {:ok, %{"connected_account_id" => supported_account_id}} =
             SalixWeb.LocalComposioMock.create_connect_link(
               %{},
               "local-auth-config-gmail",
               workspace["default_group_id"]
             )

    assert {:ok, %{"connected_account_id" => unsupported_account_id}} =
             SalixWeb.LocalComposioMock.create_connect_link(
               %{},
               "local-auth-config-jira",
               workspace["default_group_id"]
             )

    assert {:ok, accounts} =
             SalixWeb.LocalComposioMock.list_connected_accounts(
               %{},
               workspace["default_group_id"]
             )

    assert %{"status" => "ACTIVE", "toolkit" => %{"slug" => "jira"}} =
             Enum.find(accounts, &(&1["id"] == unsupported_account_id))

    assert {:ok, _envelope} = RecommendationRuntime.ensure(user, %{}, workspace, "UTC")
    assert {:ok, profile} = Recommendations.get_runtime_profile(workspace["id"], user["id"])
    assert :ok = RecommendationRuntime.sync_sources(profile.id)
    assert {:ok, profile} = Recommendations.get_runtime_profile(workspace["id"], user["id"])

    assert Enum.any?(profile.sources, &(&1["connectionId"] == supported_account_id))
    refute Enum.any?(profile.sources, &(&1["connectionId"] == unsupported_account_id))

    assert {:ok, envelope} = Recommendations.get(user, %{}, workspace["id"], "UTC")

    refute Enum.any?(
             envelope["settings"]["sources"],
             &(&1["connectionId"] == unsupported_account_id)
           )

    assert {:ok, %{facts: facts, failures: failures}} =
             RecommendationSourceCollector.collect(workspace, profile.sources)

    assert Enum.any?(facts, &(&1["sourceId"] == supported_account_id))

    refute Enum.any?(
             facts ++ failures,
             &(&1["sourceId"] == unsupported_account_id)
           )
  end

  test "switching out of the local mock invalidates its snapshot and active run" do
    enable_local_recommendation_mock!()
    configure_local_llm!()

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" =>
          "local-recommendation-switch-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)
    assert {:ok, _plugin} = Comma.Plugins.install(user, %{}, workspace["id"], "slack")
    assert {:ok, _envelope} = RecommendationRuntime.ensure(user, %{}, workspace, "UTC")
    assert {:ok, profile} = Recommendations.get_runtime_profile(workspace["id"], user["id"])
    assert :ok = RecommendationRuntime.sync_sources(profile.id)

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace["id"], "manual")

    assert {:ok, %{enabled: false}} = SalixWeb.LocalOAuthMock.set_enabled(false)
    assert :ok = RecommendationRuntime.reset_for_mode_change(user, %{}, workspace)

    assert {:ok, switched} = Recommendations.get(user, %{}, workspace["id"], "UTC")
    assert switched["state"] == "empty"
    assert switched["snapshot"] == nil
    assert switched["settings"]["sources"] == []

    assert {:ok, %{run: stored_run}} = Recommendations.run_context(run["id"])
    assert stored_run.status == "superseded"
  end

  test "link previews read through the local Composio mock with production argument names" do
    enable_local_recommendation_mock!()

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" =>
          "local-recommendation-preview-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)
    group_id = workspace["default_group_id"]

    source = fn toolkit ->
      %{
        "appId" => toolkit,
        "appName" => String.capitalize(toolkit),
        "connectionId" => "local-#{group_id}-#{toolkit}",
        "enabled" => true,
        "kind" => "composio",
        "toolkit" => toolkit
      }
    end

    # Materialize the group's local accounts, exactly like connecting them.
    assert {:ok, _accounts} = SalixWeb.LocalComposioMock.list_connected_accounts(%{}, group_id)

    # Each hover read crosses the real preview module into the local mock, so
    # an argument-name drift between the production call and the provider
    # contract the mock enforces (e.g. row_id vs page_id) fails here.
    [notion_page] = SalixWeb.LocalProviderFixtures.notion_pages_data()["values"]

    assert {:ok, %{"kind" => "notion_page", "title" => "Q3 plan"}} =
             authorized_preview(
               workspace,
               [source.("notion")],
               notion_page["url"],
               nil
             )

    assert {:ok, %{"kind" => "github_pull_request", "state" => "merged", "number" => 845}} =
             authorized_preview(
               workspace,
               [source.("github")],
               "https://github.com/AFK-surf/Comma/pull/845",
               nil
             )

    assert {:ok,
            %{
              "kind" => "linear_issue",
              "identifier" => "COMMA-143",
              "title" => "Fix onboarding crash on first launch"
            }} =
             authorized_preview(
               workspace,
               [source.("linear")],
               "https://linear.app/comma/issue/COMMA-143",
               nil
             )

    event = SalixWeb.LocalProviderFixtures.calendar_event("evt123")

    assert {:ok,
            %{
              "kind" => "google_calendar_event",
              "title" => "Launch review",
              "startsAt" => starts_at
            }} =
             authorized_preview(
               workspace,
               [source.("googlecalendar")],
               event["htmlLink"],
               nil
             )

    assert is_integer(starts_at)
  end

  defp enable_local_recommendation_mock! do
    keys = [
      {:salix_web, :local_oauth_mock},
      {:salix_web, :public_base_url},
      {:salix_web, :composio_client_mod},
      {:salix_web, :composio_settings_mod},
      {:salix_agent, :composio_client_mod},
      {:salix_agent, :composio_store_mod},
      {:salix_store, :oauth_endpoint_overrides},
      {:salix_mcp, :remote_target_overrides},
      {:salix_mcp, :private_http_target_allowlist}
    ]

    previous = Map.new(keys, fn {app, key} -> {{app, key}, SystemsRuntime.get_env(app, key)} end)
    base_url = SalixWeb.Application.base_url()

    SystemsRuntime.put_env(:salix_web, :public_base_url, base_url)
    assert {:ok, %{enabled: true}} = SalixWeb.LocalOAuthMock.set_enabled(true)

    on_exit(fn ->
      _ = SalixWeb.LocalOAuthMock.set_enabled(false)
      Enum.each(previous, fn {{app, key}, value} -> restore_env(app, key, value) end)
    end)
  end

  # The deterministic local LLM as the platform model the Workspace's Agents follow.
  defp configure_local_llm!(protocol \\ "chat_completions"),
    do: configure_platform_llm!("gpt-local-dev", protocol, "http://llm-mock:23123")

  defp configure_platform_llm!(model, protocol, base_url) do
    platform = SalixAgent.AccountPool.platform_tenant()

    {:ok, profile} =
      SalixAgent.AccountPool.create(platform, %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "api_key" => "sk-local-dev-only-0123456789",
        "base_url" => base_url,
        "protocol" => protocol,
        "models" => [model]
      })

    {:ok, previous} = SalixAgent.PlatformModels.get()

    on_exit(fn ->
      {:ok, _} = SalixAgent.PlatformModels.put(previous)

      SalixAgent.SubscriptionStore.query("DELETE FROM subscription_accounts WHERE id=$1", [
        profile["id"]
      ])
    end)

    entry = %{"profile_id" => profile["id"], "model" => model, "protocol" => protocol}

    tiers =
      Map.merge(previous["tiers"] || %{}, %{"router" => entry, "worker" => entry})

    {:ok, _} = SalixAgent.PlatformModels.put(Map.put(previous, "tiers", tiers))
  end

  # The owner's managed Slack source in member mode, with a recorded
  # baseline. Each collection only records the pool; the proactive consumer
  # runs when the test says.
  defp withdrawal_fixture! do
    {user, workspace, profile, _token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, SystemsRuntime.get_env(:salix_web, key)}

    for {key, _} <- previous, do: SystemsRuntime.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      SystemsRuntime.delete_env(:comma_web, :member_slack_test)
    end)

    member_slack_http!()

    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))
    account = source["connectionId"]
    slack = %{workspace: workspace, account: account}
    SystemsRuntime.put_env(:comma_web, :member_slack_test, slack)
    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    group = workspace["default_group_id"]

    collect = fn direct ->
      SystemsRuntime.put_env(:comma_web, :member_slack_test, Map.put(slack, :direct, direct))
      job = %Oban.Job{args: %{"group_id" => group, "user_id" => user["id"]}}
      assert :ok = CommaWeb.MemberSourceIngest.perform(job)
    end

    check = fn -> perform_job(CommaWeb.ProactiveCheck, %{"profile_id" => profile.id}) end

    pending = fn ->
      Enum.map(Comma.MemberSourceItems.pending(profile.id, 24), & &1.url)
    end

    router_inputs = fn ->
      {:ok, home} = SalixIM.RouterConversationInput.ensure(group)

      {:ok, messages} =
        SalixIM.Conversations.list_group_conversation_messages(group, home["conversation_id"])

      refute Enum.any?(messages, &(&1["kind"] == "message" and &1["actor_type"] == "agent"))
      Enum.filter(messages, &is_map(&1["agent_input"]))
    end

    approval = fn ts ->
      %{
        "text" => "<@UCOMMALOCAL> can you approve the launch today?",
        "user" => "U777",
        "ts" => ts,
        "channel" => %{"id" => "D#{ts}", "is_im" => true},
        "permalink" => "https://team.slack.com/archives/D#{ts}/p#{ts}"
      }
    end

    settings = fn enabled ->
      current = Comma.Repo.get!(Comma.Data.RecommendationProfile, profile.id)

      %{
        "schedule" => %{
          "enabled" => current.schedule_enabled,
          "hour" => current.schedule_hour,
          "minute" => current.schedule_minute,
          "timezone" => current.timezone
        },
        "autoEnableNewSources" => current.auto_enable_new_sources,
        "sources" => [%{"connectionId" => account, "enabled" => enabled}]
      }
    end

    collect.([])

    %{
      user: user,
      workspace: workspace,
      account: account,
      collect: collect,
      check: check,
      pending: pending,
      router_inputs: router_inputs,
      approval: approval,
      settings: settings,
      user: user
    }
  end

  # The built-in Slack plugin's managed authorization through the local OAuth
  # mock: the Group binding carries the member stamp and the local identity.
  defp connect_slack!(user, workspace) do
    # The plugin's Slack MCP binding needs the built-in definitions, which an
    # earlier suite may have cleared with its storage backend.
    {:ok, _} = SalixMCP.Builtins.seed_builtin_definitions()

    assert {:ok, install} =
             CommaWeb.PluginConnections.install(user, %{}, workspace["id"], "slack")

    state =
      install["authorization"]["authorizationUrl"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    SalixWeb.OAuthFlow.handle_callback("slack", %{"state" => state, "code" => "test"})

    assert {:ok, %{"plugin" => %{"installed" => true}}} =
             CommaWeb.PluginConnections.install(user, %{}, workspace["id"], "slack", %{
               "verify_only" => true,
               "authorization_state" => install["authorization"]["state"]
             })

    workspace["default_group_id"]
    |> Salix.Control.OAuthBindings.list()
    |> Enum.find(&(&1["provider"] == "slack" and &1["alias"] == "slack"))
  end

  # Removing the plugin disconnects the managed grant, like the owner's
  # Disconnect in Plugins.
  defp disconnect_slack!(user, workspace) do
    assert {:ok, _} = CommaWeb.PluginConnections.uninstall(user, %{}, workspace["id"], "slack")
  end

  # The built-in GitHub plugin's managed authorization through the local OAuth
  # mock, like connect_slack!/2.
  defp connect_github!(user, workspace) do
    assert {:ok, install} =
             CommaWeb.PluginConnections.install(user, %{}, workspace["id"], "github")

    state =
      install["authorization"]["authorizationUrl"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    SalixWeb.OAuthFlow.handle_callback("github", %{"state" => state, "code" => "test"})

    assert {:ok, %{"plugin" => %{"installed" => true}}} =
             CommaWeb.PluginConnections.install(user, %{}, workspace["id"], "github", %{
               "verify_only" => true,
               "authorization_state" => install["authorization"]["state"]
             })
  end

  # Managed GitHub member reads go to the MemberGitHub stub instead of the API.
  defp member_github_http!(state) do
    previous = SystemsRuntime.get_env(:comma_web, :recommendation_oauth_http_options)
    SystemsRuntime.put_env(:comma_web, :member_github_test, state)
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(MemberGitHub, &MemberGitHub.call/1)

    SystemsRuntime.put_env(:comma_web, :recommendation_oauth_http_options,
      plug: {Req.Test, MemberGitHub}
    )

    on_exit(fn ->
      restore_env(:comma_web, :recommendation_oauth_http_options, previous)
      SystemsRuntime.delete_env(:comma_web, :member_github_test)
    end)
  end

  # Managed Slack reads go to the MemberSlack stub instead of the Web API.
  defp member_slack_http! do
    previous = SystemsRuntime.get_env(:comma_web, :recommendation_oauth_http_options)
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(MemberSlack, &MemberSlack.call/1)

    SystemsRuntime.put_env(:comma_web, :recommendation_oauth_http_options,
      plug: {Req.Test, MemberSlack}
    )

    on_exit(fn -> restore_env(:comma_web, :recommendation_oauth_http_options, previous) end)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defmodule OutlookPreviewClient do
    def get(_tenant), do: {:ok, %{}}

    def get_connected_account(_settings, id) do
      fixture = SystemsRuntime.fetch_env!(:comma_web, :outlook_preview_fixture)
      state = if fixture[:rebind], do: "INACTIVE", else: "ACTIVE"

      {:ok,
       %{
         "id" => id,
         "user_id" => fixture.group,
         "toolkit" => %{"slug" => "outlook"},
         "status" => state
       }}
    end

    def create_proxy_session(_settings, _group, _id, "outlook", _opts),
      do: {:ok, "outlook-preview"}

    def delete_proxy_session(_settings, "outlook-preview"), do: :ok

    def proxy_execute(_settings, "outlook-preview", %{"endpoint" => endpoint}, _opts) do
      fixture = SystemsRuntime.fetch_env!(:comma_web, :outlook_preview_fixture)

      data =
        cond do
          String.ends_with?(endpoint, "/me?$select=id") ->
            %{"id" => fixture.provider_user}

          String.contains?(endpoint, "/me/messages/") ->
            %{
              "id" => fixture.message,
              "webLink" => fixture.url,
              "subject" => "Private mail",
              "bodyPreview" => "Review it"
            }

          String.contains?(endpoint, "/me/events/") ->
            %{
              "id" => fixture.event,
              "webLink" => fixture.url,
              "subject" => "Private event",
              "start" => %{"dateTime" => "2026-10-06T09:00:00.0000000", "timeZone" => "UTC"}
            }
        end

      if fixture[:rebind_during_read] == true and
           not String.ends_with?(endpoint, "/me?$select=id"),
         do:
           SystemsRuntime.put_env(
             :comma_web,
             :outlook_preview_fixture,
             Map.put(fixture, :rebind, true)
           )

      {:ok, %{"status" => 200, "data" => data}}
    end
  end

  test "collected Outlook mail and event use exact URL/id/account; rebind and other links fail closed" do
    {user, workspace, profile, _token} = generation_fixture!()
    account = "ca-outlook-preview"
    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "outlook", account)
    consent = Comma.MemberSourceConsents.binding(workspace["id"], user["id"], "outlook")

    profile =
      profile
      |> Ecto.Changeset.change(%{
        relevance_mode: "member",
        sources: [
          %{
            "appId" => "outlook",
            "toolkit" => "outlook",
            "kind" => "composio",
            "enabled" => true,
            "connectionId" => account
          }
        ]
      })
      |> Comma.Repo.update!()

    subject =
      Map.merge(consent, %{
        "user_id" => user["id"],
        "toolkit" => "outlook",
        "provider_user_id" => "graph-owner"
      })

    urls = [
      {"message", "https://outlook.office.com/mail/id/AAMk1", %{"messageId" => "AAMk1"}},
      {"event", "https://outlook.office.com/calendar/item/AAEv1", %{"eventId" => "AAEv1"}}
    ]

    keys =
      Enum.map(urls, fn {_, url, _} -> Base.encode16(:crypto.hash(:sha256, url), case: :lower) end)

    now = SystemsClock.utc_now()

    Comma.Repo.insert!(%Comma.Data.MemberSourceState{
      profile_id: profile.id,
      source_id: account,
      toolkit: "outlook",
      subject: subject,
      current_keys: keys,
      collected_at: now,
      attempted_at: now
    })

    for {{_, url, ids}, key} <- Enum.zip(urls, keys) do
      Comma.Repo.insert!(%Comma.Data.MemberSourceItem{
        profile_id: profile.id,
        source_id: account,
        item_key: key,
        toolkit: "outlook",
        url: url,
        provider_ids: ids,
        fingerprint: key,
        first_seen_at: now,
        changed_at: now,
        last_seen_at: now
      })
    end

    old_client = SystemsRuntime.get_env(:salix_web, :composio_client_mod)
    old_settings = SystemsRuntime.get_env(:salix_web, :composio_settings_mod)
    SystemsRuntime.put_env(:salix_web, :composio_client_mod, OutlookPreviewClient)
    SystemsRuntime.put_env(:salix_web, :composio_settings_mod, OutlookPreviewClient)

    on_exit(fn ->
      restore_env(:salix_web, :composio_client_mod, old_client)
      restore_env(:salix_web, :composio_settings_mod, old_settings)
      SystemsRuntime.delete_env(:comma_web, :outlook_preview_fixture)
    end)

    for {kind, url, _ids} <- urls do
      fixture = %{
        group: workspace["default_group_id"],
        provider_user: "graph-owner",
        url: url,
        message: "AAMk1",
        event: "AAEv1"
      }

      SystemsRuntime.put_env(:comma_web, :outlook_preview_fixture, fixture)

      assert {:ok, %{"kind" => card_kind, "href" => ^url}} =
               CommaWeb.RecommendationOutlookPreview.preview(workspace, user["id"], url, account)

      assert card_kind == "outlook_" <> kind

      # Graph's zoneless UTC string becomes epoch milliseconds, like Google Calendar.
      assert {:ok, %{"startsAt" => starts_at}} =
               CommaWeb.RecommendationOutlookPreview.preview(workspace, user["id"], url, account)

      assert starts_at ==
               if(kind == "event",
                 do: DateTime.to_unix(~U[2026-10-06 09:00:00Z], :millisecond),
                 else: nil
               )

      assert {:error, :not_found} =
               CommaWeb.RecommendationOutlookPreview.preview(
                 workspace,
                 user["id"],
                 url <> "?uncollected=true",
                 account
               )

      assert {:error, :not_found} =
               CommaWeb.RecommendationOutlookPreview.preview(
                 workspace,
                 user["id"],
                 url,
                 "other-account"
               )

      SystemsRuntime.put_env(
        :comma_web,
        :outlook_preview_fixture,
        Map.put(fixture, :rebind_during_read, true)
      )

      assert {:error, :not_found} =
               CommaWeb.RecommendationOutlookPreview.preview(
                 workspace,
                 user["id"],
                 url,
                 account
               )
    end
  end

  defp authorized_preview(workspace, sources, href, source_id) do
    viewer = workspace["owner_user_id"] || "test-viewer"
    workspace = Map.put(workspace, "owner_user_id", viewer)
    CommaWeb.RecommendationLinkPreview.preview(workspace, sources, href, source_id, viewer)
  end
end
