defmodule CommaWeb.RecommendationMemberSourceTest do
  use ExUnit.Case, async: false

  alias CommaWeb.{RecommendationMemberIdentity, RecommendationOAuthSource}
  alias Salix.Control.OAuthBindings

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Application.get_env(:salix_store, :s3_backend)
    http = Application.get_env(:comma_web, :recommendation_oauth_http_options)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    Application.put_env(:comma_web, :recommendation_oauth_http_options,
      plug: {Req.Test, __MODULE__}
    )

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      for {app, key, value} <- [
            {:salix_store, :s3_backend, previous},
            {:comma_web, :recommendation_oauth_http_options, http}
          ] do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
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
      now = DateTime.utc_now()

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/graphql" ->
            {:ok, request, conn} = Plug.Conn.read_body(conn)
            fields = Jason.decode!(request)["query"]
            record = issue("mine", "viewer", "started")
            # Return the field only if it was requested, as the provider does.
            record =
              if fields =~ "description", do: Map.put(record, "description", body), else: record

            Req.Test.json(conn, response([record]))

          "/user" ->
            Req.Test.json(conn, %{"id" => 42, "login" => "member"})

          "/issues" ->
            record =
              github_issue(1, 42)
              |> Map.merge(%{"body" => body, "updated_at" => DateTime.to_iso8601(now)})

            Req.Test.json(conn, [record])

          "/search/issues" ->
            Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})
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

  test "GitHub uses live numeric identity and only assigned open work", ctx do
    source = github_source(ctx)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/user"
      Req.Test.json(conn, %{"id" => 42, "login" => "renamed-user"})
    end)

    # Assigned issues and both searches run concurrently, in any order.
    test = self()

    Req.Test.expect(__MODULE__, 3, fn conn ->
      params = Plug.Conn.fetch_query_params(conn).query_params

      case {conn.request_path, params["q"]} do
        {"/issues", _query} ->
          assert params["filter"] == "assigned"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer member-token"]
          send(test, {:github_read, :assigned})

          Req.Test.json(conn, [
            github_issue(1, 42),
            github_issue(2, 99),
            Map.put(github_issue(3, 42), "state", "closed"),
            github_issue(1, 42)
          ])

        {"/search/issues", "is:pr is:open review-requested:renamed-user"} ->
          send(test, {:github_read, :reviews})

          Req.Test.json(conn, %{
            "items" => [Map.put(github_issue(4, 99), "pull_request", %{})],
            "incomplete_results" => false
          })

        {"/search/issues", "mentions:renamed-user is:open updated:>=" <> date} ->
          assert date =~ ~r/^\d{4}-\d{2}-\d{2}$/
          send(test, {:github_read, :mentions})
          Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})
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
    for read <- [:assigned, :reviews, :mentions], do: assert_received({:github_read, ^read})
  end

  test "GitHub adds open work that mentions the member with the mentioning comment", ctx do
    source = github_source(ctx)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

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

  test "Linear adds recent open inbox mentions before assigned issues", ctx do
    now = DateTime.utc_now()
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

    Req.Test.expect(__MODULE__, fn conn ->
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
      if conn.request_path == "/issues",
        do: Req.Test.json(conn, []),
        else: Req.Test.json(conn, %{"items" => [], "incomplete_results" => false})
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
    now = DateTime.utc_now() |> DateTime.to_iso8601()
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
    now = DateTime.utc_now()
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
