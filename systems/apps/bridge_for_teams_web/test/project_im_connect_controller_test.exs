defmodule BridgeForTeamsWeb.ProjectIMConnectControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.CLI.Login, as: CLILogin
  alias BridgeForTeams.{Agents, Memberships}
  alias BridgeForTeamsWeb.DashboardEndpoint

  defmodule SlackConnectSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def child_spec(_opts) do
      %{id: __MODULE__, start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__]]}}
    end

    def list_group_im_connects(group_id, provider) do
      connects =
        Agent.get(__MODULE__, fn connects ->
          connects
          |> Enum.filter(&(provider in [nil, &1["provider"]]))
          |> Enum.map(&Map.put_new(&1, "group_id", group_id))
        end)

      {:ok, connects}
    end

    def create_slack_im_connect(_tenant_id, group_id, attrs) do
      connect =
        attrs
        |> Map.take(~w(app_id client_id app_name inbound_agent_id))
        |> Map.merge(%{
          "connect_id" => "conn_slack_1",
          "provider" => "slack",
          "group_id" => group_id,
          "oauth_url" => "https://slack.example.test/oauth?connect_id=conn_slack_1",
          "bot_user_id" => "UWORKERBOT",
          "bot_username" => "project_worker_bot",
          "client_secret_configured" => Map.has_key?(attrs, "client_secret"),
          "signing_secret_configured" => Map.has_key?(attrs, "signing_secret")
        })

      Agent.update(__MODULE__, fn connects -> [connect | connects] end)
      {:ok, connect}
    end

    def update_slack_im_connect(_tenant_id, group_id, connect_id, attrs) do
      updated =
        Agent.get_and_update(__MODULE__, fn connects ->
          connect =
            connects
            |> Enum.find(&(&1["connect_id"] == connect_id))
            |> case do
              nil ->
                nil

              existing ->
                existing
                |> Map.merge(Map.take(attrs, ~w(app_id client_id app_name inbound_agent_id)))
                |> Map.put("group_id", group_id)
                |> maybe_put_configured("client_secret_configured", attrs, "client_secret")
                |> maybe_put_configured("signing_secret_configured", attrs, "signing_secret")
            end

          if connect do
            {connect,
             Enum.map(connects, &if(&1["connect_id"] == connect_id, do: connect, else: &1))}
          else
            {nil, connects}
          end
        end)

      if updated, do: {:ok, updated}, else: {:error, :not_found}
    end

    def disable_im_connect(_tenant_id, _group_id, connect_id) do
      update_connect(connect_id, &Map.put(&1, "disabled_at", "2026-06-26T00:00:00Z"))
    end

    def enable_im_connect(_tenant_id, _group_id, connect_id) do
      update_connect(connect_id, &Map.put(&1, "disabled_at", nil))
    end

    def delete_im_connect(_tenant_id, _group_id, connect_id) do
      Agent.update(__MODULE__, fn connects ->
        Enum.reject(connects, &(&1["connect_id"] == connect_id))
      end)

      :ok
    end

    defp update_connect(connect_id, fun) do
      found? =
        Agent.get_and_update(__MODULE__, fn connects ->
          found? = Enum.any?(connects, &(&1["connect_id"] == connect_id))

          {found?,
           Enum.map(connects, &if(&1["connect_id"] == connect_id, do: fun.(&1), else: &1))}
        end)

      if found?, do: :ok, else: {:error, :not_found}
    end

    defp maybe_put_configured(connect, field, attrs, credential_field) do
      if Map.has_key?(attrs, credential_field) do
        Map.put(connect, field, true)
      else
        connect
      end
    end
  end

  defmodule SlackConnectUnavailableClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:error, :unavailable}
  end

  defmodule SlackConnectAppInUseClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}

    def create_slack_im_connect(_tenant_id, _group_id, _attrs),
      do: {:error, {:bad_request, "slack app_id is already used by another connect"}}
  end

  setup do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    start_supervised!(SlackConnectSalixClient)
    Application.put_env(:bridge_for_teams_core, :salix_client, SlackConnectSalixClient)

    %{user: user, org: org} = org_with_owner_fixture(org: %{slug: "acme", name: "Acme"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Support",
        "slug" => "support"
      })

    [router] = Agents.list_agents(project.id)
    {:ok, %{token: token, session: session}} = Sessions.create(user, device: "bft-cli")
    {:ok, _grants} = CLILogin.grant_cli_session_orgs(session, [org.id], user.id)

    %{
      user: user,
      org: org,
      project: project,
      inbound_agent_id: router.salix_agent_id,
      token: token
    }
  end

  test "project Slack connect API uses ProjectIMConnects lifecycle and redacts secrets", %{
    org: org,
    project: project,
    inbound_agent_id: inbound_agent_id,
    token: token
  } do
    base = project_slack_path(org.slug, project.slug)

    initial = api(:get, base, token) |> json_data()
    assert initial["mode"] == "project_im_connects_list"
    assert initial["provider"] == "slack"
    assert initial["connects"] == []

    create = api(:post, base, token, slack_create_body(inbound_agent_id))
    assert create.status == 200
    refute create.resp_body =~ "client-secret-value"
    refute create.resp_body =~ "signing-secret-value"
    created = json_data(create)

    assert created["mode"] == "project_im_connect_create"
    assert created["connect"]["connect_id"] == "conn_slack_1"
    assert created["connect"]["app_id"] == "A123"
    assert created["connect"]["inbound_agent_id"] == inbound_agent_id
    assert created["connect"]["bot_user_id"] == "UWORKERBOT"
    assert created["connect"]["bot_username"] == "project_worker_bot"
    assert created["connect"]["client_secret_configured"] == true
    assert created["connect"]["signing_secret_configured"] == true
    assert created["connect"]["install_status"] == "pending_oauth"
    assert created["oauth_url"] =~ "conn_slack_1"
    refute Map.has_key?(created["connect"], "client_secret")
    refute Map.has_key?(created["connect"], "signing_secret")

    disabled = api(:post, base <> "/conn_slack_1/disable", token, %{}) |> json_data()
    assert disabled["mode"] == "project_im_connect_disable"
    assert disabled["connect"]["disabled_at"]
    assert disabled["connect"]["install_status"] == "disabled"

    enabled = api(:post, base <> "/conn_slack_1/enable", token, %{}) |> json_data()
    assert enabled["mode"] == "project_im_connect_enable"
    assert is_nil(enabled["connect"]["disabled_at"])
    assert enabled["connect"]["install_status"] == "pending_oauth"

    deleted = api(:delete, base <> "/conn_slack_1", token) |> json_data()
    assert deleted["mode"] == "project_im_connect_delete"
    assert deleted["connect_id"] == "conn_slack_1"
    assert deleted["connects"] == []
  end

  test "project Slack connect API updates inbound agent without resubmitting credentials", %{
    org: org,
    project: project,
    inbound_agent_id: inbound_agent_id,
    token: token
  } do
    {:ok, worker} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "worker",
        "role" => "worker"
      })

    base = project_slack_path(org.slug, project.slug)

    created = api(:post, base, token, slack_create_body(inbound_agent_id)) |> json_data()
    assert created["connect"]["client_secret_configured"] == true
    assert created["connect"]["signing_secret_configured"] == true

    updated =
      api(:patch, base <> "/conn_slack_1", token, %{"inbound_agent_id" => worker.salix_agent_id})
      |> json_data()

    assert updated["mode"] == "project_im_connect_update"
    assert updated["connect"]["connect_id"] == "conn_slack_1"
    assert updated["connect"]["inbound_agent_id"] == worker.salix_agent_id
    assert updated["connect"]["app_id"] == "A123"
    assert updated["connect"]["client_secret_configured"] == true
    assert updated["connect"]["signing_secret_configured"] == true
    refute updated["connect"]["client_secret"]
    refute updated["connect"]["signing_secret"]
  end

  test "project Slack connect API enforces project read and write permissions", %{
    org: org,
    project: project,
    inbound_agent_id: inbound_agent_id
  } do
    member = user_fixture(email: "slack-connect-member@example.com")
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _project_membership} = Memberships.put_project_member(project.id, member.id, "user")

    {:ok, %{token: member_token, session: member_session}} =
      Sessions.create(member, device: "bft-cli")

    {:ok, _grants} = CLILogin.grant_cli_session_orgs(member_session, [org.id], member.id)

    base = project_slack_path(org.slug, project.slug)

    assert api(:get, base, member_token).status == 200

    create = api(:post, base, member_token, slack_create_body(inbound_agent_id))
    assert create.status == 403
    assert %{"ok" => false, "error" => %{"code" => "forbidden"}} = Jason.decode!(create.resp_body)
  end

  test "project Slack connect API maps core validation and backend errors", %{
    org: org,
    project: project,
    token: token,
    inbound_agent_id: inbound_agent_id
  } do
    base = project_slack_path(org.slug, project.slug)

    missing =
      api(:post, base, token, Map.delete(slack_create_body(inbound_agent_id), "client_secret"))

    assert missing.status == 400

    assert %{"ok" => false, "error" => %{"code" => "missing_credentials"}} =
             Jason.decode!(missing.resp_body)

    invalid_agent = api(:post, base, token, slack_create_body("agent_missing"))
    assert invalid_agent.status == 400

    assert %{"ok" => false, "error" => %{"code" => "invalid_inbound_agent"}} =
             Jason.decode!(invalid_agent.resp_body)

    not_found = api(:post, base <> "/conn_missing/disable", token, %{})
    assert not_found.status == 404

    assert %{"ok" => false, "error" => %{"code" => "connect_not_found"}} =
             Jason.decode!(not_found.resp_body)

    Application.put_env(:bridge_for_teams_core, :salix_client, SlackConnectUnavailableClient)
    unavailable = api(:get, base, token)
    assert unavailable.status == 503

    assert %{"ok" => false, "error" => %{"code" => "unavailable"}} =
             Jason.decode!(unavailable.resp_body)

    Application.put_env(:bridge_for_teams_core, :salix_client, SlackConnectAppInUseClient)
    app_in_use = api(:post, base, token, slack_create_body(inbound_agent_id))
    assert app_in_use.status == 409

    assert %{"ok" => false, "error" => %{"code" => "provider_app_in_use"}} =
             Jason.decode!(app_in_use.resp_body)
  end

  defp project_slack_path(org, project) do
    "/v1/orgs/#{org}/projects/#{project}/im/slack/connects"
  end

  defp slack_create_body(inbound_agent_id) do
    %{
      "app_id" => "A123",
      "client_id" => "123.abc",
      "client_secret" => "client-secret-value",
      "signing_secret" => "signing-secret-value",
      "app_name" => "Project Worker",
      "inbound_agent_id" => inbound_agent_id
    }
  end

  defp api(method, path, token, body \\ nil) do
    body = if is_nil(body), do: nil, else: Jason.encode!(body)

    method
    |> build_conn(path, body)
    |> put_req_header("accept", "application/json")
    |> maybe_put_json_content_type(body)
    |> put_req_header("authorization", "Bearer #{token}")
    |> DashboardEndpoint.call([])
  end

  defp maybe_put_json_content_type(conn, nil), do: conn

  defp maybe_put_json_content_type(conn, _body),
    do: put_req_header(conn, "content-type", "application/json")

  defp json_data(conn) do
    assert conn.status == 200
    assert %{"ok" => true, "data" => data} = Jason.decode!(conn.resp_body)
    data
  end
end
