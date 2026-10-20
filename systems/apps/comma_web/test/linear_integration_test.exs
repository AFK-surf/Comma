defmodule CommaWeb.LinearIntegrationTest do
  use SystemsClock.Case, async: false

  import Comma.WorkspaceTestSupport
  import Plug.Conn
  import Plug.Test

  alias SalixIM.TestSupport.BanditServer

  @router_opts CommaWeb.Router.init([])
  @webhook_secret "linear-webhook-secret-for-tests-0123456789"
  @organization_id "org-acme-1"
  @app_user_id "app-user-comma-1"

  defmodule LinearAPI do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case {conn.method, conn.path_info} do
        {"POST", ["oauth", "token"]} ->
          {:ok, raw, conn} = read_body(conn)
          form = URI.decode_query(raw)
          SystemsRuntime.Proc.send(test_pid(), {:linear_token_exchange, form})

          # A `user-code-<name>` code authorizes the person <name>; any other
          # code installs the app.
          case form["code"] do
            "user-code-" <> name ->
              json(conn, 200, %{
                "access_token" => "linear-user-token:" <> name,
                "token_type" => "Bearer",
                "expires_in" => 60 * 60 * 24,
                "scope" => "read"
              })

            _app ->
              json(conn, 200, %{
                "access_token" => "linear-app-token",
                "token_type" => "Bearer",
                "expires_in" => 60 * 60 * 24 * 365,
                "scope" => "read,write,app:assignable,app:mentionable"
              })
          end

        {"POST", ["oauth", "revoke"]} ->
          {:ok, raw, conn} = read_body(conn)
          SystemsRuntime.Proc.send(test_pid(), {:linear_revoke, URI.decode_query(raw)})
          send_resp(conn, 200, "")

        {"POST", ["graphql"]} ->
          {:ok, raw, conn} = read_body(conn)
          request = Jason.decode!(raw)
          graphql(conn, request["query"] || "", request["variables"] || %{}, bearer(conn))

        _other ->
          send_resp(conn, 404, "")
      end
    end

    defp bearer(conn) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> ""
      end
    end

    defp graphql(conn, query, variables, token) do
      cond do
        token == "linear-app-token" and
            SystemsRuntime.get_env(:comma_web, :linear_app_token_dead) == true ->
          json(conn, 401, %{"errors" => [%{"message" => "authentication required"}]})

        token == "linear-app-token" and
            SystemsRuntime.get_env(:comma_web, :linear_app_token_dead) == :unreachable ->
          json(conn, 503, %{"error" => "unavailable"})

        String.contains?(query, "viewer") ->
          viewer =
            case token do
              "linear-user-token:" <> name ->
                %{
                  "id" => "linear-user-" <> name,
                  "name" => String.capitalize(name),
                  "email" => name <> "@acme.test"
                }

              _app ->
                %{"id" => "app-user-comma-1", "name" => "Comma", "email" => nil}
            end

          organization_id =
            SystemsRuntime.get_env(:comma_web, :linear_app_organization_id, "org-acme-1")

          json(conn, 200, %{
            "data" => %{
              "viewer" => viewer,
              "organization" => %{
                "id" => organization_id,
                "name" => "Acme",
                "urlKey" => "acme"
              }
            }
          })

        String.contains?(query, "agentActivityCreate") and
            SystemsRuntime.get_env(:comma_web, :linear_activity_response) == :drop_once ->
          # The connection closes before Linear records anything: the caller
          # cannot tell whether the activity was created.
          SystemsRuntime.delete_env(:comma_web, :linear_activity_response)

          SystemsRuntime.Proc.send(
            test_pid(),
            {:linear_activity_dropped, variables["input"]["agentSessionId"]}
          )

          SystemsRuntime.Proc.exit(SystemsRuntime.Proc.self(), :kill)

        String.contains?(query, "agentActivityCreate") ->
          input = variables["input"]
          id = "activity-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))
          CommaWeb.LinearTestActivities.put(input["agentSessionId"], input["content"])

          SystemsRuntime.Proc.send(
            test_pid(),
            {:linear_activity, input["agentSessionId"], input["content"], input}
          )

          case SystemsRuntime.get_env(:comma_web, :linear_activity_response) do
            {status, body} when is_integer(status) ->
              json(conn, status, body)

            _ ->
              json(conn, 200, %{
                "data" => %{
                  "agentActivityCreate" => %{"success" => true, "agentActivity" => %{"id" => id}}
                }
              })
          end

        String.contains?(query, "issueUpdate") ->
          SystemsRuntime.Proc.send(
            test_pid(),
            {:linear_issue_update, variables["id"], variables["input"]}
          )

          json(conn, 200, %{"data" => %{"issueUpdate" => %{"success" => true}}})

        String.contains?(query, "issue(id") ->
          type = SystemsRuntime.get_env(:comma_web, :linear_issue_state_type, "unstarted")

          json(conn, 200, %{
            "data" => %{
              "issue" => %{
                "id" => variables["id"],
                "team" => %{"id" => "team-eng"},
                "state" => %{"id" => "st_" <> type, "type" => type}
              }
            }
          })

        String.contains?(query, "states") ->
          json(conn, 200, %{
            "data" => %{
              "team" => %{
                "states" => %{
                  "nodes" => [
                    %{
                      "id" => "st_todo",
                      "name" => "Todo",
                      "type" => "unstarted",
                      "position" => 0
                    },
                    %{
                      "id" => "st_review",
                      "name" => "In Review",
                      "type" => "started",
                      "position" => 2
                    },
                    %{
                      "id" => "st_progress",
                      "name" => "In Progress",
                      "type" => "started",
                      "position" => 1
                    },
                    %{"id" => "st_done", "name" => "Done", "type" => "completed", "position" => 3}
                  ]
                }
              }
            }
          })

        String.contains?(query, "agentSessionUpdate") ->
          SystemsRuntime.Proc.send(
            test_pid(),
            {:linear_session_update, variables["id"], variables["input"]}
          )

          json(conn, 200, %{"data" => %{"agentSessionUpdate" => %{"success" => true}}})

        String.contains?(query, "activities") ->
          nodes =
            variables["id"]
            |> CommaWeb.LinearTestActivities.list()
            |> Enum.with_index()
            |> Enum.map(fn {content, index} ->
              typename = "AgentActivity" <> String.capitalize(content["type"]) <> "Content"

              %{
                "id" => "activity-#{index}",
                "content" => Map.merge(%{"__typename" => typename}, Map.delete(content, "type"))
              }
            end)

          json(conn, 200, %{"data" => %{"agentSession" => %{"activities" => %{"nodes" => nodes}}}})

        true ->
          json(conn, 200, %{"errors" => [%{"message" => "unsupported test query"}]})
      end
    end

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp test_pid, do: SystemsRuntime.fetch_env!(:comma_web, :linear_test_pid)
  end

  defmodule InteractionDelivery do
    @moduledoc false
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :linear_test_pid),
        {:interaction_input, agent_id, payload, opts}
      )

      {:ok, :queued}
    end
  end

  setup_all do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    :ok = Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
    :ok
  end

  setup do
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)

    comma_owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    on_exit(fn -> CommaWeb.TestRepoSandbox.stop_owner(comma_owner) end)

    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      overrides: SystemsRuntime.get_env(:salix_store, :oauth_endpoint_overrides),
      linear: SystemsRuntime.get_env(:comma_web, :linear_agent),
      test_pid: SystemsRuntime.get_env(:comma_web, :linear_test_pid),
      activity_response: SystemsRuntime.get_env(:comma_web, :linear_activity_response),
      bridge_wait: SystemsRuntime.get_env(:comma_web, :linear_agent_bridge_wait_ms),
      app_organization: SystemsRuntime.get_env(:comma_web, :linear_app_organization_id),
      app_token_dead: SystemsRuntime.get_env(:comma_web, :linear_app_token_dead),
      revoked_retry: SystemsRuntime.get_env(:comma_web, :linear_revoked_check_retry_ms),
      bind_wait: SystemsRuntime.get_env(:comma_web, :linear_task_bind_wait_ms),
      bind_attempts: SystemsRuntime.get_env(:comma_web, :linear_task_bind_attempts),
      adapter: SystemsRuntime.get_env(:salix_im, :linear_agent_session_adapter),
      delivery: SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    }

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous.s3)
      restore_env(:salix_store, :oauth_endpoint_overrides, previous.overrides)
      restore_env(:comma_web, :linear_agent, previous.linear)
      restore_env(:comma_web, :linear_test_pid, previous.test_pid)
      restore_env(:comma_web, :linear_activity_response, previous.activity_response)
      restore_env(:comma_web, :linear_agent_bridge_wait_ms, previous.bridge_wait)
      restore_env(:comma_web, :linear_app_organization_id, previous.app_organization)
      restore_env(:comma_web, :linear_app_token_dead, previous.app_token_dead)
      restore_env(:comma_web, :linear_revoked_check_retry_ms, previous.revoked_retry)
      restore_env(:comma_web, :linear_task_bind_wait_ms, previous.bind_wait)
      restore_env(:comma_web, :linear_task_bind_attempts, previous.bind_attempts)
      restore_env(:salix_im, :linear_agent_session_adapter, previous.adapter)
      restore_env(:salix_im, :agent_delivery_mod, previous.delivery)
    end)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    start_supervised!(CommaWeb.LinearTestActivities)

    port = BanditServer.start!(fn port -> {Bandit, plug: LinearAPI, port: port} end)
    base = "http://127.0.0.1:#{port}"

    SystemsRuntime.put_env(:salix_store, :oauth_endpoint_overrides, %{
      "linear" => %{
        "token_url" => base <> "/oauth/token",
        "revoke_url" => base <> "/oauth/revoke",
        "api_url" => base <> "/graphql"
      }
    })

    SystemsRuntime.put_env(:comma_web, :linear_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.delete_env(:comma_web, :linear_activity_response)
    SystemsRuntime.put_env(:comma_web, :linear_agent_bridge_wait_ms, 200)
    SystemsRuntime.put_env(:salix_im, :linear_agent_session_adapter, CommaWeb.LinearAgentSession)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)

    SystemsRuntime.put_env(:comma_web, :linear_agent,
      enabled: true,
      client_id: "linear-client",
      client_secret: "linear-client-secret",
      webhook_secret: @webhook_secret,
      public_base_url: "https://comma.test"
    )

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "linear-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace =
      user
      |> create_ready_workspace!(%{"name" => "Linear Team"})
      |> CommaWeb.TestWorkers.with_default_worker!()

    {:ok, session} = Comma.Accounts.create_session(user["id"])

    %{session: session, user: user, workspace: workspace}
  end

  describe "connect" do
    test "the first person links their Linear account and installs Comma into the organization",
         c do
      attempt =
        api_request(c.session, :post, linear_path(c.workspace) <> "/connect", %{
          "environment" => "dev"
        })
        |> expect_json(201)

      # The person authorizes as themselves first: Comma learns who they are.
      uri = URI.parse(attempt["authorization_url"])
      query = URI.decode_query(uri.query)
      assert uri.host == "linear.app"
      refute Map.has_key?(query, "actor")
      assert query["scope"] == "read"

      assert query["redirect_uri"] ==
               "https://comma.test/v1/comma/integrations/linear/connect/callback"

      assert String.starts_with?(query["state"], "dev.")

      # Their organization has no Comma yet: the same window goes on to the
      # app installation.
      conn = callback(query["state"], "user-code-yue")
      assert conn.status == 302, conn.resp_body
      [location] = get_resp_header(conn, "location")
      assert_receive {:linear_token_exchange, %{"code" => "user-code-yue"}}
      # The person's own token is not kept: it is revoked once their identity is read.
      assert_receive {:linear_revoke, %{"token" => "linear-user-token:yue"}}, 2_000

      install = URI.parse(location)
      install_query = URI.decode_query(install.query)
      assert install.host == "linear.app"
      assert install_query["actor"] == "app"
      assert install_query["scope"] == "read,write,app:assignable,app:mentionable"
      assert String.starts_with?(install_query["state"], "dev.")
      assert install_query["state"] != query["state"]

      conn = callback(install_query["state"], "app-code")
      assert conn.status == 200, conn.resp_body
      assert conn.resp_body =~ "Linear connected"
      assert conn.resp_body =~ "comma-dev://linear/return?workspace_id="
      assert_receive {:linear_token_exchange, %{"code" => "app-code", "code_verifier" => _}}

      state = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert state["configured"] == true
      assert state["installation"]["organization_id"] == @organization_id
      assert state["installation"]["organization_name"] == "Acme"
      assert state["installation"]["installer"] == true
      assert state["installation"]["revoked"] == false
      assert state["member"]["linear_user_id"] == "linear-user-yue"
      assert state["member"]["linear_user_name"] == "Yue"
      assert state["member"]["linear_user_email"] == "yue@acme.test"
      assert state["member"]["completion_state_policy"] == "unchanged"
      assert state["member"]["worker_agent_id"] == nil

      # A consumed state cannot complete a second time.
      assert callback(install_query["state"], "app-code").status == 400
    end

    test "a second person in an installed organization links without installing", c do
      install!(c)
      other = other_person!("xp")

      conn = connect(other.session, other.workspace, "user-code-xp")
      assert conn.status == 200, conn.resp_body
      assert conn.resp_body =~ "Linear connected"
      # Only the person's own authorization happened: no app installation.
      refute_receive {:linear_token_exchange, _}

      state = api_request(other.session, :get, linear_path(other.workspace)) |> expect_json(200)
      assert state["installation"]["organization_id"] == @organization_id
      assert state["installation"]["installer"] == false
      assert state["member"]["linear_user_id"] == "linear-user-xp"
      assert state["member"]["linear_user_name"] == "Xp"

      # Only the Workspace that installed Comma can remove it from the organization.
      assert api_request(
               other.session,
               :delete,
               linear_path(other.workspace) <> "?scope=organization"
             ).status ==
               403

      kept = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert kept["installation"]["installer"] == true
      assert kept["member"]["linear_user_id"] == "linear-user-yue"
    end

    test "a Linear user links to one Workspace: the latest authorization wins", c do
      install!(c)
      other = other_person!("other")

      assert connect(other.session, other.workspace, "user-code-yue").status == 200

      moved = api_request(other.session, :get, linear_path(other.workspace)) |> expect_json(200)
      assert moved["member"]["linear_user_id"] == "linear-user-yue"

      # The installer keeps the installation it holds, without a link.
      state = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert state["member"] == nil
      assert state["installation"]["installer"] == true
    end

    test "installing again after Linear removed Comma replaces the installation", c do
      install!(c)
      first = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert {:ok, _} = Comma.LinearInstallations.mark_revoked(@organization_id)

      # Connecting again goes through the app installation; the replaced
      # token is only forgotten, since revoking it could uninstall the app
      # just authorized again.
      install!(c)
      refute_receive {:linear_revoke, %{"token" => "linear-app-token"}}

      again = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert again["installation"]["id"] == first["installation"]["id"]
      assert again["installation"]["revoked"] == false
      assert again["installation"]["updated_at"] != first["installation"]["updated_at"]
      assert again["member"]["id"] == first["member"]["id"]
      assert again["member"]["updated_at"] != first["member"]["updated_at"]

      assert %{"disconnected" => true} =
               api_request(c.session, :delete, linear_path(c.workspace) <> "?scope=organization")
               |> expect_json(200)

      assert_receive {:linear_revoke, %{"token" => "linear-app-token"}}, 2_000
      state = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert state["installation"] == nil
      assert state["member"] == nil
    end

    test "an app installed into another organization than the person's is refused", c do
      attempt =
        api_request(c.session, :post, linear_path(c.workspace) <> "/connect", %{})
        |> expect_json(201)

      conn = callback(state_of(attempt["authorization_url"]), "user-code-yue")
      assert conn.status == 302
      [location] = get_resp_header(conn, "location")

      SystemsRuntime.put_env(:comma_web, :linear_app_organization_id, "org-other-9")
      conn = callback(state_of(location), "app-code")
      assert conn.status == 400
      # Nobody holds that organization: the stray installation is removed again.
      assert_receive {:linear_revoke, %{"token" => "linear-app-token"}}, 2_000

      state = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert state["installation"] == nil
      assert state["member"] == nil

      # Another Workspace holds that organization: its app installation stays.
      other = other_person!("xp")
      assert connect(other.session, other.workspace, "user-code-xp").status == 200
      SystemsRuntime.delete_env(:comma_web, :linear_app_organization_id)

      attempt =
        api_request(c.session, :post, linear_path(c.workspace) <> "/connect", %{})
        |> expect_json(201)

      conn = callback(state_of(attempt["authorization_url"]), "user-code-yue")
      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      SystemsRuntime.put_env(:comma_web, :linear_app_organization_id, "org-other-9")
      assert callback(state_of(location), "app-code").status == 400
      refute_receive {:linear_revoke, %{"token" => "linear-app-token"}}

      kept = api_request(other.session, :get, linear_path(other.workspace)) |> expect_json(200)
      assert kept["installation"]["organization_id"] == "org-other-9"
      assert kept["installation"]["revoked"] == false
    end

    test "connecting again with the same account refreshes the link", c do
      install!(c)
      first = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)

      # The organization has Comma: only the person's authorization runs, and
      # the unchanged link still shows the connect landed.
      install!(c)
      refute_receive {:linear_token_exchange, %{"code" => "app-code"}}

      again = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert again["member"]["id"] == first["member"]["id"]
      assert again["member"]["updated_at"] != first["member"]["updated_at"]
      assert again["installation"]["updated_at"] == first["installation"]["updated_at"]
    end

    test "two people connecting to the same organization at once share one installation", c do
      other = other_person!("xp")

      first =
        api_request(c.session, :post, linear_path(c.workspace) <> "/connect", %{})
        |> expect_json(201)

      second =
        api_request(other.session, :post, linear_path(other.workspace) <> "/connect", %{})
        |> expect_json(201)

      conn = callback(state_of(first["authorization_url"]), "user-code-yue")
      assert conn.status == 302
      [first_install] = get_resp_header(conn, "location")
      conn = callback(state_of(second["authorization_url"]), "user-code-xp")
      assert conn.status == 302
      [second_install] = get_resp_header(conn, "location")

      assert callback(state_of(first_install), "app-code").status == 200
      # The installation landed meanwhile: the second person joins it, and
      # the holder stays.
      assert callback(state_of(second_install), "app-code").status == 200
      refute_receive {:linear_revoke, %{"token" => "linear-app-token"}}

      holder = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert holder["installation"]["installer"] == true
      joined = api_request(other.session, :get, linear_path(other.workspace)) |> expect_json(200)
      assert joined["installation"]["id"] == holder["installation"]["id"]
      assert joined["installation"]["installer"] == false
      assert joined["member"]["linear_user_id"] == "linear-user-xp"
    end

    test "a non-owner cannot manage the installation", c do
      {:ok, other} =
        Comma.Accounts.create_user(%{
          "email" => "other-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
        })

      {:ok, other_session} = Comma.Accounts.create_session(other["id"])
      conn = api_request(other_session, :get, linear_path(c.workspace))
      assert conn.status in [403, 404]
    end

    test "settings choose the completion policy; a shipped app's Worker choice is ignored", c do
      install!(c)

      # Desktop apps already shipped read a Worker list and the member's Worker.
      state = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert state["workers"] == []
      assert state["member"]["worker_agent_id"] == nil

      updated =
        api_request(c.session, :patch, linear_path(c.workspace), %{
          "worker_agent_id" => c.workspace["default_worker_agent_id"],
          "completion_state_policy" => "in_review"
        })
        |> expect_json(200)

      assert updated["worker_agent_id"] == nil
      assert updated["completion_state_policy"] == "in_review"

      assert {:ok, _workspace, %{member: %{worker_agent_id: nil}}} =
               Comma.LinearInstallations.get(c.user, c.session, c.workspace["id"])

      # Disconnecting removes the person's link; the installation they hold stays.
      assert %{"disconnected" => true} =
               api_request(c.session, :delete, linear_path(c.workspace)) |> expect_json(200)

      state = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert state["member"] == nil
      assert state["installation"]["installer"] == true
      assert api_request(c.session, :patch, linear_path(c.workspace), %{}).status == 404
    end
  end

  describe "webhooks" do
    setup c do
      install!(c)
      :ok
    end

    test "rejects a bad signature or a stale timestamp", c do
      payload = created_payload("sess-bad")

      conn =
        :post
        |> json_conn(webhook_path(), payload)
        |> put_req_header("linear-signature", "00")
        |> call()

      assert conn.status == 401

      stale =
        Map.put(
          payload,
          "webhookTimestamp",
          SystemsClock.system_time(:millisecond) - 60 * 60 * 1000
        )

      assert webhook_request(stale).status == 401
      refute_receive {:linear_activity, "sess-bad", _, _}, 100
      assert {:error, :not_found} = Comma.LinearInstallations.get_agent_session("sess-bad")
      _ = c
    end

    test "a session created by a Linear user without a link is refused without a chat", c do
      payload = created_payload("sess-stranger", "linear-user-stranger")
      assert webhook_request(payload) |> expect_json(200) == %{"ok" => true}

      assert_receive {:linear_activity, "sess-stranger", %{"type" => "error", "body" => body}, _},
                     5_000

      assert body =~ "connect your Linear account"
      refute_receive {:linear_activity, "sess-stranger", %{"type" => "thought"}, _}
      assert {:error, :not_found} = Comma.LinearInstallations.get_agent_session("sess-stranger")
      _ = c
    end

    test "a created session opens a chat with the Router and hands it the issue", c do
      payload = created_payload("sess-1")
      assert webhook_request(payload) |> expect_json(200) == %{"ok" => true}

      assert_receive {:linear_activity, "sess-1", %{"type" => "thought", "body" => body}, _},
                     5_000

      assert body =~ "looking at it"

      assert_receive {:linear_session_update, "sess-1", %{"addedExternalUrls" => [link]}}, 5_000
      assert link["label"] == "Open in Comma"
      assert link["url"] =~ "/#/inbox/"
      # Nothing moves the issue until the Router creates a Task for it.
      refute_receive {:linear_issue_update, "issue-sess-1", _}

      {:ok, agent_session} = Comma.LinearInstallations.get_agent_session("sess-1")
      group_id = c.workspace["default_group_id"]
      assert agent_session.group_id == group_id
      assert agent_session.task_conversation_id == nil

      {:ok, chat} =
        SalixIM.Conversations.get_group_conversation(group_id, agent_session.conversation_id)

      assert chat["kind"] == "user_chat"
      assert chat["title"] == "ENG-1: Fix login redirect"
      assert chat["owner_user_id"] == c.user["id"]
      assert get_in(chat, ["source_refs", "linear", "agent_session_id"]) == "sess-1"

      {:ok, %{"participants" => participants}} =
        SalixIM.Conversations.list_group_conversation_participants(
          group_id,
          agent_session.conversation_id
        )

      router = c.workspace["router_agent_id"]
      assert Enum.any?(participants, &(&1["actor_type"] == "agent" and &1["agent_id"] == router))
      assert [linear] = Enum.filter(participants, &(&1["provider"] == "linear"))
      assert linear["payload"]["surface"] == "chat"

      request = provider_messages(c, agent_session.conversation_id) |> List.first()
      text = SalixIM.ConversationMessage.text_content(request["content"])
      assert text =~ "Fix login redirect"
      assert text =~ "Create a Task only when"
      assert request["user_id"] == "linear-user-yue"

      # Linear retries a webhook it did not see answered: the same session
      # finds its chat and asks nothing twice.
      assert webhook_request(payload) |> expect_json(200) == %{"ok" => true}
      assert_receive {:linear_activity, "sess-1", %{"type" => "thought"}, _}, 5_000
      {:ok, again} = Comma.LinearInstallations.get_agent_session("sess-1")
      assert again.conversation_id == agent_session.conversation_id
      assert length(provider_messages(c, agent_session.conversation_id)) == 1
    end

    test "the owner opens the session's chat in Comma and writes in it", c do
      start_session!("sess-open")
      {:ok, agent_session} = Comma.LinearInstallations.get_agent_session("sess-open")
      group_id = c.workspace["default_group_id"]
      path = "/v1/comma/groups/#{group_id}/conversations/#{agent_session.conversation_id}"

      chat = api_request(c.session, :get, path) |> expect_json(200)
      assert chat["kind"] == "user_chat"
      assert chat["title"] == "ENG-1: Fix login redirect"
      assert Enum.any?(chat["messages"], &(&1["actor_type"] == "provider_user"))

      # Writing to the Router is admitted like any chat message: it needs credits.
      grant_credits!(c.workspace)

      sent =
        api_request(c.session, :post, path <> "/messages", %{
          "content" => [%{"type" => "text", "text" => "I will take this one myself."}]
        })
        |> expect_json(202)

      assert Enum.any?(
               sent["messages"],
               &(&1["actor_type"] == "user" and
                   SalixIM.ConversationMessage.text_content(&1["content"]) ==
                     "I will take this one myself.")
             )

      # The Router's answer to what the owner wrote in Comma stays in Comma:
      # Linear would see an answer without its question.
      router_send(c, agent_session.conversation_id, "Sure, it is yours.")
      refute_receive {:linear_activity, "sess-open", %{"type" => "response"}, _}

      # An answer to a Linear prompt goes to Linear as before.
      prompt = prompted_payload("sess-open", "act-open", "Which files would change?")
      assert webhook_request(prompt) |> expect_json(200) == %{"ok" => true}

      assert eventually(fn ->
               length(provider_messages(c, agent_session.conversation_id)) == 2
             end)

      router_send(c, agent_session.conversation_id, "auth.ts and session.ts.")

      assert_receive {:linear_activity, "sess-open",
                      %{"type" => "response", "body" => "auth.ts and session.ts."}, _},
                     5_000

      # A late delivery is judged by what came before the Router message:
      # the owner writing more than a page in Comma afterwards does not hold
      # back its answer.
      for n <- 1..41 do
        api_request(c.session, :post, path <> "/messages", %{
          "content" => [%{"type" => "text", "text" => "Note #{n}."}]
        })
        |> expect_json(202)
      end

      {:ok, %{"messages" => messages}} =
        SalixIM.Conversations.list_group_conversation_message_page(
          group_id,
          agent_session.conversation_id,
          limit: 100
        )

      answer =
        Enum.find(
          messages,
          &(SalixIM.ConversationMessage.text_content(&1["content"]) == "auth.ts and session.ts.")
        )

      assert {:ok, _receipt} =
               CommaWeb.LinearAgentSession.deliver(%{
                 "delivery_kind" => "group_conversation",
                 "agent_group_id" => group_id,
                 "conversation_id" => agent_session.conversation_id,
                 "message_id" => answer["message_id"],
                 "message_seq" => answer["seq"],
                 "source_actor_type" => "agent",
                 "message_content" => answer["content"],
                 "participant_payload" => %{
                   "installation_id" => agent_session.installation_id,
                   "agent_session_id" => "sess-open",
                   "surface" => "chat"
                 }
               })

      assert_receive {:linear_activity, "sess-open",
                      %{"type" => "response", "body" => "auth.ts and session.ts."}, _},
                     5_000

      # Someone outside the Workspace sees nothing.
      other = other_person!("peek")
      assert api_request(other.session, :get, path).status in [403, 404]

      # A chat of the owner's without the Linear mark stays out of reach.
      {:ok, plain} =
        SalixIM.ConversationInput.create_group_conversation(group_id, %{
          "kind" => "user_chat",
          "title" => "Not from Linear",
          "status" => "active",
          "owner_user_id" => c.user["id"],
          "created_by_agent_id" => c.workspace["router_agent_id"],
          "participants" => []
        })

      plain_path = "/v1/comma/groups/#{group_id}/conversations/#{plain["conversation_id"]}"
      assert api_request(c.session, :get, plain_path).status == 404

      assert api_request(c.session, :post, plain_path <> "/messages", %{
               "content" => [%{"type" => "text", "text" => "hello"}]
             }).status == 404
    end

    test "the Router's answer reaches Linear as the response and a follow-up goes back to it",
         c do
      start_session!("sess-2")
      {:ok, agent_session} = Comma.LinearInstallations.get_agent_session("sess-2")
      chat = agent_session.conversation_id

      router_send(c, chat, "This is a one-line config change; no Task needed.")

      assert_receive {:linear_activity, "sess-2",
                      %{
                        "type" => "response",
                        "body" => "This is a one-line config change; no Task needed."
                      }, _},
                     5_000

      prompt = prompted_payload("sess-2", "act-1", "Also check the logout path")
      assert webhook_request(prompt) |> expect_json(200) == %{"ok" => true}
      assert webhook_request(prompt) |> expect_json(200) == %{"ok" => true}

      assert [_request, follow_up] = provider_messages(c, chat)

      assert SalixIM.ConversationMessage.text_content(follow_up["content"]) ==
               "Also check the logout path"

      assert follow_up["provider"] == "linear"
      assert get_in(follow_up, ["mentions", "participant_ids"]) != nil
      refute_receive {:linear_issue_update, "issue-sess-2", _}

      # A prompt for a session Comma never bridged tells the user in Linear.
      assert webhook_request(prompted_payload("sess-unknown", "act-9", "hello"))
             |> expect_json(200) ==
               %{"ok" => true}

      assert_receive {:linear_activity, "sess-unknown", %{"type" => "error", "body" => body}, _},
                     5_000

      assert body =~ "no conversation for this session"
    end

    test "a Task the Router creates from the chat binds to the session and mirrors its progress",
         c do
      start_session!("sess-3")
      task_id = start_task!(c.workspace, "sess-3")

      assert_receive {:linear_session_update, "sess-3",
                      %{
                        "addedExternalUrls" => [
                          %{"label" => "Task in Comma · ENG-1: Fix login redirect", "url" => url}
                        ]
                      }},
                     5_000

      assert url =~ "/task-panel.html?"
      assert url =~ "source=linear"
      assert_receive {:linear_issue_update, "issue-sess-3", %{"stateId" => "st_progress"}}, 5_000

      {:ok, agent_session} = Comma.LinearInstallations.get_agent_session("sess-3")
      group_id = c.workspace["default_group_id"]

      {:ok, task} = SalixIM.Conversations.get_group_conversation(group_id, task_id)
      assert task["kind"] == "agent_task"
      assert task["owner_user_id"] == c.user["id"]

      assert get_in(task, ["source_refs", "parent_conversation_id"]) ==
               agent_session.conversation_id

      {:ok, %{"participants" => participants}} =
        SalixIM.Conversations.list_group_conversation_participants(group_id, task_id)

      assert [linear] = Enum.filter(participants, &(&1["provider"] == "linear"))
      assert linear["payload"]["surface"] == "task"
      assert linear["payload"]["agent_session_id"] == "sess-3"

      # The Worker publishes progress; it reaches Linear as a thought.
      worker_send(c, task_id, "Found the redirect bug in auth.ts")

      assert_receive {:linear_activity, "sess-3",
                      %{"type" => "thought", "body" => "Found the redirect bug in auth.ts"}, _},
                     5_000

      # Review completes the answer as one response, restated status does not repeat it.
      set_task(c, task_id, %{"status" => "ready_for_review"})

      assert_receive {:linear_activity, "sess-3",
                      %{"type" => "response", "body" => "Found the redirect bug in auth.ts"}, _},
                     5_000

      set_task(c, task_id, %{"status" => "ready_for_review", "title" => "ENG-2: revised"})
      refute_receive {:linear_activity, "sess-3", %{"type" => "response"}, _}

      # Completion after review restates the same answer; it is posted once.
      set_task(c, task_id, %{"status" => "completed"})
      refute_receive {:linear_activity, "sess-3", %{"type" => "response"}, _}
    end

    test "a second Task from the chat takes the binding over once the first reached review", c do
      start_session!("sess-two")
      first = start_task!(c.workspace, "sess-two")
      group_id = c.workspace["default_group_id"]

      assert_receive {:linear_session_update, "sess-two",
                      %{
                        "addedExternalUrls" => [
                          %{"label" => "Task in Comma · ENG-1: Fix login redirect"}
                        ]
                      }},
                     5_000

      # The first Task still runs: a second one gets no Linear Participant
      # and the binding stays.
      second = create_task!(c.workspace, "sess-two", "second")
      refute_receive {:linear_session_update, "sess-two", _}

      {:ok, %{"participants" => participants}} =
        SalixIM.Conversations.list_group_conversation_participants(group_id, second)

      assert Enum.filter(participants, &(&1["provider"] == "linear")) == []
      {:ok, bound} = Comma.LinearInstallations.get_agent_session("sess-two")
      assert bound.task_conversation_id == first

      # The first Task delivers its answer and waits for review; the person
      # follows up in Linear and the next Task takes the binding over.
      worker_send(c, first, "First answer")
      assert_receive {:linear_activity, "sess-two", %{"type" => "thought"}, _}, 5_000
      set_task(c, first, %{"status" => "ready_for_review"})

      assert_receive {:linear_activity, "sess-two",
                      %{"type" => "response", "body" => "First answer"}, _},
                     5_000

      third = create_task!(c.workspace, "sess-two", "third")

      assert eventually(fn ->
               match?(
                 {:ok, %{task_conversation_id: ^third}},
                 Comma.LinearInstallations.get_agent_session("sess-two")
               )
             end)

      assert_receive {:linear_session_update, "sess-two",
                      %{
                        "addedExternalUrls" => [
                          %{"label" => "Task in Comma · ENG-1: Fix login redirect", "url" => url}
                        ]
                      }},
                     5_000

      assert url =~ third

      # The owner completes the first Task later in Comma: it posts nothing more.
      worker_send(c, first, "A late note on the first Task")
      set_task(c, first, %{"status" => "completed"})
      refute_receive {:linear_activity, "sess-two", _, _}

      # The third Task speaks for the session now; a stop from Linear ends it.
      worker_send(c, third, "Working on the follow-up")

      assert_receive {:linear_activity, "sess-two",
                      %{"type" => "thought", "body" => "Working on the follow-up"}, _},
                     5_000

      stop =
        prompted_payload("sess-two", "act-stop-two", "Stop")
        |> put_in(["agentActivity", "signal"], "stop")

      assert webhook_request(stop) |> expect_json(200) == %{"ok" => true}

      assert_receive {:linear_activity, "sess-two", %{"type" => "response", "body" => body}, _},
                     5_000

      assert body =~ "stopped working"
      {:ok, task} = SalixIM.Conversations.get_group_conversation(group_id, third)
      assert task["status"] == "cancelled"

      # A Task that takes over after a stop reports its own end: the stop
      # marker belongs to the Task it stopped.
      fourth = create_task!(c.workspace, "sess-two", "fourth")

      assert eventually(fn ->
               match?(
                 {:ok, %{task_conversation_id: ^fourth}},
                 Comma.LinearInstallations.get_agent_session("sess-two")
               )
             end)

      assert_receive {:linear_session_update, "sess-two", _}, 5_000
      set_task(c, fourth, %{"status" => "cancelled"})

      assert_receive {:linear_activity, "sess-two", %{"type" => "error", "body" => body}, _},
                     5_000

      assert body =~ "ended as cancelled"
    end

    test "a retried creation of the same Task keeps its Participant", c do
      start_session!("sess-retry")
      {:ok, agent_session} = Comma.LinearInstallations.get_agent_session("sess-retry")
      group_id = c.workspace["default_group_id"]
      task_id = SalixStore.Ids.new_conversation_id()
      refs = %{"parent_conversation_id" => agent_session.conversation_id}

      assert [%{"provider" => "linear"}] =
               CommaWeb.LinearAgentSession.task_participants(group_id, task_id, refs)

      assert [%{"provider" => "linear"}] =
               CommaWeb.LinearAgentSession.task_participants(group_id, task_id, refs)

      {:ok, bound} = Comma.LinearInstallations.get_agent_session("sess-retry")
      assert bound.task_conversation_id == task_id
    end

    test "a Task that never comes to exist loses its binding again", c do
      SystemsRuntime.put_env(:comma_web, :linear_task_bind_wait_ms, 10)
      SystemsRuntime.put_env(:comma_web, :linear_task_bind_attempts, 3)
      start_session!("sess-ghost")
      {:ok, agent_session} = Comma.LinearInstallations.get_agent_session("sess-ghost")
      group_id = c.workspace["default_group_id"]
      ghost = SalixStore.Ids.new_conversation_id()

      # Creation asks for the Participants, then fails: the Task id is never written.
      assert [%{"provider" => "linear"}] =
               CommaWeb.LinearAgentSession.task_participants(group_id, ghost, %{
                 "parent_conversation_id" => agent_session.conversation_id
               })

      assert eventually(fn ->
               match?(
                 {:ok, %{task_conversation_id: nil}},
                 Comma.LinearInstallations.get_agent_session("sess-ghost")
               )
             end)

      refute_receive {:linear_session_update, "sess-ghost", _}
      refute_receive {:linear_issue_update, "issue-sess-ghost", _}, 100

      # A Task that does exist binds as usual afterwards, with the usual wait
      # for its creation to commit.
      SystemsRuntime.delete_env(:comma_web, :linear_task_bind_wait_ms)
      SystemsRuntime.delete_env(:comma_web, :linear_task_bind_attempts)
      task_id = start_task!(c.workspace, "sess-ghost")

      assert_receive {:linear_issue_update, "issue-sess-ghost", %{"stateId" => "st_progress"}},
                     5_000

      {:ok, bound} = Comma.LinearInstallations.get_agent_session("sess-ghost")
      assert bound.task_conversation_id == task_id
    end

    test "a session from before the chat keeps speaking to its Task", c do
      start_session!("sess-legacy")
      task_id = start_task!(c.workspace, "sess-legacy")
      group_id = c.workspace["default_group_id"]

      # A row from the previous release: the session's conversation is the Task.
      require Ecto.Query

      {1, _} =
        Comma.Repo.update_all(
          Ecto.Query.from(row in Comma.Data.LinearAgentSession,
            where: row.agent_session_id == "sess-legacy"
          ),
          set: [conversation_id: task_id]
        )

      prompt = prompted_payload("sess-legacy", "act-legacy", "Also check the logout path")
      assert webhook_request(prompt) |> expect_json(200) == %{"ok" => true}

      assert eventually(fn -> provider_messages(c, task_id) != [] end)
      [follow_up] = provider_messages(c, task_id)

      {:ok, %{"participants" => participants}} =
        SalixIM.Conversations.list_group_conversation_participants(group_id, task_id)

      assert [_one] = Enum.filter(participants, &(&1["provider"] == "linear"))
      worker = Enum.find(participants, &(&1["role_label"] == "worker"))
      assert get_in(follow_up, ["mentions", "participant_ids"]) == [worker["participant_id"]]

      # Worker output still posts once, as a thought.
      worker_send(c, task_id, "Checked the logout path")

      assert_receive {:linear_activity, "sess-legacy", %{"type" => "thought"}, _}, 5_000
      refute_receive {:linear_activity, "sess-legacy", _, _}
    end

    test "each member's sessions open chats and Tasks in their own Workspace", c do
      other = other_person!("xp")
      assert connect(other.session, other.workspace, "user-code-xp").status == 200

      start_session!("sess-xp", "linear-user-xp")
      start_session!("sess-yue", "linear-user-yue")

      {:ok, xp_session} = Comma.LinearInstallations.get_agent_session("sess-xp")
      assert xp_session.workspace_id == other.workspace["id"]
      assert xp_session.group_id == other.workspace["default_group_id"]

      {:ok, xp_chat} =
        SalixIM.Conversations.get_group_conversation(
          xp_session.group_id,
          xp_session.conversation_id
        )

      assert xp_chat["owner_user_id"] == other.user["id"]

      {:ok, yue_session} = Comma.LinearInstallations.get_agent_session("sess-yue")
      assert yue_session.workspace_id == c.workspace["id"]
      assert yue_session.group_id == c.workspace["default_group_id"]

      # A Task from xp's chat belongs to xp, and a stop from Linear ends it as xp.
      task_id = start_task!(other.workspace, "sess-xp")
      {:ok, task} = SalixIM.Conversations.get_group_conversation(xp_session.group_id, task_id)
      assert task["owner_user_id"] == other.user["id"]

      stop =
        prompted_payload("sess-xp", "act-stop-xp", "Stop")
        |> put_in(["agentActivity", "signal"], "stop")

      assert webhook_request(stop) |> expect_json(200) == %{"ok" => true}
      assert_receive {:linear_activity, "sess-xp", %{"type" => "response"}, _}, 5_000

      {:ok, stopped} = SalixIM.Conversations.get_group_conversation(xp_session.group_id, task_id)
      assert stopped["status"] == "cancelled"
      assert get_in(stopped, ["manual_status_change", "user_id"]) == other.user["id"]
    end

    test "verification finds the posted response after the Worker writes again", c do
      start_session!("sess-verify")
      task_id = start_task!(c.workspace, "sess-verify")
      {:ok, agent_session} = Comma.LinearInstallations.get_agent_session("sess-verify")

      worker_send(c, task_id, "First answer")
      assert_receive {:linear_activity, "sess-verify", %{"type" => "thought"}, _}, 5_000

      set_task(c, task_id, %{"status" => "ready_for_review"})

      assert_receive {:linear_activity, "sess-verify",
                      %{"type" => "response", "body" => "First answer"}, _},
                     5_000

      # A later Worker message changes the latest text; the earlier attempt
      # must still verify as present instead of being sent again.
      worker_send(c, task_id, "Second note")
      assert_receive {:linear_activity, "sess-verify", %{"type" => "thought"}, _}, 5_000

      rec = %{
        "delivery_kind" => "conversation_status",
        "conversation_status" => "ready_for_review",
        "agent_group_id" => c.workspace["default_group_id"],
        "conversation_id" => task_id,
        "participant_payload" => %{
          "installation_id" => agent_session.installation_id,
          "agent_session_id" => "sess-verify",
          "surface" => "task"
        }
      }

      assert {:ok, %{"status" => "response_present"}} = CommaWeb.LinearAgentSession.verify(rec)
    end

    test "a response lost in transit is verified missing and sent again", c do
      start_session!("sess-lost")
      task_id = start_task!(c.workspace, "sess-lost")

      worker_send(c, task_id, "Lost answer")
      assert_receive {:linear_activity, "sess-lost", %{"type" => "thought"}, _}, 5_000

      SystemsRuntime.put_env(:comma_web, :linear_activity_response, :drop_once)
      set_task(c, task_id, %{"status" => "ready_for_review"})
      assert_receive {:linear_activity_dropped, "sess-lost"}, 5_000

      # The ambiguous send is verified against the session's activities, found
      # missing, and resent once.
      assert_receive {:linear_activity, "sess-lost",
                      %{"type" => "response", "body" => "Lost answer"}, _},
                     10_000

      refute_receive {:linear_activity, "sess-lost", %{"type" => "response"}, _}
    end

    test "a prompt that arrives before its chat is bridged waits for it", c do
      SystemsRuntime.put_env(:comma_web, :linear_agent_bridge_wait_ms, 10_000)

      prompt = prompted_payload("sess-early", "act-early", "Start with the mobile flow")
      assert webhook_request(prompt) |> expect_json(200) == %{"ok" => true}
      start_session!("sess-early")

      {:ok, agent_session} = Comma.LinearInstallations.get_agent_session("sess-early")

      assert eventually(fn ->
               Enum.any?(
                 provider_messages(c, agent_session.conversation_id),
                 &(SalixIM.ConversationMessage.text_content(&1["content"]) ==
                     "Start with the mobile flow")
               )
             end)

      refute_receive {:linear_activity, "sess-early", %{"type" => "error"}, _}
    end

    test "an issue already in progress stays where it is when a Task starts", c do
      SystemsRuntime.put_env(:comma_web, :linear_issue_state_type, "started")
      on_exit(fn -> SystemsRuntime.delete_env(:comma_web, :linear_issue_state_type) end)
      start_session!("sess-stay")
      _task_id = start_task!(c.workspace, "sess-stay")
      refute_receive {:linear_issue_update, "issue-sess-stay", _}
    end

    test "a stop signal ends the Task and answers once without an error", c do
      start_session!("sess-stop")

      # No Task yet: the stop says so and the chat stays.
      early =
        prompted_payload("sess-stop", "act-stop-early", "Stop")
        |> put_in(["agentActivity", "signal"], "stop")

      assert webhook_request(early) |> expect_json(200) == %{"ok" => true}

      assert_receive {:linear_activity, "sess-stop", %{"type" => "response", "body" => body}, _},
                     5_000

      assert body =~ "no Task running"

      task_id = start_task!(c.workspace, "sess-stop")
      group_id = c.workspace["default_group_id"]

      stop =
        prompted_payload("sess-stop", "act-stop", "Stop")
        |> put_in(["agentActivity", "signal"], "stop")

      assert webhook_request(stop) |> expect_json(200) == %{"ok" => true}

      assert_receive {:linear_activity, "sess-stop", %{"type" => "response", "body" => body}, _},
                     5_000

      assert body =~ "stopped working"

      {:ok, task} = SalixIM.Conversations.get_group_conversation(group_id, task_id)
      assert task["status"] == "cancelled"
      assert get_in(task, ["manual_status_change", "user_id"]) == c.user["id"]
      refute_receive {:linear_activity, "sess-stop", %{"type" => "error"}, _}
    end

    test "an issue marked done in Linear ends the running Task and answers once", c do
      start_session!("sess-done")
      task_id = start_task!(c.workspace, "sess-done")
      group_id = c.workspace["default_group_id"]

      done =
        issue_payload(
          "sess-done",
          "update",
          %{"state" => %{"type" => "completed"}},
          %{"stateId" => "st_progress"}
        )

      assert webhook_request(done) |> expect_json(200) == %{"ok" => true}

      assert_receive {:linear_activity, "sess-done", %{"type" => "response", "body" => body}, _},
                     5_000

      assert body =~ "marked done"

      {:ok, task} = SalixIM.Conversations.get_group_conversation(group_id, task_id)
      assert task["status"] == "cancelled"
      assert get_in(task, ["manual_status_change", "user_id"]) == c.user["id"]
      assert [notice] = provider_messages(c, task_id)

      assert SalixIM.ConversationMessage.text_content(notice["content"]) =~
               "marked done in Linear"

      refute_receive {:linear_activity, "sess-done", %{"type" => "error"}, _}

      # Linear redelivers: the Task is already cancelled, nothing is said twice.
      assert webhook_request(done) |> expect_json(200) == %{"ok" => true}
      refute_receive {:linear_activity, "sess-done", _, _}
      assert [_notice] = provider_messages(c, task_id)
    end

    test "an issue deleted or assigned away in Linear ends the running Task", c do
      start_session!("sess-deleted")
      deleted_task = start_task!(c.workspace, "sess-deleted")
      group_id = c.workspace["default_group_id"]

      assert webhook_request(issue_payload("sess-deleted", "remove", %{})) |> expect_json(200) ==
               %{"ok" => true}

      assert eventually(fn ->
               match?(
                 {:ok, %{"status" => "cancelled"}},
                 SalixIM.Conversations.get_group_conversation(group_id, deleted_task)
               )
             end)

      assert [notice] = provider_messages(c, deleted_task)
      assert SalixIM.ConversationMessage.text_content(notice["content"]) =~ "deleted"
      # The session went with the issue: nothing is posted there.
      refute_receive {:linear_activity, "sess-deleted", _, _}

      start_session!("sess-unassigned")
      unassigned_task = start_task!(c.workspace, "sess-unassigned")

      taken =
        issue_payload(
          "sess-unassigned",
          "update",
          %{"state" => %{"type" => "started"}, "assigneeId" => "linear-user-yue"},
          %{"delegateId" => @app_user_id}
        )

      assert webhook_request(taken) |> expect_json(200) == %{"ok" => true}

      assert_receive {:linear_activity, "sess-unassigned",
                      %{"type" => "response", "body" => body}, _},
                     5_000

      assert body =~ "assigned away"
      {:ok, task} = SalixIM.Conversations.get_group_conversation(group_id, unassigned_task)
      assert task["status"] == "cancelled"
    end

    test "an issue change leaves a Task in review and a working Task on other changes alone",
         c do
      start_session!("sess-review")
      task_id = start_task!(c.workspace, "sess-review")
      group_id = c.workspace["default_group_id"]
      worker_send(c, task_id, "Done: the redirect keeps the return path.")
      assert_receive {:linear_activity, "sess-review", %{"type" => "thought"}, _}, 5_000
      set_task(c, task_id, %{"status" => "ready_for_review"})
      assert_receive {:linear_activity, "sess-review", %{"type" => "response"}, _}, 5_000

      done =
        issue_payload(
          "sess-review",
          "update",
          %{"state" => %{"type" => "completed"}},
          %{"stateId" => "st_progress"}
        )

      assert webhook_request(done) |> expect_json(200) == %{"ok" => true}
      refute_receive {:linear_activity, "sess-review", _, _}
      {:ok, task} = SalixIM.Conversations.get_group_conversation(group_id, task_id)
      assert task["status"] == "ready_for_review"
      assert provider_messages(c, task_id) == []

      # Comma works on an issue that was already done: editing it ends nothing.
      start_session!("sess-edit")
      working = start_task!(c.workspace, "sess-edit")

      edited =
        issue_payload(
          "sess-edit",
          "update",
          %{"state" => %{"type" => "completed"}, "delegateId" => @app_user_id, "title" => "New"},
          %{"title" => "Old"}
        )

      assert webhook_request(edited) |> expect_json(200) == %{"ok" => true}
      refute_receive {:linear_activity, "sess-edit", _, _}
      {:ok, task} = SalixIM.Conversations.get_group_conversation(group_id, working)
      assert task["status"] == "active"
    end

    test "a stop after the Task ended says so and changes nothing", c do
      start_session!("sess-late")
      task_id = start_task!(c.workspace, "sess-late")
      set_task(c, task_id, %{"status" => "failed"})
      assert_receive {:linear_activity, "sess-late", %{"type" => "error"}, _}, 5_000

      stop =
        prompted_payload("sess-late", "act-late", "Stop")
        |> put_in(["agentActivity", "signal"], "stop")

      assert webhook_request(stop) |> expect_json(200) == %{"ok" => true}

      assert_receive {:linear_activity, "sess-late", %{"type" => "response", "body" => body}, _},
                     5_000

      assert body =~ "already ended as failed"

      # A redelivery of that stop answers nothing more.
      assert webhook_request(stop) |> expect_json(200) == %{"ok" => true}
      refute_receive {:linear_activity, "sess-late", _, _}

      {:ok, task} =
        SalixIM.Conversations.get_group_conversation(c.workspace["default_group_id"], task_id)

      assert task["status"] == "failed"
    end

    test "the in review policy moves an open issue and leaves a closed one", c do
      assert %{"completion_state_policy" => "in_review"} =
               api_request(c.session, :patch, linear_path(c.workspace), %{
                 "completion_state_policy" => "in_review"
               })
               |> expect_json(200)

      start_session!("sess-review")
      review_task = start_task!(c.workspace, "sess-review")

      assert_receive {:linear_issue_update, "issue-sess-review", %{"stateId" => "st_progress"}},
                     5_000

      worker_send(c, review_task, "Ready for review.")
      set_task(c, review_task, %{"status" => "ready_for_review"})
      assert_receive {:linear_activity, "sess-review", %{"type" => "response"}, _}, 5_000

      assert_receive {:linear_issue_update, "issue-sess-review", %{"stateId" => "st_review"}},
                     5_000

      # Someone already closed the issue in Linear: the policy leaves it.
      SystemsRuntime.put_env(:comma_web, :linear_issue_state_type, "completed")
      on_exit(fn -> SystemsRuntime.delete_env(:comma_web, :linear_issue_state_type) end)
      start_session!("sess-closed")
      closed_task = start_task!(c.workspace, "sess-closed")
      worker_send(c, closed_task, "Done already.")
      set_task(c, closed_task, %{"status" => "ready_for_review"})
      assert_receive {:linear_activity, "sess-closed", %{"type" => "response"}, _}, 5_000
      refute_receive {:linear_issue_update, "issue-sess-closed", _}
    end

    test "completion moves the issue by the member's policy and links pull requests", c do
      start_session!("sess-done")
      task_id = start_task!(c.workspace, "sess-done")

      assert_receive {:linear_issue_update, "issue-sess-done", %{"stateId" => "st_progress"}},
                     5_000

      assert %{"completion_state_policy" => "done"} =
               api_request(c.session, :patch, linear_path(c.workspace), %{
                 "completion_state_policy" => "done"
               })
               |> expect_json(200)

      worker_send(c, task_id, "Opened https://github.com/acme/app/pull/42 for review.")

      assert_receive {:linear_activity, "sess-done", %{"type" => "thought"}, _}, 5_000

      assert_receive {:linear_session_update, "sess-done",
                      %{
                        "addedExternalUrls" => [%{"url" => "https://github.com/acme/app/pull/42"}]
                      }},
                     5_000

      set_task(c, task_id, %{"status" => "ready_for_review"})
      assert_receive {:linear_activity, "sess-done", %{"type" => "response"}, _}, 5_000
      assert_receive {:linear_issue_update, "issue-sess-done", %{"stateId" => "st_done"}}, 5_000
    end

    test "a revoked installation stops accepting sessions", c do
      revoked = %{
        "type" => "OAuthApp",
        "action" => "revoked",
        "organizationId" => @organization_id,
        "oauthClientId" => "linear-client",
        "webhookTimestamp" => SystemsClock.system_time(:millisecond),
        "webhookId" => "wh-revoked"
      }

      # A person revoking their own authorization reports the same event; the
      # app's token still works, so the installation stays.
      assert webhook_request(revoked) |> expect_json(200) == %{"ok" => true}
      start_session!("sess-still-installed")
      state = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert state["installation"]["revoked"] == false

      # Linear unreachable while checking: the installation is kept, not retired.
      SystemsRuntime.put_env(:comma_web, :linear_revoked_check_retry_ms, 10)
      SystemsRuntime.put_env(:comma_web, :linear_app_token_dead, :unreachable)
      assert webhook_request(revoked) |> expect_json(200) == %{"ok" => true}
      SystemsRuntime.Proc.sleep(200)
      SystemsRuntime.delete_env(:comma_web, :linear_app_token_dead)
      start_session!("sess-still-installed-2")
      state = api_request(c.session, :get, linear_path(c.workspace)) |> expect_json(200)
      assert state["installation"]["revoked"] == false

      SystemsRuntime.put_env(:comma_web, :linear_app_token_dead, true)
      assert webhook_request(revoked) |> expect_json(200) == %{"ok" => true}

      assert eventually(fn ->
               api_request(c.session, :get, linear_path(c.workspace))
               |> expect_json(200)
               |> get_in(["installation", "revoked"])
             end)

      assert webhook_request(created_payload("sess-after-revoke")) |> expect_json(200) ==
               %{"ok" => true, "ignored" => true}

      refute_receive {:linear_activity, "sess-after-revoke", _, _}
    end
  end

  # ---- helpers ----

  # Connects the person `yue`, installing Comma into the organization when needed.
  defp install!(c) do
    conn = connect(c.session, c.workspace, "user-code-yue")
    assert conn.status == 200, conn.resp_body
    :ok
  end

  # Connects as the person the code names; follows the app installation when
  # the callback goes on to it. Returns the final callback.
  defp connect(session, workspace, code) do
    attempt =
      api_request(session, :post, linear_path(workspace) <> "/connect", %{})
      |> expect_json(201)

    conn = callback(state_of(attempt["authorization_url"]), code)
    assert_receive {:linear_token_exchange, %{"code" => ^code}}

    case conn.status do
      302 ->
        [location] = get_resp_header(conn, "location")
        conn = callback(state_of(location), "app-code")
        assert_receive {:linear_token_exchange, %{"code" => "app-code"}}
        conn

      _ ->
        conn
    end
  end

  defp state_of(url) do
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
  end

  defp other_person!(name) do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "#{name}-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace =
      user
      |> create_ready_workspace!(%{"name" => "#{name} Team"})
      |> CommaWeb.TestWorkers.with_default_worker!()

    {:ok, session} = Comma.Accounts.create_session(user["id"])
    %{user: user, workspace: workspace, session: session}
  end

  defp start_session!(session_id, creator \\ "linear-user-yue") do
    assert webhook_request(created_payload(session_id, creator)) |> expect_json(200) ==
             %{"ok" => true}

    assert_receive {:linear_activity, ^session_id, %{"type" => "thought"}, _}, 5_000
    assert_receive {:linear_session_update, ^session_id, _}, 5_000
    :ok
  end

  defp created_payload(session_id, creator \\ "linear-user-yue") do
    %{
      "type" => "AgentSessionEvent",
      "action" => "created",
      "organizationId" => @organization_id,
      "appUserId" => @app_user_id,
      "agentSession" => %{
        "id" => session_id,
        "creatorId" => creator,
        "creator" => %{"id" => creator, "name" => creator},
        "issue" => %{
          "id" => "issue-" <> session_id,
          "identifier" => "ENG-1",
          "title" => "Fix login redirect",
          "url" => "https://linear.app/acme/issue/ENG-1/fix-login-redirect"
        }
      },
      "promptContext" => "<issue identifier=\"ENG-1\"><title>Fix login redirect</title></issue>",
      "webhookTimestamp" => SystemsClock.system_time(:millisecond),
      "webhookId" => "wh-" <> session_id
    }
  end

  defp prompted_payload(session_id, activity_id, body) do
    %{
      "type" => "AgentSessionEvent",
      "action" => "prompted",
      "organizationId" => @organization_id,
      "appUserId" => @app_user_id,
      "agentSession" => %{"id" => session_id},
      "agentActivity" => %{
        "id" => activity_id,
        "content" => %{"type" => "prompt", "body" => body}
      },
      "webhookTimestamp" => SystemsClock.system_time(:millisecond),
      "webhookId" => "wh-" <> activity_id
    }
  end

  # An Issue webhook of the session's issue. Linear sends no `appUserId` here.
  defp issue_payload(session_id, action, data, updated_from \\ %{}) do
    %{
      "type" => "Issue",
      "action" => action,
      "organizationId" => @organization_id,
      "data" => Map.merge(%{"id" => "issue-" <> session_id, "identifier" => "ENG-1"}, data),
      "updatedFrom" => updated_from,
      "webhookTimestamp" => SystemsClock.system_time(:millisecond),
      "webhookId" => "wh-issue-" <> session_id <> "-" <> action
    }
  end

  defp router_send(c, conversation_id, text) do
    assert {:ok, _} =
             SalixIM.Provider.call_api(
               c.workspace["router_agent_id"],
               "internal",
               "internal.send_message",
               %{
                 "connect_id" => "internal",
                 "params" => %{"conversation_id" => conversation_id, "content" => text}
               }
             )
  end

  # The Task the Router creates while answering the session's chat: created
  # the way the Router's tool does, with the chat as its parent. Returns the
  # Task's conversation id once the session is bound to it.
  defp start_task!(workspace, session_id) do
    task_id = create_task!(workspace, session_id, "task")

    assert eventually(fn ->
             match?(
               {:ok, %{task_conversation_id: ^task_id}},
               Comma.LinearInstallations.get_agent_session(session_id)
             )
           end)

    task_id
  end

  defp create_task!(workspace, session_id, request) do
    {:ok, agent_session} = Comma.LinearInstallations.get_agent_session(session_id)
    group_id = workspace["default_group_id"]
    router = workspace["router_agent_id"]

    assert {:ok, %{"conversation_id" => task_id}} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               router,
               workspace["default_worker_agent_id"],
               %{
                 "client_request_id" => "linear-test-#{request}-" <> session_id,
                 "title" => "ENG-1: Fix login redirect",
                 "content" => "Fix the login redirect bug described in ENG-1 (#{request}).",
                 "source_refs" => %{
                   "origin_agent_id" => router,
                   "parent_conversation_id" => agent_session.conversation_id
                 }
               }
             )

    task_id
  end

  defp grant_credits!(workspace) do
    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: workspace["billing_account_id"],
        credits: 100,
        valid_from: ~U[2026-06-17 00:00:00Z],
        expires_at: DateTime.add(SystemsClock.utc_now(), 30, :day),
        source_type: "manual_contract",
        source_id: "linear-chat-test:#{workspace["id"]}",
        source_event_id: "linear-chat-test:#{workspace["id"]}",
        idempotency_key: "linear-chat-test:#{workspace["id"]}"
      })

    :ok
  end

  defp provider_messages(c, conversation_id) do
    {:ok, %{"messages" => messages}} =
      SalixIM.Conversations.list_group_conversation_message_page(
        c.workspace["default_group_id"],
        conversation_id
      )

    Enum.filter(messages, &(&1["actor_type"] == "provider_user"))
  end

  defp worker_send(c, conversation_id, text) do
    assert {:ok, _} =
             SalixIM.Provider.call_api(
               c.workspace["default_worker_agent_id"],
               "internal",
               "internal.send_message",
               %{
                 "connect_id" => "internal",
                 "params" => %{"conversation_id" => conversation_id, "content" => text}
               }
             )
  end

  defp set_task(c, id, changes) do
    assert {:ok, _} =
             SalixIM.Provider.call_api(
               c.workspace["router_agent_id"],
               "internal",
               "internal.update_conversation",
               %{"connect_id" => "internal", "params" => Map.put(changes, "conversation_id", id)}
             )
  end

  defp webhook_request(payload) do
    raw = Jason.encode!(payload)
    signature = :crypto.mac(:hmac, :sha256, @webhook_secret, raw) |> Base.encode16(case: :lower)

    :post
    |> conn(webhook_path(), raw)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("linear-signature", signature)
    |> call()
  end

  defp callback(state, code) do
    :get
    |> conn(
      "/v1/comma/integrations/linear/connect/callback?" <>
        URI.encode_query(%{"code" => code, "state" => state})
    )
    |> call()
  end

  defp webhook_path, do: "/v1/comma/integrations/linear/webhook"

  defp linear_path(workspace),
    do: "/v1/comma/workspaces/#{workspace["id"]}/integrations/linear"

  defp api_request(session, method, path, body \\ nil) do
    conn = if is_nil(body), do: conn(method, path), else: json_conn(method, path, body)

    conn
    |> put_req_header("authorization", "Bearer #{session["token"]}")
    |> call()
  end

  defp json_conn(method, path, body) do
    method
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp call(conn), do: CommaWeb.Router.call(conn, @router_opts)

  defp expect_json(conn, status) do
    assert conn.status == status, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts <= 1 -> false
      true -> SystemsRuntime.Proc.sleep(100) && eventually(fun, attempts - 1)
    end
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end

defmodule CommaWeb.LinearTestActivities do
  @moduledoc false
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(session_id, content),
    do:
      Agent.update(
        __MODULE__,
        &Map.update(&1, session_id, [content], fn list -> list ++ [content] end)
      )

  def list(session_id), do: Agent.get(__MODULE__, &Map.get(&1, session_id, []))
end
