defmodule CommaWeb.LocalRecommendationFlowTest do
  use Comma.DataCase, async: false
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

    def complete_stream(messages, tools, _delta, opts) do
      state =
        Agent.get_and_update(__MODULE__, fn state ->
          {state, %{state | requests: [{messages, tools, opts} | state.requests]}}
        end)

      if state.mode == :hold do
        send(state.owner, {:model_waiting, self()})

        receive do
          :continue -> :ok
        end
      end

      case state.mode do
        :deepseek_chat ->
          transport = fn _url, request ->
            body = Jason.decode!(request[:body])
            send(state.owner, {:routine_provider_request, body})

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

      if Map.has_key?(input["contentSchema"]["properties"], "most_urgent") do
        rated =
          Enum.map(input["candidates"], fn candidate ->
            cond do
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
            %{
              "most_urgent" => %{
                "id" => candidate["id"],
                "urgency" => level,
                "message" =>
                  "Milo is waiting for your launch approval today. Want me to draft the reply?"
              }
            }
        end
      else
        member_or_generic(input)
      end
    end

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
      do: Process.exit(self(), :kill)

    def execute_tool(settings, tool, group, args, opts),
      do: SalixWeb.LocalComposioMock.execute_tool(settings, tool, group, args, opts)
  end

  defmodule AllCrashedSources do
    def execute_tool(_settings, _tool, _group, _args, _opts), do: Process.exit(self(), :kill)
  end

  defmodule MemberGmail do
    def get(_tenant) do
      state = Application.get_env(:comma_web, :member_gmail_test, %{})
      {:ok, if(state[:webhook], do: %{"webhook_configured" => true}, else: %{})}
    end

    def get_connected_account(_settings, id, _opts \\ []) do
      %{workspace: workspace} = Application.fetch_env!(:comma_web, :member_gmail_test)

      {:ok,
       %{
         "id" => id,
         "user_id" => workspace["default_group_id"],
         "toolkit" => %{"slug" => "gmail"},
         "status" => "ACTIVE"
       }}
    end

    def upsert_trigger(_settings, group, account, slug, config) do
      state = Application.fetch_env!(:comma_web, :member_gmail_test)
      send(state.owner, {:upsert_trigger, group, account, slug, config})
      {:ok, %{"trigger_id" => "ti_member_gmail"}}
    end

    def create_proxy_session(_settings, group, account, "gmail", _opts) do
      state = Application.fetch_env!(:comma_web, :member_gmail_test)
      true = state.account == account and state.workspace["default_group_id"] == group
      {:ok, "member-gmail-session"}
    end

    def delete_proxy_session(_settings, "member-gmail-session"), do: :ok

    def proxy_execute(_settings, "member-gmail-session", request, _opts) do
      %{"toolkit_slug" => "gmail", "method" => "GET", "endpoint" => endpoint} = request
      "https://gmail.googleapis.com/gmail/v1/users/me" <> path = endpoint
      state = Application.fetch_env!(:comma_web, :member_gmail_test)

      message = fn id, subject, body ->
        %{
          "id" => id,
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
            Process.sleep(2_000)
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
        end

      {:ok, %{"status" => 200, "data" => data}}
    end
  end

  defmodule MemberSlack do
    def get(_tenant), do: {:ok, %{}}

    def get_connected_account(_settings, id) do
      %{workspace: workspace} = Application.fetch_env!(:comma_web, :member_slack_test)

      {:ok,
       %{
         "id" => id,
         "user_id" => workspace["default_group_id"],
         "toolkit" => %{"slug" => "slack"},
         "status" => "ACTIVE"
       }}
    end

    def create_proxy_session(_settings, group, account, "slack", _opts) do
      state = Application.fetch_env!(:comma_web, :member_slack_test)
      true = state.account == account and state.workspace["default_group_id"] == group
      {:ok, "member-auth-session"}
    end

    def proxy_execute(_settings, "member-auth-session", request, _opts) do
      %{"toolkit_slug" => "slack", "method" => "GET", "endpoint" => endpoint} = request
      state = Application.fetch_env!(:comma_web, :member_slack_test)
      %URI{host: "slack.com", path: path, query: query} = URI.parse(endpoint)
      if state[:reads], do: send(state.reads, {:slack_read, path})

      data =
        case {path, URI.decode_query(query || "")["query"]} do
          {"/api/auth.test", nil} ->
            Map.merge(
              %{"ok" => true, "user_id" => "U123", "team_id" => "T123"},
              Map.get(state, :auth, %{})
            )

          {"/api/search.messages", _query} when is_map_key(state, :search_error) ->
            %{"ok" => false, "error" => state.search_error}

          {"/api/search.messages", "<@U123> after:" <> _} ->
            search([
              %{
                "text" => "https://example.com/plan\n<@U123> review the plan",
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
              send(owner, {:source_waiting, self()})

              receive do
                :continue -> :ok
              end
            end

            search(Map.get(state, :direct, []))

          {"/api/search.messages", "is:thread with:<@U123> after:" <> _} ->
            search(Map.get(state, :threads, []))
        end

      respond(data)
    end

    defp search(matches), do: %{"ok" => true, "messages" => %{"matches" => matches}}

    defp respond(:unavailable), do: {:ok, %{"status" => 502, "data" => %{}}}
    defp respond(data), do: {:ok, %{"status" => 200, "data" => data}}

    def delete_proxy_session(_settings, "member-auth-session"), do: :ok
  end

  # Collection tests observe the durable handoff, not a second LLM turn.
  defmodule RouterDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(_agent, _payload, _opts), do: {:ok, :queued}
  end

  setup do
    previous_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, RouterDelivery)
    on_exit(fn -> restore_env(:salix_im, :agent_delivery_mod, previous_delivery) end)
    Req.Test.set_req_test_to_shared()
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
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
          do: {key, Application.get_env(:salix_web, key)}

    for {key, _} <- previous, do: Application.put_env(:salix_web, key, MemberGmail)
    Application.put_env(:comma_web, :member_gmail_test, %{workspace: workspace, account: account})

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      Application.delete_env(:comma_web, :member_gmail_test)
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
          do: {key, Application.get_env(:salix_web, key)}

    for {key, _} <- previous, do: Application.put_env(:salix_web, key, MemberGmail)

    Application.put_env(:comma_web, :member_gmail_test, %{
      workspace: workspace,
      account: account,
      stalled: true
    })

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      Application.delete_env(:comma_web, :member_gmail_test)
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
    previous = Application.get_env(:comma_web, :recommendation_composio_client_mod)
    Application.put_env(:comma_web, :recommendation_composio_client_mod, CrashedSource)
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

    Application.put_env(:comma_web, :recommendation_composio_client_mod, AllCrashedSources)
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

  test "DeepSeek generic refresh publishes through its supported chat response format" do
    {user, workspace, _profile, token} = generation_fixture!()
    template = Application.fetch_env!(:comma_core, :default_agent_template)

    Application.put_env(
      :comma_core,
      :default_agent_template,
      template
      |> Map.put("model", "deepseek-flash")
      |> Map.put("provider_config", %{
        "base_url" => "https://api.deepseek.com",
        "api_key" => "local-dev-only"
      })
    )

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
        inserted_at: DateTime.add(DateTime.utc_now(), -480, :second)
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
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -3_600, :second))
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
      Task.async(fn ->
        RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => first["run"]["id"]}})
      end)

    assert_receive {:model_waiting, model}, 5_000
    assert request(:get, workspace, token, "").status == 200
    second = request(:post, workspace, token, "/refresh")
    assert second.status == 202
    second_id = Jason.decode!(second.resp_body)["run"]["id"]
    send(model, :continue)
    assert :ok = Task.await(task, 5_000)

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

  @tag sandbox: false
  test "a committed refresh cancels the executing Oban owner and releases its model dependency" do
    # PostgreSQL sends Oban's cancellation only after COMMIT. This test needs
    # real connections and a queue producer; a sandbox rollback cannot prove it.
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :manual) end)
    {user, workspace, profile, token} = generation_fixture!()

    on_exit(fn ->
      Comma.Repo.query!(
        """
        DELETE FROM oban_jobs WHERE args->>'profile_id' = $1 OR args->>'run_id' IN
          (SELECT id::text FROM comma_recommendation_runs WHERE profile_id = $1::uuid)
        """,
        [profile.id]
      )

      Comma.WorkspaceTestSupport.cleanup_committed_user!(Process.whereis(Comma.Repo), user["id"])
    end)

    DraftLLM.mode(:hold)
    first = request(:post, workspace, token, "/refresh") |> then(&Jason.decode!(&1.resp_body))

    start_supervised!(
      {Oban,
       name: Comma.RoutineExecutionTestOban,
       repo: Comma.Repo,
       peer: {Oban.Peers.Isolated, []},
       queues: [comma_recommendations: 1],
       plugins: false,
       testing: :disabled}
    )

    assert_receive {:model_waiting, model}, 5_000
    monitor = Process.monitor(model)
    DraftLLM.mode(:normal)
    second = request(:post, workspace, token, "/refresh")
    assert second.status == 202
    assert_receive {:DOWN, ^monitor, :process, ^model, _}, 5_000

    assert {:ok, %{run: %{status: "superseded"}}} =
             Recommendations.run_context(first["run"]["id"])

    second_id = Jason.decode!(second.resp_body)["run"]["id"]
    assert wait_for_publication(second_id, 100)
    assert length(DraftLLM.requests()) == 2
  end

  defp wait_for_publication(_run_id, 0), do: false

  defp wait_for_publication(run_id, attempts) do
    case Recommendations.run_context(run_id) do
      {:ok, %{run: %{status: "published"}}} ->
        true

      _ ->
        Process.sleep(50)
        wait_for_publication(run_id, attempts - 1)
    end
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
        "state" => %{"type" => "started"}
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
    assert snapshot["prompts"][prompt_id]["context"] == ~s(My task state: {"type":"started"})

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
    archive = Application.get_env(:salix_agent, :event_archive_mod)
    Application.put_env(:salix_agent, :event_archive_mod, DraftLLM)
    on_exit(fn -> restore_env(:salix_agent, :event_archive_mod, archive) end)

    for {role, model} <- [{"router", "router-judge"}, {"worker", "worker-model"}] do
      {:ok, template} =
        SalixAgent.Templates.create_private(
          %{
            "name" => model,
            "model" => model,
            "provider" => "openai",
            "provider_config" => %{
              "protocol" => "chat_completions",
              "base_url" => "http://llm-mock:43123",
              "api_key" => "local-dev-only"
            },
            "max_tokens" => 4096
          },
          workspace["salix_tenant_id"]
        )

      assert {:ok, _} =
               Comma.Salix.Client.update_workspace_agent_model(
                 workspace,
                 role,
                 template["template_id"]
               )
    end

    # The local mock substitutes one deterministic template for every Agent.
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

  test "collection feeds the item pool and hands arrivals the owner must act on to the Router" do
    {user, workspace, profile, _token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, Application.get_env(:salix_web, key)}

    for {key, _} <- previous, do: Application.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      Application.delete_env(:comma_web, :member_slack_test)
    end)

    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))
    account = source["connectionId"]
    slack = %{workspace: workspace, account: account}
    Application.put_env(:comma_web, :member_slack_test, slack)
    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "slack", account)
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
    Application.put_env(
      :comma_web,
      :member_slack_test,
      Map.put(slack, :direct, [direct.("200", "<@U123> can you review the notes this week?")])
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
    Application.put_env(
      :comma_web,
      :member_slack_test,
      Map.put(slack, :direct, [
        direct.("400", "<@U123> please review the budget too"),
        direct.("300", "<@U123> can you approve the launch today?")
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

    assert next_at > System.system_time(:millisecond)

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

    # The scheduled Routine reads the same pool. Collection ran within its
    # interval, so the run makes no provider read and offers the pooled items.
    Application.put_env(:comma_web, :member_slack_test, Map.put(slack, :reads, self()))
    assert :ok = RecommendationRuntime.reconcile_profile(profile.id)
    profile = Comma.Repo.get!(Comma.Data.RecommendationProfile, profile.id)

    {:ok, %{run: run}} =
      Recommendations.begin_schedule_occurrence(profile.id, profile.schedule_id, 1_789_738_000)

    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    refute_received {:slack_read, _path}
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    {messages, [], %{"entrypoint" => "comma_recommendation"}} = List.last(DraftLLM.requests())

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
    state = Application.fetch_env!(:comma_web, :member_slack_test)

    Application.put_env(
      :comma_web,
      :member_slack_test,
      Map.merge(state, %{hold: self(), direct: [f.approval.("450")]})
    )

    collecting =
      Task.async(fn -> CommaWeb.MemberSourceIngest.ingest(f.workspace, f.user["id"]) end)

    assert_receive {:source_waiting, reader}, 10_000
    {:ok, _} = Recommendations.update_settings(f.user, %{}, f.workspace["id"], f.settings.(false))
    send(reader, :continue)
    assert {:ok, %{new: 0, changed: 0}} = Task.await(collecting, 30_000)
    assert Comma.Repo.aggregate(Comma.Data.MemberSourceItem, :count) == 0
    assert Comma.Repo.aggregate(Comma.Data.MemberSourceState, :count) == 0
    assert :ok = f.check.()
    assert DraftLLM.requests() == []
    assert f.router_inputs.() == []
  end

  test "changed source context reaches Routine and proactive judgment without a new prompt" do
    f = withdrawal_fixture!()
    request = f.approval.("460") |> Map.put("text", "<@U123> can you review the launch?")
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
    judging = Task.async(f.check)
    assert_receive {:model_waiting, judge}, 10_000
    :ok = Comma.MemberSourceConsents.forget_connection(f.workspace["id"], f.account)
    DraftLLM.mode(:normal)
    send(judge, :continue)
    assert :ok = Task.await(judging, 30_000)
    assert [_judgment] = DraftLLM.requests()
    assert f.router_inputs.() == []
  end

  test "Routine settings turn automatic messages off, and back on from that moment" do
    {user, workspace, profile, token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, Application.get_env(:salix_web, key)}

    for {key, _} <- previous, do: Application.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      Application.delete_env(:comma_web, :member_slack_test)
    end)

    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))
    account = source["connectionId"]
    slack = %{workspace: workspace, account: account}
    Application.put_env(:comma_web, :member_slack_test, slack)
    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "slack", account)
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
      Application.put_env(
        :comma_web,
        :member_slack_test,
        slack |> Map.put(:direct, messages) |> Map.put(:reads, self())
      )
    end

    # On by default. The first collection records existing work as history.
    assert {200, %{"enabled" => true}} = setting.(:get, %{})
    chain.()

    # Off: the chain stops without reading or scheduling another collection.
    assert {200, %{"enabled" => false}} =
             setting.(:put, %{"enabled" => false, "request_id" => "off-1"})

    urgent = direct.("300", "<@U123> can you approve the launch today?")
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
    arrive.([direct.("400", "<@U123> please approve the budget today"), urgent])
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
          do: {key, Application.get_env(:salix_web, key)}

    for {key, _} <- previous, do: Application.put_env(:salix_web, key, MemberGmail)
    gmail = %{workspace: workspace, account: account, webhook: true, owner: self()}
    Application.put_env(:comma_web, :member_gmail_test, gmail)

    # The tenant's Composio webhook. Its secret URL is the ingress credential.
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    SalixStore.ComposioSettings.put(tenant, %{
      "api_key" => "ck_test",
      "enabled" => true,
      "webhook_secret" => secret
    })

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      Application.delete_env(:comma_web, :member_gmail_test)
      SalixStore.ComposioSettings.delete(tenant)
    end)

    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "gmail", account)

    # The first collection records the inbox as history and creates the
    # source's trigger.
    job = %Oban.Job{args: %{"group_id" => group, "user_id" => user["id"]}}
    assert :ok = CommaWeb.MemberSourceIngest.perform(job)
    assert_received {:upsert_trigger, ^group, ^account, "GMAIL_NEW_GMAIL_MESSAGE", %{}}
    refute Comma.MemberSourceItems.pending?(profile.id)

    # Mail arrives. The event also carries mail data, which Comma never uses:
    # the pool stores what the official read returns.
    arrived = %{id: "contract", subject: "Please approve the contract today", body: "Due 5 PM."}
    Application.put_env(:comma_web, :member_gmail_test, Map.put(gmail, :arrived, [arrived]))

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
    assert DateTime.diff(at, DateTime.utc_now()) > 30
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

  test "Slack member runs require consent, exclude chatter, and hide results after disconnect" do
    {user, workspace, profile, _token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, Application.get_env(:salix_web, key)}

    for {key, _} <- previous, do: Application.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      Application.delete_env(:comma_web, :member_slack_test)
    end)

    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))
    account = source["connectionId"]
    Application.put_env(:comma_web, :member_slack_test, %{workspace: workspace, account: account})
    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, profile} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")

    assert {:error, _} =
             CommaWeb.RecommendationComposioMemberSource.read(
               workspace,
               user["id"],
               source,
               DateTime.utc_now()
             )

    {:ok, %{run: missing}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => missing["id"]}})

    assert {:ok, %{"lastError" => "member_identity_required"}} =
             Recommendations.get(user, %{}, workspace["id"])

    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "slack", account)

    assert {:ok, %{facts: [fact]}} =
             RecommendationSourceCollector.collect(workspace, [source],
               member_user_id: user["id"]
             )

    assert [%{"text" => "https://example.com/plan\n<@U123> review the plan"}] =
             fact["data"]["messages"]["matches"]

    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace["id"])
    assert :ok = RecommendationGenerate.perform(%Oban.Job{args: %{"run_id" => run["id"]}})
    assert {:ok, %{run: %{status: "published"}}} = Recommendations.run_context(run["id"])
    assert [{messages, [], _opts}] = DraftLLM.requests()
    assert [candidate] = Jason.decode!(List.last(messages).content)["candidates"]
    assert candidate["title"] == "review the plan"
    assert candidate["excerpt"] == "https://example.com/plan\n<@U123> review the plan"
    assert candidate["recipient"] == "U123"
    assert candidate["context"]["scope"] == "search_neighbors"
    assert candidate["context"]["text"] =~ "The revised plan is ready for review."
    :ok = Comma.MemberSourceConsents.forget_connection(workspace["id"], account)

    assert {:ok, %{"snapshot" => nil, "state" => "error"}} =
             Recommendations.get(user, %{}, workspace["id"])

    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "slack", account)

    Application.put_env(:comma_web, :member_slack_test, %{
      workspace: workspace,
      account: account,
      search_error: "missing_scope"
    })

    # Slack reports method errors with HTTP 200; the failure keeps the code.
    assert {:error, {:member_provider_error, "missing_scope"}} =
             CommaWeb.RecommendationComposioMemberSource.read(
               workspace,
               user["id"],
               source,
               DateTime.utc_now()
             )

    Application.put_env(:comma_web, :member_slack_test, %{
      workspace: workspace,
      account: account,
      auth: %{"bot_id" => "B123"}
    })

    assert {:error, _} =
             CommaWeb.RecommendationComposioMemberSource.read(
               workspace,
               user["id"],
               source,
               DateTime.utc_now()
             )

    assert profile.relevance_mode == "member"
  end

  test "Slack member reads add direct messages and threads that wait for the member" do
    {user, workspace, profile, _token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, Application.get_env(:salix_web, key)}

    for {key, _} <- previous, do: Application.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      Application.delete_env(:comma_web, :member_slack_test)
    end)

    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))
    account = source["connectionId"]

    message = fn channel, text, user, permalink ->
      %{"text" => text, "user" => user, "channel" => channel, "permalink" => permalink}
    end

    direct = %{"id" => "D1", "is_im" => true}

    Application.put_env(:comma_web, :member_slack_test, %{
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
          "U123",
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
    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "slack", account)

    assert {:ok, %{facts: [fact]}} =
             RecommendationSourceCollector.collect(workspace, [source],
               member_user_id: user["id"]
             )

    # The latest direct message per conversation, and only threads where
    # someone else spoke last. Group conversations need a mention.
    assert Enum.map(fact["data"]["messages"]["matches"], &{&1["text"], &1["memberRelation"]}) == [
             {"https://example.com/plan\n<@U123> review the plan", "mentioned_you"},
             {"Can you send the launch checklist today?", "direct_message_to_you"},
             {"Does Friday still work for the rollout?", "replied_in_your_thread"}
           ]

    # An unreadable relationship leaves the others readable and is reported.
    Application.put_env(
      :comma_web,
      :member_slack_test,
      Map.put(Application.fetch_env!(:comma_web, :member_slack_test), :direct_error, true)
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
    id = "notion-#{System.unique_integer([:positive])}"
    viewer = Ecto.UUID.generate()
    now = DateTime.utc_now()
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
    previous = Application.get_env(:comma_web, :recommendation_oauth_http_options)

    Application.put_env(:comma_web, :recommendation_oauth_http_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn -> restore_env(:comma_web, :recommendation_oauth_http_options, previous) end)
    id = "member-#{System.unique_integer([:positive])}"

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
    configure_local_llm_template!(protocol)

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "routine-job-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)
    assert {:ok, _} = Comma.Plugins.install(user, %{}, workspace["id"], "slack")
    assert {:ok, _} = RecommendationRuntime.ensure(user, %{}, workspace, "UTC", "en")
    # This fixture exercises the retained generic recipe; member tests opt in below.
    assert {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "generic")
    assert {:ok, profile} = Recommendations.get_runtime_profile(workspace["id"], user["id"])
    assert :ok = RecommendationRuntime.sync_sources(profile.id)
    assert {:ok, profile} = Recommendations.get_runtime_profile(workspace["id"], user["id"])
    previous = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, DraftLLM)
    start_supervised!({DraftLLM, self()})
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
    _local_template_id = configure_local_llm_template!()

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "local-recommendation-readd-#{System.unique_integer([:positive])}@comma.test"
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

    assert {:ok, sources} = CommaWeb.RecommendationSources.discover(workspace)
    assert [%{"connectionId" => ^new_id}] = Enum.filter(sources, &(&1["toolkit"] == "slack"))
  end

  test "runtime sync excludes an active unsupported Composio account before collection" do
    enable_local_recommendation_mock!()
    _local_template_id = configure_local_llm_template!()

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" =>
          "local-recommendation-unsupported-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user)
    assert {:ok, _plugin} = Comma.Plugins.install(user, %{}, workspace["id"], "slack")

    assert {:ok, %{"connected_account_id" => supported_account_id}} =
             SalixWeb.LocalComposioMock.create_connect_link(
               %{},
               "local-auth-config-slack",
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
    _local_template_id = configure_local_llm_template!()

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "local-recommendation-switch-#{System.unique_integer([:positive])}@comma.test"
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
        "email" => "local-recommendation-preview-#{System.unique_integer([:positive])}@comma.test"
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
             CommaWeb.RecommendationLinkPreview.preview(
               workspace,
               [source.("notion")],
               notion_page["url"],
               nil
             )

    assert {:ok, %{"kind" => "github_pull_request", "state" => "merged", "number" => 845}} =
             CommaWeb.RecommendationLinkPreview.preview(
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
             CommaWeb.RecommendationLinkPreview.preview(
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
             CommaWeb.RecommendationLinkPreview.preview(
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

    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    base_url = SalixWeb.Application.base_url()

    Application.put_env(:salix_web, :public_base_url, base_url)
    assert {:ok, %{enabled: true}} = SalixWeb.LocalOAuthMock.set_enabled(true)

    on_exit(fn ->
      _ = SalixWeb.LocalOAuthMock.set_enabled(false)
      Enum.each(previous, fn {{app, key}, value} -> restore_env(app, key, value) end)
    end)
  end

  defp configure_local_llm_template!(protocol \\ "chat_completions") do
    template_id = "local-recommendation-#{System.unique_integer([:positive])}"
    previous = Application.get_env(:comma_core, :default_agent_template)

    Application.put_env(:comma_core, :default_agent_template, %{
      "template_id" => template_id,
      "name" => "Local recommendation deterministic LLM",
      "model" => "gpt-local-dev",
      "provider_config" => %{
        "protocol" => protocol,
        "base_url" => "http://llm-mock:43123",
        "api_key" => "local-dev-only"
      }
    })

    on_exit(fn -> restore_env(:comma_core, :default_agent_template, previous) end)
    template_id
  end

  # The owner's Slack source in member mode, with consent and a recorded
  # baseline. Each collection only records the pool; the proactive consumer
  # runs when the test says.
  defp withdrawal_fixture! do
    {user, workspace, profile, _token} = generation_fixture!()

    previous =
      for key <- [:composio_client_mod, :composio_settings_mod],
          do: {key, Application.get_env(:salix_web, key)}

    for {key, _} <- previous, do: Application.put_env(:salix_web, key, MemberSlack)

    on_exit(fn ->
      for {key, value} <- previous, do: restore_env(:salix_web, key, value)
      Application.delete_env(:comma_web, :member_slack_test)
    end)

    source = Enum.find(profile.sources, &(&1["toolkit"] == "slack"))
    account = source["connectionId"]
    slack = %{workspace: workspace, account: account}
    Application.put_env(:comma_web, :member_slack_test, slack)
    {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [source])
    {:ok, _} = Recommendations.set_relevance_mode(user, %{}, workspace["id"], "member")
    {:ok, :ok} = Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "slack", account)
    group = workspace["default_group_id"]

    collect = fn direct ->
      Application.put_env(:comma_web, :member_slack_test, Map.put(slack, :direct, direct))
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
        "text" => "<@U123> can you approve the launch today?",
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
      settings: settings
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
