defmodule CommaWeb.RecommendationMemberSourceTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  alias CommaWeb.{RecommendationMemberIdentity, RecommendationOAuthSource}
  alias Salix.Control.OAuthBindings

  setup do
    Req.Test.set_req_test_to_shared()
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    http = SystemsRuntime.get_env(:comma_web, :recommendation_oauth_http_options)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    SystemsRuntime.put_env(:comma_web, :recommendation_oauth_http_options,
      plug: {Req.Test, __MODULE__}
    )

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      for {app, key, value} <- [
            {:salix_store, :s3_backend, previous},
            {:comma_web, :recommendation_oauth_http_options, http}
          ] do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    workspace = %{
      "id" => "workspace",
      "owner_user_id" => "user",
      "salix_tenant_id" => "tenant",
      "default_group_id" => "group"
    }

    connection = %{
      "connection_id" => "conn-1",
      "tenant" => "tenant",
      "provider" => "linear",
      "status" => "active",
      "access_token" => "member-token",
      "scopes" => ["read"],
      "comma_member" => %{"user_id" => "user", "workspace_id" => "workspace"},
      "metadata" => %{
        "metadata" => %{
          "actor" => "user",
          "viewer_id" => "viewer",
          "workspace_id" => "organization"
        }
      }
    }

    :ok = SalixStore.OAuth.put("conn-1", connection)
    {:ok, binding, nil} = OAuthBindings.put("tenant", "group", "linear", "linear", "conn-1")

    source = %{
      "appId" => "linear",
      "kind" => "managed_oauth",
      "connectionId" => binding["binding_id"]
    }

    %{workspace: workspace, source: source, connection: connection}
  end

  test "Outlook collected resource ids follow only exact admitted URLs" do
    mail_url = "https://outlook.office.com/mail/id/AAMk1"
    event_url = "https://outlook.office.com/calendar/item/AAEv1"

    fact = %{
      "toolkit" => "outlook",
      "data" => %{
        "messages" => [%{"webUrl" => mail_url, "messageId" => "AAMk1"}],
        "items" => [%{"webUrl" => event_url, "id" => "AAEv1"}]
      }
    }

    assert CommaWeb.MemberSourceIngest.provider_ids(fact, mail_url) == %{"messageId" => "AAMk1"}
    assert CommaWeb.MemberSourceIngest.provider_ids(fact, event_url) == %{"eventId" => "AAEv1"}
    assert CommaWeb.MemberSourceIngest.provider_ids(fact, event_url <> "?other=true") == %{}
    assert CommaWeb.MemberSourceIngest.provider_ids(fact, mail_url <> "?other=true") == %{}
  end

  test "Slack reads member relationships with the managed user token and rejects a different workspace",
       ctx do
    source = slack_source(ctx)

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer member-token"]

      case conn.request_path do
        "/api/auth.test" ->
          Req.Test.json(conn, %{"ok" => true, "user_id" => "UMEMBER", "team_id" => "TWORKSPACE"})

        "/api/search.messages" ->
          assert conn.query_params["count"] in ["40", "100"]
          assert conn.query_params["page"] == "1"

          Req.Test.json(conn, %{
            "ok" => true,
            "messages" => %{
              "matches" => [
                %{
                  "text" => "<@UMEMBER> please review",
                  "user" => "UOTHER",
                  "ts" => "1.000001",
                  "permalink" => "https://workspace.slack.com/archives/C1/p1000001"
                }
              ]
            }
          })
      end
    end)

    assert {:ok, %{"messages" => %{"matches" => [item]}}, identity} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)

    assert item["memberRelation"] == "mentioned_you"
    assert identity["provider_workspace_id"] == "TWORKSPACE"

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/auth.test" ->
          Req.Test.json(conn, %{"ok" => true, "user_id" => "UMEMBER", "team_id" => "TOTHER"})

        "/api/search.messages" ->
          flunk("identity mismatch must stop before message reads")
      end
    end)

    assert {:error, :member_source_identity_mismatch} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)
  end

  test "Slack own messages carry the thread each answered, read with the managed user token",
       ctx do
    source = slack_source(ctx)

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer member-token"]

      case conn.request_path do
        "/api/auth.test" ->
          Req.Test.json(conn, %{
            "ok" => true,
            "user_id" => "UMEMBER",
            "team_id" => "TWORKSPACE",
            "user" => "member"
          })

        "/api/search.messages" ->
          assert conn.query_params["query"] =~ ~r/^from:<@UMEMBER> after:/

          Req.Test.json(conn, %{
            "ok" => true,
            "messages" => %{
              "matches" => [
                %{
                  "text" => "Renewed the token",
                  "user" => "UMEMBER",
                  "ts" => "2.000001",
                  "channel" => %{"id" => "C1", "name" => "alerts"},
                  "permalink" =>
                    "https://workspace.slack.com/archives/C1/p2000001?thread_ts=1.000001&cid=C1"
                },
                %{
                  "text" => "Not mine",
                  "user" => "UOTHER",
                  "ts" => "3.000001",
                  "permalink" => "https://workspace.slack.com/archives/C1/p3000001"
                }
              ]
            }
          })

        "/api/conversations.replies" ->
          assert conn.query_params == %{"channel" => "C1", "ts" => "1.000001", "limit" => "1"}

          Req.Test.json(conn, %{
            "ok" => true,
            "messages" => [%{"ts" => "1.000001", "text" => "Patrol failed: 401 token"}]
          })
      end
    end)

    assert {:ok, [own], %{"handle" => "member", "provider_user_id" => "UMEMBER"}} =
             RecommendationOAuthSource.own_slack_messages(ctx.workspace, "user", source)

    assert own["text"] == "Renewed the token"
    assert own["thread"] == "Patrol failed: 401 token"
    assert own["channel"] == "alerts"
  end

  test "a handoff reads its matter's GitHub run with the member's managed grant", ctx do
    source = Map.put(github_source(ctx), "enabled", true)

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer member-token"]
      assert conn.request_path == "/repos/acme/board/actions/runs/7"

      Req.Test.json(conn, %{
        "html_url" => "https://github.com/acme/board/actions/runs/7",
        "status" => "completed",
        "conclusion" => "success",
        "run_attempt" => 2
      })
    end)

    matter = %{
      "url" => "https://acme.slack.com/archives/C1/p100",
      "excerpt" => "Run: <https://github.com/acme/board/actions/runs/7>"
    }

    assert [%{"kind" => "github_actions_run", "conclusion" => "success", "attempt" => 2}] =
             CommaWeb.ProactiveEvidence.linked(ctx.workspace, "user", [source], matter)
  end

  test "Slack generic reads bound responses and report provider errors", ctx do
    source = slack_source(ctx)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/search.messages"
      assert conn.query_params["count"] == "12"
      Req.Test.json(conn, %{"ok" => false, "error" => "missing_scope"})
    end)

    assert {:error, {:member_provider_error, "missing_scope"}} =
             RecommendationOAuthSource.read(ctx.workspace, source)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"ok" => true, "padding" => String.duplicate("x", 512_001)})
    end)

    assert {:error, :response_too_large} = RecommendationOAuthSource.read(ctx.workspace, source)
  end

  test "a grant only the member can repair is a reconnect failure, not a read failure", ctx do
    source = Map.merge(slack_source(ctx), %{"enabled" => true, "appName" => "Slack"})

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"ok" => false, "error" => "missing_scope"})
    end)

    assert {:ok, %{facts: [], failures: [%{"class" => "reconnect", "appId" => "slack"}]}} =
             CommaWeb.RecommendationSourceCollector.collect(ctx.workspace, [source])

    # A provider outage clears on its own; the member has nothing to reconnect.
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"ok" => false, "error" => "ratelimited"})
    end)

    assert {:ok, %{failures: [%{"class" => "read"}]}} =
             CommaWeb.RecommendationSourceCollector.collect(ctx.workspace, [source])
  end

  test "queries the authenticated member and excludes unrelated or completed work", ctx do
    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      query = Jason.decode!(body)["query"]
      assert query =~ "assignedIssues(first: 40"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer member-token"]

      Req.Test.json(
        conn,
        response([
          Map.put(
            issue("mine", "viewer", "started"),
            "description",
            "Awaiting your review of the checkout flow."
          ),
          issue("other", "other", "started"),
          issue("done", "viewer", "completed")
        ])
      )
    end)

    assert {:ok, %{"issues" => %{"nodes" => [%{"id" => "mine"} = item]}}, identity} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", ctx.source)

    assert identity["connection_id"] == "conn-1"
    assert item["context"]["text"] =~ "Awaiting your review of the checkout flow."
  end

  for provider <- ~w(linear github) do
    @provider provider
    test "#{provider} body constraints survive collection, model input and hover context", ctx do
      provider = @provider
      source = if provider == "github", do: github_source(ctx), else: ctx.source
      source = Map.merge(source, %{"enabled" => true, "appName" => provider})
      constraint = "Only measure latency; do not change production."
      body = constraint <> "\n\n" <> String.duplicate("More background. ", 150)
      now = SystemsClock.utc_now()

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/graphql" ->
            {:ok, request, conn} = Plug.Conn.read_body(conn)
            fields = Jason.decode!(request)["query"]
            record = issue("mine", "viewer", "started")
            # Return the field only if it was requested, as the provider does.
            record =
              if fields =~ "description", do: Map.put(record, "description", body), else: record

            # GitHub's GraphQL read is the member's own pull requests.
            if fields =~ "CommaMemberPullRequests",
              do: Req.Test.json(conn, %{"data" => %{"search" => %{"nodes" => []}}}),
              else: Req.Test.json(conn, response([record]))

          "/user" ->
            Req.Test.json(conn, %{"id" => 42, "login" => "member"})

          "/issues" ->
            record =
              github_issue(1, 42)
              |> Map.merge(%{"body" => body, "updated_at" => DateTime.to_iso8601(now)})

            Req.Test.json(conn, [record])

          "/search/issues" ->
            Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})

          "/notifications" ->
            Req.Test.json(conn, [])
        end
      end)

      assert {:ok, %{facts: [fact], failures: []}} =
               CommaWeb.RecommendationSourceCollector.collect(ctx.workspace, [source],
                 member_user_id: "user"
               )

      records =
        if provider == "github", do: fact["data"]["issues"], else: fact["data"]["issues"]["nodes"]

      assert [record] = records
      url = record["html_url"] || record["url"]
      assert fact["contexts"][url]["text"] =~ constraint
      assert byte_size(fact["contexts"][url]["text"]) <= 1_200
      refute Map.has_key?(record, "body")
      refute Map.has_key?(record, "description")
      url = record["html_url"] || record["url"]

      context =
        Comma.RecommendationDraft.prepare([fact], %{source["connectionId"] => [url]}, "member")

      assert [candidate] = Comma.RecommendationMemberSelection.model_candidates(context)
      assert candidate["context"]["text"] =~ constraint

      assert {:ok, snapshot} =
               Comma.RecommendationDraft.compile(
                 %{
                   "selected" => [
                     %{
                       "id" => candidate["id"],
                       "recommendation" => "Measure latency without changing production"
                     }
                   ]
                 },
                 context,
                 %{relevance_mode: "member", generation: 1, source_revision: 1},
                 [],
                 locale: "en"
               )

      prompt = snapshot["prompts"][candidate["id"]]
      assert prompt["context"] =~ constraint
      assert String.length(prompt["context"]) <= 601

      assert get_in(snapshot, ["cards", Access.at(0), "items", Access.at(0), "action", "promptId"]) ==
               candidate["id"]
    end
  end

  test "keeps a successful empty result distinct from query failure", ctx do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, response([])) end)

    assert {:ok, %{"issues" => %{"nodes" => []}}, _} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", ctx.source)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"message" => "unavailable"}]})
    end)

    assert {:error, :oauth_provider_query_failed} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", ctx.source)
  end

  test "rejects a changed provider subject and replacement during the read", ctx do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, put_in(response([]), ["data", "viewer", "id"], "someone-else"))
    end)

    assert {:error, :member_source_identity_mismatch} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", ctx.source)

    Req.Test.expect(__MODULE__, fn conn ->
      :ok = SalixStore.OAuth.put("conn-2", Map.put(ctx.connection, "connection_id", "conn-2"))
      {:ok, _, _} = OAuthBindings.put("tenant", "group", "linear", "linear", "conn-2")
      Req.Test.json(conn, response([]))
    end)

    assert {:error, :member_source_changed} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", ctx.source)
  end

  test "credential resolution cannot follow a repointed binding", ctx do
    {:ok, identity} = RecommendationMemberIdentity.resolve(ctx.workspace, "user", ctx.source)
    :ok = SalixStore.OAuth.put("conn-2", Map.put(ctx.connection, "connection_id", "conn-2"))
    {:ok, _, _} = OAuthBindings.put("tenant", "group", "linear", "linear", "conn-2")

    assert {:error, {:missing_oauth, "OAuth binding connection changed"}} =
             Salix.Bindings.MCPCredentials.resolve(%{
               "tenant_id" => "tenant",
               "group_id" => "group",
               "oauth_binding_refs" => %{
                 "TOKEN" => %{
                   "binding_id" => identity["binding_id"],
                   "expected_connection_id" => identity["connection_id"],
                   "provider" => "linear"
                 }
               }
             })
  end

  test "member collection keeps its subject outside model data and never falls back", ctx do
    source = Map.merge(ctx.source, %{"enabled" => true, "appName" => "Linear"})

    unrelated = %{
      "enabled" => true,
      "appId" => "notion",
      "appName" => "Notion",
      "kind" => "managed_oauth",
      "connectionId" => "notion-binding"
    }

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, response([issue("mine", "viewer", "started")]))
    end)

    assert {:ok, %{facts: [fact], failures: [failure]}} =
             CommaWeb.RecommendationSourceCollector.collect(ctx.workspace, [source, unrelated],
               member_user_id: "user"
             )

    assert fact["memberSubject"]["provider_user_id"] == "viewer"
    assert fact["data"]["issues"]["nodes"] |> Enum.map(& &1["id"]) == ["mine"]
    assert failure["sourceId"] == "notion-binding"
    context = Comma.RecommendationDraft.prepare([fact], %{})
    refute Map.has_key?(hd(context.input), "memberSubject")
  end

  test "GitHub adds the last day's failed runs of the repositories the portrait names", ctx do
    source = Map.put(github_source(ctx), "memberTargets", %{"repos" => ["acme/board"]})

    Req.Test.stub(__MODULE__, fn conn ->
      params = Plug.Conn.fetch_query_params(conn).query_params

      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, %{"id" => 42, "login" => "member"})

        "/repos/acme/board/actions/runs" ->
          assert params["status"] == "failure"
          assert "created" in Map.keys(params)

          Req.Test.json(conn, %{
            "workflow_runs" => [
              %{
                "id" => 7,
                "name" => "Production macOS Patrol",
                "head_branch" => "main",
                "run_attempt" => 1,
                "conclusion" => "failure",
                "html_url" => "https://github.com/acme/board/actions/runs/7",
                "updated_at" => DateTime.to_iso8601(SystemsClock.utc_now())
              }
            ]
          })

        "/search/issues" ->
          Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})

        "/graphql" ->
          Req.Test.json(conn, %{"data" => %{"search" => %{"nodes" => []}}})

        _ ->
          Req.Test.json(conn, [])
      end
    end)

    assert {:ok, %{"issues" => [run]}, _identity} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)

    assert %{
             "html_url" => "https://github.com/acme/board/actions/runs/7",
             "title" => "Production macOS Patrol failed on main (attempt 1)",
             "memberRelation" => "failed_in_your_repo"
           } = run
  end

  test "GitHub uses live numeric identity and only assigned open work", ctx do
    source = github_source(ctx)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/user"
      Req.Test.json(conn, %{"id" => 42, "login" => "renamed-user"})
    end)

    # All member reads run concurrently, in any order.
    test = SystemsRuntime.Proc.self()

    Req.Test.expect(__MODULE__, 5, fn conn ->
      params = Plug.Conn.fetch_query_params(conn).query_params

      case {conn.request_path, params["q"]} do
        {"/issues", _query} ->
          assert params["filter"] == "assigned"
          # Assigned work nobody touched for a month stays out of the Routine.
          assert {:ok, since, 0} = DateTime.from_iso8601(params["since"])
          assert_in_delta DateTime.diff(SystemsClock.utc_now(), since, :day), 30, 1
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer member-token"]
          SystemsRuntime.Proc.send(test, {:github_read, :assigned})

          Req.Test.json(conn, [
            github_issue(1, 42),
            github_issue(2, 99),
            Map.put(github_issue(3, 42), "state", "closed"),
            github_issue(1, 42)
          ])

        {"/search/issues", "is:pr is:open review-requested:renamed-user updated:>=" <> date} ->
          # A review request untouched for a month stays out of the Routine.
          assert Date.diff(Date.utc_today(), Date.from_iso8601!(date)) in 29..31
          SystemsRuntime.Proc.send(test, {:github_read, :reviews})

          Req.Test.json(conn, %{
            "items" => [Map.put(github_issue(4, 99), "pull_request", %{})],
            "incomplete_results" => false
          })

        {"/search/issues", "mentions:renamed-user is:open updated:>=" <> date} ->
          assert date =~ ~r/^\d{4}-\d{2}-\d{2}$/
          SystemsRuntime.Proc.send(test, {:github_read, :mentions})
          Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})

        {"/graphql", _query} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert "is:pr is:open author:renamed-user updated:>=" <> date =
                   Jason.decode!(body)["variables"]["query"]

          assert Date.diff(Date.utc_today(), Date.from_iso8601!(date)) in 29..31
          SystemsRuntime.Proc.send(test, {:github_read, :authored})
          Req.Test.json(conn, %{"data" => %{"search" => %{"nodes" => []}}})

        {"/notifications", _query} ->
          assert params["all"] == "true"
          assert {:ok, since, 0} = DateTime.from_iso8601(params["since"])
          assert_in_delta DateTime.diff(SystemsClock.utc_now(), since, :day), 7, 1
          SystemsRuntime.Proc.send(test, {:github_read, :notifications})
          Req.Test.json(conn, [])
      end
    end)

    assert {:ok,
            %{
              "issues" => [
                %{"id" => 4, "memberRelation" => "review_requested_from_you"},
                %{"id" => 1}
              ]
            }, identity} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)

    assert identity["provider_user_id"] == "42"

    for read <- [:assigned, :reviews, :mentions, :authored, :notifications],
        do: assert_received({:github_read, ^read})
  end

  test "GitHub adds open work that mentions the member with the mentioning comment", ctx do
    source = github_source(ctx)
    now = SystemsClock.utc_now() |> DateTime.to_iso8601()

    mentioned =
      github_issue(7, 99)
      |> Map.merge(%{
        "body" => "Background from last month.",
        "updated_at" => now,
        "comments_url" => "https://api.github.com/repos/example/project/issues/7/comments"
      })

    Req.Test.stub(__MODULE__, fn conn ->
      params = Plug.Conn.fetch_query_params(conn).query_params

      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, %{"id" => 42, "login" => "member"})

        "/issues" ->
          Req.Test.json(conn, [Map.put(github_issue(1, 42), "updated_at", now)])

        "/search/issues" ->
          items = if params["q"] =~ "mentions:member", do: [mentioned], else: []
          Req.Test.json(conn, %{"items" => items, "incomplete_results" => false})

        "/graphql" ->
          Req.Test.json(conn, %{"data" => %{"search" => %{"nodes" => []}}})

        "/notifications" ->
          Req.Test.json(conn, [])

        "/repos/example/project/issues/7/comments" ->
          assert params["since"]

          Req.Test.json(conn, [
            %{
              "id" => 70,
              "body" => "@member2 please look",
              "html_url" => "https://github.com/example/project/issues/7#issuecomment-70"
            },
            %{
              "id" => 71,
              "body" => "@member can you confirm the fix on staging?",
              "html_url" => "https://github.com/example/project/issues/7#issuecomment-71"
            }
          ])
      end
    end)

    assert {:ok, %{"issues" => [mention, assigned]}, _} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)

    assert mention["memberRelation"] == "mentioned_you"
    assert mention["html_url"] == "https://github.com/example/project/issues/7#issuecomment-71"
    assert mention["context"]["text"] =~ "can you confirm the fix on staging?"
    assert assigned["memberRelation"] == "assigned_to_you"
  end

  test "GitHub adds the member's open pull requests with their checks and review, and their inbox",
       ctx do
    source = github_source(ctx)
    test = SystemsRuntime.Proc.self()
    now = SystemsClock.utc_now() |> DateTime.to_iso8601()

    repository = %{
      "full_name" => "example/project",
      "html_url" => "https://github.com/example/project"
    }

    notification = fn id, reason, type, url, title ->
      %{
        "id" => id,
        "reason" => reason,
        "updated_at" => now,
        "subject" => %{"type" => type, "url" => url, "title" => title},
        "repository" => repository
      }
    end

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, %{"id" => 42, "login" => "member"})

        "/issues" ->
          Req.Test.json(conn, [])

        "/search/issues" ->
          Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})

        "/graphql" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          request = Jason.decode!(body)

          if request["query"] =~ "issueOrPullRequest" do
            SystemsRuntime.Proc.send(test, {:subjects, request["variables"]})

            index = fn number ->
              Enum.find(request["variables"], &match?({"k" <> _, ^number}, &1))
            end

            {"k" <> merged, _} = index.(6)
            {"k" <> hidden, _} = index.(8)

            # GitHub answers each lookup alone: an unreadable subject is null.
            Req.Test.json(conn, %{
              "data" => %{
                ("s" <> merged) => %{
                  "issueOrPullRequest" => %{
                    "state" => "MERGED",
                    "comments" => %{
                      "nodes" => [
                        %{"author" => %{"login" => "member"}, "body" => "Thanks, merged."}
                      ]
                    }
                  }
                },
                ("s" <> hidden) => nil
              },
              "errors" => [%{"type" => "NOT_FOUND"}]
            })
          else
            Req.Test.json(conn, %{
              "data" => %{
                "search" => %{
                  "nodes" => [
                    %{
                      "databaseId" => 501,
                      "number" => 5,
                      "title" => "Fix the importer",
                      "url" => "https://github.com/example/project/pull/5",
                      "state" => "OPEN",
                      "isDraft" => false,
                      "updatedAt" => now,
                      "reviewDecision" => "CHANGES_REQUESTED",
                      "commits" => %{
                        "nodes" => [
                          %{"commit" => %{"statusCheckRollup" => %{"state" => "FAILURE"}}}
                        ]
                      }
                    },
                    # The search can return items that are not pull requests.
                    %{}
                  ]
                }
              }
            })
          end

        "/notifications" ->
          Req.Test.json(conn, [
            notification.(
              "1",
              "author",
              "PullRequest",
              "https://api.github.com/repos/example/project/pulls/5",
              "Fix the importer"
            ),
            notification.(
              "6",
              "author",
              "PullRequest",
              "https://api.github.com/repos/example/project/pulls/6",
              "Merged importer fix"
            ),
            notification.(
              "2",
              "ci_activity",
              "CheckSuite",
              nil,
              "CI workflow run failed for main branch"
            ),
            notification.(
              "3",
              "comment",
              "Issue",
              "https://api.github.com/repos/example/project/issues/8",
              "Importer drops rows"
            ),
            notification.(
              "4",
              "subscribed",
              "Issue",
              "https://api.github.com/repos/example/project/issues/9",
              "Watched repository activity"
            ),
            notification.(
              "5",
              "mention",
              "Issue",
              "https://api.github.com/repos/example/project/issues/10",
              "Read by the mention search"
            )
          ])
      end
    end)

    assert {:ok, %{"issues" => [authored, merged, ci, comment]} = data, _} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)

    # One request reads the issues and pull requests that the inbox names.
    assert_received {:subjects, variables}
    refute_received {:subjects, _}

    assert variables
           |> Map.filter(fn {key, _} -> key =~ ~r/^k/ end)
           |> Map.values()
           |> Enum.sort() ==
             [5, 6, 8]

    refute Map.has_key?(data, :source_warnings)

    assert authored["memberRelation"] == "authored_by_you"
    assert authored["html_url"] == "https://github.com/example/project/pull/5"
    assert authored["context"]["text"] =~ "checks: FAILURE"
    assert authored["context"]["text"] =~ "review: CHANGES_REQUESTED"

    # The member's merged pull request says that it is resolved.
    assert merged["memberRelation"] == "notified_you"
    assert merged["context"]["text"] =~ "reason: author"
    assert merged["context"]["text"] =~ "state: merged"
    assert merged["context"]["text"] =~ "latest_comment: you: Thanks, merged."

    assert ci["memberRelation"] == "notified_you"
    assert ci["html_url"] == "https://github.com/example/project/actions"
    assert ci["context"]["text"] =~ "reason: ci_activity"

    assert comment["html_url"] == "https://github.com/example/project/issues/8"
    assert comment["context"]["text"] =~ "reason: comment"
    refute comment["context"]["text"] =~ "state:"

    # The proactive pool reads the same candidates.
    source = Map.merge(source, %{"enabled" => true, "appName" => "GitHub"})

    assert {:ok, %{facts: facts, failures: []}} =
             CommaWeb.RecommendationSourceCollector.collect(ctx.workspace, [source],
               member_user_id: "user"
             )

    context =
      Comma.RecommendationDraft.prepare(
        facts,
        Comma.Recommendations.source_evidence(facts),
        "member"
      )

    assert context
           |> Comma.RecommendationMemberSelection.candidates()
           |> Enum.map(&{&1["url"], &1["relationship"]}) == [
             {"https://github.com/example/project/pull/5", "authored_by_you"},
             {"https://github.com/example/project/pull/6", "notified_you"},
             {"https://github.com/example/project/actions", "notified_you"},
             {"https://github.com/example/project/issues/8", "notified_you"}
           ]
  end

  test "Linear adds recent open inbox mentions before assigned issues", ctx do
    now = SystemsClock.utc_now()
    at = fn days -> now |> DateTime.add(-days * 86_400) |> DateTime.to_iso8601() end

    notification = fn type, created, extra ->
      Map.merge(
        %{
          "type" => type,
          "createdAt" => created,
          "archivedAt" => nil,
          "issue" => %{
            "id" => "i-9",
            "identifier" => "ENG-9",
            "title" => "Checkout errors",
            "url" => "https://linear.app/team/issue/ENG-9",
            "state" => %{"type" => "started"}
          },
          "comment" => %{
            "id" => "c-9",
            "body" => "@member can you confirm the rollback?",
            "url" => "https://linear.app/team/issue/ENG-9#comment-c9"
          }
        },
        extra
      )
    end

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["query"] =~ "notifications(first: 50)"

      Req.Test.json(
        conn,
        response([issue("mine", "viewer", "started")], [
          notification.("issueCommentMention", at.(1), %{}),
          notification.("issueCommentMention", at.(1), %{"archivedAt" => at.(0)}),
          notification.("issueCommentMention", at.(9), %{}),
          notification.("issueNewComment", at.(1), %{})
        ])
      )
    end)

    assert {:ok, %{"issues" => %{"nodes" => [mention, assigned]}}, _} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", ctx.source)

    assert mention["memberRelation"] == "mentioned_you"
    assert mention["url"] == "https://linear.app/team/issue/ENG-9#comment-c9"
    assert mention["context"]["text"] =~ "can you confirm the rollback?"
    assert assigned["id"] == "mine"
  end

  test "private GitHub PR preview reads real details without a Routine profile only for its bound owner",
       ctx do
    source = github_source(ctx)
    href = "https://github.com/AFK-surf/Cue/pull/2490?token=never-forward"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/user"
      Req.Test.json(conn, %{"id" => 42, "login" => "member"})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/AFK-surf/Cue/pulls/2490"
      assert conn.query_string == ""

      Req.Test.json(conn, %{
        "number" => 2490,
        "title" => "Real private title",
        "state" => "open",
        "draft" => true,
        "user" => %{"login" => "author", "avatar_url" => nil},
        "base" => %{"repo" => %{"full_name" => "AFK-surf/Cue"}}
      })
    end)

    assert {:ok,
            %{
              "title" => "Real private title",
              "state" => "draft",
              "author" => %{"login" => "author"}
            }} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               source["connectionId"],
               "user"
             )

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               source["connectionId"],
               "other-member"
             )

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               Map.put(ctx.workspace, "id", "other-workspace"),
               href,
               source["connectionId"],
               "user"
             )

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               "another-source",
               "user"
             )
  end

  test "private PR preview withholds result when a connection is revoked during read", ctx do
    source = github_source(ctx) |> Map.put("enabled", true)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/user"
      Req.Test.json(conn, %{"id" => 42, "login" => "member"})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      key = SalixStore.Keys.ctl_oauth_group_binding("group", source["connectionId"])
      {:ok, _} = Salix.Control.Store.update_record(key, &Map.put(&1, "enabled", false))

      Req.Test.json(conn, %{
        "number" => 2490,
        "title" => "Secret",
        "state" => "open",
        "base" => %{"repo" => %{"full_name" => "AFK-surf/Cue"}}
      })
    end)

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview(
               ctx.workspace,
               [source],
               "https://github.com/AFK-surf/Cue/pull/2490",
               source["connectionId"],
               "user"
             )

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview(
               ctx.workspace,
               [source],
               "https://github.com/AFK-surf/Cue/pull/2490",
               source["connectionId"],
               "user"
             )
  end

  test "private PR preview rejects mismatched payload without inventing a title", ctx do
    source = github_source(ctx) |> Map.put("enabled", true)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"id" => 42, "login" => "member"})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "number" => 2490,
        "title" => "Other repo title",
        "state" => "open",
        "base" => %{"repo" => %{"full_name" => "other/repo"}}
      })
    end)

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview(
               ctx.workspace,
               [source],
               "https://github.com/AFK-surf/Cue/pull/2490",
               source["connectionId"],
               "user"
             )
  end

  test "GitHub rejects wrong token owner before reading work and rebind during read", ctx do
    source = github_source(ctx)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"id" => 99, "login" => "other"})
    end)

    assert {:error, :member_source_identity_mismatch} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"id" => 42, "login" => "member"})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, connection} = SalixStore.OAuth.get("github-1")
      :ok = SalixStore.OAuth.put("github-2", Map.put(connection, "connection_id", "github-2"))
      {:ok, _, _} = OAuthBindings.put("tenant", "group", "github", "github", "github-2")
      Req.Test.json(conn, [github_issue(1, 42)])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})
    end)

    Req.Test.expect(__MODULE__, 3, fn conn ->
      Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})
    end)

    assert {:error, :member_source_changed} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)
  end

  test "GitHub empty work is distinct from denied provider access", ctx do
    source = github_source(ctx)

    github = fn work ->
      Req.Test.stub(__MODULE__, fn conn ->
        if conn.request_path == "/user",
          do: Req.Test.json(conn, %{"id" => 42, "login" => "member"}),
          else: work.(conn)
      end)
    end

    github.(fn conn ->
      case conn.request_path do
        path when path in ["/issues", "/notifications"] ->
          Req.Test.json(conn, [])

        "/graphql" ->
          Req.Test.json(conn, %{"data" => %{"search" => %{"nodes" => []}}})

        "/search/issues" ->
          Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})
      end
    end)

    assert {:ok, %{"issues" => []} = empty, _} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)

    refute Map.has_key?(empty, :source_warnings)

    github.(&Plug.Conn.send_resp(&1, 403, "denied"))

    assert {:error, {:oauth_provider_http, 403}} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)
  end

  test "GitHub keeps readable work when one query fails, search is incomplete or comments are unreadable",
       ctx do
    source = github_source(ctx)
    now = SystemsClock.utc_now() |> DateTime.to_iso8601()
    review = github_issue(3, 99) |> Map.merge(%{"pull_request" => %{}, "updated_at" => now})

    mentioned =
      github_issue(7, 99)
      |> Map.merge(%{
        "body" => "Can @member check the rollout?",
        "updated_at" => now,
        "comments_url" => "https://api.github.com/repos/example/project/issues/7/comments"
      })

    Req.Test.stub(__MODULE__, fn conn ->
      params = Plug.Conn.fetch_query_params(conn).query_params

      case conn.request_path do
        "/user" ->
          Req.Test.json(conn, %{"id" => 42, "login" => "member"})

        "/issues" ->
          Plug.Conn.send_resp(conn, 502, "")

        "/graphql" ->
          Req.Test.json(conn, %{"data" => %{"search" => %{"nodes" => []}}})

        "/notifications" ->
          Req.Test.json(conn, [])

        "/search/issues" ->
          if params["q"] =~ "review-requested",
            do: Req.Test.json(conn, %{"items" => [review], "incomplete_results" => true}),
            else: Req.Test.json(conn, %{"items" => [mentioned], "incomplete_results" => false})

        "/repos/example/project/issues/7/comments" ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    assert {:ok, %{"issues" => [pr, mention]} = data, _} =
             RecommendationOAuthSource.read_member(ctx.workspace, "user", source)

    assert pr["memberRelation"] == "review_requested_from_you"
    # The mention keeps the issue text when its comments cannot be read.
    assert mention["memberRelation"] == "mentioned_you"
    assert mention["context"]["text"] =~ "Can @member check the rollout?"
    assert data.source_warnings == [{:oauth_provider_http, 502}]
  end

  test "Notion keeps the task databases it can read when one is throttled" do
    now = SystemsClock.utc_now()
    recent = now |> DateTime.add(-3600) |> DateTime.to_iso8601()

    database = fn id ->
      %{
        "id" => id,
        "properties" => %{
          "Owner" => %{"type" => "people", "id" => "owner"},
          "Status" => %{
            "type" => "status",
            "id" => "status",
            "status" => %{
              "options" => [
                %{"id" => "open", "name" => "In progress"},
                %{"id" => "done", "name" => "Done"}
              ],
              "groups" => [%{"option_ids" => ["open"]}, %{"option_ids" => ["done"]}]
            }
          }
        }
      }
    end

    task = %{
      "id" => "task",
      "url" => "https://www.notion.so/task",
      "last_edited_time" => recent,
      "parent" => %{"data_source_id" => "tasks"},
      "properties" => %{
        "Owner" => %{"id" => "owner", "type" => "people", "people" => [%{"id" => "member"}]},
        "Status" => %{
          "id" => "status",
          "type" => "status",
          "status" => %{"name" => "In progress"}
        },
        "Name" => %{"type" => "title", "title" => [%{"plain_text" => "Ship the guide"}]}
      }
    }

    request = fn
      "notion_self", :get, _url, _options ->
        {:ok, %{"bot" => %{"owner" => %{"type" => "user", "user" => %{"id" => "member"}}}}}

      "notion", :post, "https://api.notion.com/v1/search", options ->
        case get_in(options, [:json, "filter", "value"]) do
          "data_source" -> {:ok, %{"values" => [database.("busy"), database.("tasks")]}}
          "page" -> {:ok, %{"values" => []}}
        end

      "notion", :post, "https://api.notion.com/v1/data_sources/busy/query", _options ->
        {:error, {:oauth_provider_http, 429}}

      "notion", :post, "https://api.notion.com/v1/data_sources/tasks/query", _options ->
        {:ok, %{"values" => [task]}}
    end

    assert {:ok, %{"values" => [%{"id" => "task", "memberRelation" => "involves_you"}]} = data} =
             CommaWeb.RecommendationNotionMemberSource.read(
               %{"provider_user_id" => "member"},
               request,
               now
             )

    assert data.source_warnings == [{:oauth_provider_http, 429}]
  end

  test "truncated old GitHub items remain excluded", ctx do
    source = github_source(ctx) |> Map.put("enabled", true)

    result =
      Enum.find_value(210..212, fn size ->
        Req.Test.stub(__MODULE__, fn conn ->
          case conn.request_path do
            "/user" ->
              Req.Test.json(conn, %{"id" => 42, "login" => "member"})

            "/issues" ->
              Req.Test.json(
                conn,
                Enum.map(1..40, fn id ->
                  github_issue(id, 42)
                  |> Map.put("title", String.duplicate("a", size))
                  |> Map.put("updated_at", "2026-03-01T00:00:00Z")
                end)
              )

            "/search/issues" ->
              Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})

            "/graphql" ->
              Req.Test.json(conn, %{"data" => %{"search" => %{"nodes" => []}}})

            "/notifications" ->
              Req.Test.json(conn, [])
          end
        end)

        {:ok, %{facts: [fact]}} =
          CommaWeb.RecommendationSourceCollector.collect(ctx.workspace, [source],
            member_user_id: "user",
            now: ~U[2026-09-19 00:00:00Z]
          )

        data = fact["data"]
        records = get_in(data, ["value", "issues"]) || data["issues"]

        refs =
          Map.new(records, fn r ->
            {to_string(r["id"]), %{"sourceId" => fact["sourceId"], "href" => r["html_url"]}}
          end)

        candidates =
          Comma.RecommendationMemberSelection.candidates(%{
            sources: %{"github" => fact},
            references: refs,
            prepared_at: ~U[2026-09-19 00:00:00Z]
          })

        if candidates != [], do: {size, candidates}
      end)

    assert is_nil(result), "stale GitHub admitted after collector truncation: #{inspect(result)}"
  end

  test "managed preview discovery matches the dispatch registry and unknown kinds fail closed",
       ctx do
    assert CommaWeb.RecommendationLinkPreview.managed_toolkits() == ~w(github linear notion slack)
    refute CommaWeb.RecommendationLinkPreview.managed_toolkit?("outlook")

    assert {:error, :not_found} =
             RecommendationOAuthSource.preview_managed(
               ctx.workspace,
               "user",
               Map.put(ctx.source, "appId", "outlook"),
               {:linear_issue, "ENG-1"}
             )
  end

  test "Linear pinned issue needs live viewer, organization and exact identifier", ctx do
    href = "https://linear.app/team/issue/ENG-9?not-forwarded=secret"

    reply = fn viewer, identifier ->
      %{
        "data" => %{
          "viewer" => %{"id" => viewer},
          "organization" => %{"id" => "organization"},
          "issue" => %{"identifier" => identifier, "title" => "Private issue", "url" => href}
        }
      }
    end

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/graphql"
      assert conn.method == "POST"
      Req.Test.json(conn, reply.("viewer", "ENG-9"))
    end)

    assert {:ok, %{"kind" => "linear_issue", "title" => "Private issue"}} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               ctx.source["connectionId"],
               "user"
             )

    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, reply.("stranger", "ENG-9")) end)

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               ctx.source["connectionId"],
               "user"
             )

    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, reply.("viewer", "OTHER-9")) end)

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               ctx.source["connectionId"],
               "user"
             )

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               ctx.source["connectionId"],
               "another-user"
             )
  end

  test "Notion page uses exact id and denies mismatched provider object", ctx do
    connection = %{
      ctx.connection
      | "provider" => "notion",
        "metadata" => %{
          "metadata" => %{
            "owner" => %{"type" => "user", "user" => %{"id" => "notion-user"}},
            "workspace_id" => "notion-space"
          }
        }
    }

    :ok = SalixStore.OAuth.put("conn-1", connection)
    {:ok, binding, nil} = OAuthBindings.put("tenant", "group", "notion", "notion", "conn-1")
    href = "https://notion.so/4b8e7d0d9f1a4ed89d6ba8d11080a812"
    source_id = binding["binding_id"]

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/pages/4b8e7d0d-9f1a-4ed8-9d6b-a8d11080a812"

      Req.Test.json(conn, %{
        "object" => "page",
        "id" => "4b8e7d0d-9f1a-4ed8-9d6b-a8d11080a812",
        "properties" => %{
          "Name" => %{"type" => "title", "title" => [%{"plain_text" => "Private plan"}]}
        }
      })
    end)

    assert {:ok, %{"title" => "Private plan"}} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               source_id,
               "user"
             )

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "object" => "page",
        "id" => "11111111-1111-1111-1111-111111111111",
        "properties" => %{}
      })
    end)

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               source_id,
               "user"
             )
  end

  test "managed Slack requires member/team/host and exact message timestamp", ctx do
    source = slack_source(ctx)
    href = "https://workspace.slack.com/archives/C123456/p1786900000000200"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/auth.test"

      Req.Test.json(conn, %{
        "ok" => true,
        "user_id" => "UMEMBER",
        "team_id" => "TWORKSPACE",
        "url" => "https://workspace.slack.com/"
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/conversations.history"

      Req.Test.json(conn, %{
        "ok" => true,
        "messages" => [%{"ts" => "1786900000.000200", "text" => "Private update"}]
      })
    end)

    # The channel name is a best-effort garnish after the message read.
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/conversations.info"
      Req.Test.json(conn, %{"ok" => false, "error" => "channel_not_found"})
    end)

    assert {:ok, %{"text" => "Private update"}} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               source["connectionId"],
               "user"
             )

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "ok" => true,
        "user_id" => "UMEMBER",
        "team_id" => "TOTHER",
        "url" => "https://workspace.slack.com/"
      })
    end)

    assert {:error, :not_found} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               source["connectionId"],
               "user"
             )
  end

  test "managed Slack reply selects exact child when the parent is returned first", ctx do
    source = slack_source(ctx)

    href =
      "https://workspace.slack.com/archives/C123456/p1786900000000200?thread_ts=1786900000.000100"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/auth.test"

      Req.Test.json(conn, %{
        "ok" => true,
        "user_id" => "UMEMBER",
        "team_id" => "TWORKSPACE",
        "url" => "https://workspace.slack.com/"
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/conversations.replies"

      Req.Test.json(conn, %{
        "ok" => true,
        "messages" => [
          %{"ts" => "1786900000.000100", "text" => "Parent secret"},
          %{"ts" => "1786900000.000200", "text" => "Exact reply"}
        ]
      })
    end)

    # The channel name is a best-effort garnish after the message read.
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/conversations.info"
      Req.Test.json(conn, %{"ok" => false, "error" => "channel_not_found"})
    end)

    assert {:ok, %{"text" => "Exact reply"}} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               ctx.workspace,
               href,
               source["connectionId"],
               "user"
             )
  end

  defp slack_source(ctx) do
    connection = %{
      ctx.connection
      | "provider" => "slack",
        "metadata" => %{"metadata" => %{"authed_user_id" => "UMEMBER", "team_id" => "TWORKSPACE"}}
    }

    :ok = SalixStore.OAuth.put("conn-1", connection)
    {:ok, binding, nil} = OAuthBindings.put("tenant", "group", "slack", "slack", "conn-1")

    %{
      "appId" => "slack",
      "kind" => "managed_oauth",
      "connectionId" => binding["binding_id"]
    }
  end

  defp github_source(ctx) do
    connection =
      Map.merge(ctx.connection, %{
        "provider" => "github",
        "connection_id" => "github-1",
        "metadata" => %{"metadata" => %{"user_id" => 42, "login" => "member"}}
      })

    :ok = SalixStore.OAuth.put("github-1", connection)
    {:ok, binding, nil} = OAuthBindings.put("tenant", "group", "github", "github", "github-1")
    %{"appId" => "github", "kind" => "managed_oauth", "connectionId" => binding["binding_id"]}
  end

  defp github_issue(id, assignee),
    do: %{
      "id" => id,
      "title" => "Assigned work",
      "state" => "open",
      "html_url" => "https://github.com/example/project/issues/#{id}",
      "assignees" => [%{"id" => assignee}]
    }

  defp response(issues, notifications \\ []),
    do: %{
      "data" => %{
        "organization" => %{"id" => "organization"},
        "viewer" => %{"id" => "viewer", "assignedIssues" => %{"nodes" => issues}},
        "notifications" => %{"nodes" => notifications}
      }
    }

  defp issue(id, user, state),
    do: %{
      "id" => id,
      "url" => "https://linear.app/team/issue/" <> id,
      "title" => id,
      "priority" => 2,
      "state" => %{"type" => state},
      "assignee" => %{"id" => user}
    }
end
