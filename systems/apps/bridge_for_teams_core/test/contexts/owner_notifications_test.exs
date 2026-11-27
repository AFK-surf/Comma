defmodule BridgeForTeams.OwnerNotificationsTest do
  @moduledoc """
  Owner notifications: a Salix alert for a swarm becomes one email a day per
  subject, sent from a fixed template to the swarm's current owners through
  the teams Postmark server (a Bandit stand-in for Postmark).
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Memberships, Orgs, OwnerNotifications, Projects}
  alias BridgeForTeams.OwnerNotifications.Worker
  alias BridgeForTeams.Schema.OwnerNotification

  defmodule MockPostmark do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def requests, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", request_path: "/email"} = conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      token = conn |> get_req_header("x-postmark-server-token") |> List.first()
      Agent.update(__MODULE__, &[%{body: Jason.decode!(raw), token: token} | &1])

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"ErrorCode" => 0, "MessageID" => "m-1"}))
    end
  end

  @env [
    {:salix_store, :postmark_base_url},
    {:bridge_for_teams_core, :teams_postmark_server_token},
    {:bridge_for_teams_core, :teams_from_email},
    {:bridge_for_teams_web, :public_base_url}
  ]

  setup do
    start_supervised!(MockPostmark)

    port =
      Enum.find_value(1..10, fn _ ->
        p = 40000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20000)

        case start_supervised({Bandit, plug: MockPostmark, port: p}, id: {:bandit, p}) do
          {:ok, _pid} -> p
          {:error, _} -> nil
        end
      end)

    saved = Enum.map(@env, fn {app, key} -> {app, key, SystemsRuntime.get_env(app, key)} end)

    on_exit(fn ->
      Enum.each(Enum.reverse(saved), fn
        {app, key, nil} -> SystemsRuntime.delete_env(app, key)
        {app, key, value} -> SystemsRuntime.put_env(app, key, value)
      end)
    end)

    SystemsRuntime.put_env(:salix_store, :postmark_base_url, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:bridge_for_teams_core, :teams_postmark_server_token, "teams-token")
    SystemsRuntime.put_env(:bridge_for_teams_core, :teams_from_email, "teams@comma.test")
    SystemsRuntime.put_env(:bridge_for_teams_web, :public_base_url, "https://teams.comma.test")

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    {:ok, admin} = Accounts.create_user(%{email: "admin@acme.test"})
    {:ok, _} = Memberships.put_org_member(org.id, admin.id, "admin")
    {:ok, member} = Accounts.create_user(%{email: "member@acme.test"})
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, creator} = Accounts.create_user(%{email: "creator@acme.test"})

    {:ok, project} =
      Projects.create_project(org.id, %{name: "Research", slug: "research"},
        creator_user_id: creator.id
      )

    %{org: org, project: project}
  end

  test "an alert emails the swarm's owners once a day from the template", %{project: project} do
    facts = %{"agent_id" => "agt1_x", "category" => "provider", "status" => 503}

    :ok = OwnerNotifications.owner_alert(project.salix_group_id, "model_failing", "agt1_x", facts)
    :ok = OwnerNotifications.owner_alert(project.salix_group_id, "model_failing", "agt1_x", facts)

    assert {:ok, 1} = Worker.run_once()

    assert [%{body: body, token: "teams-token"}] = MockPostmark.requests()
    assert body["From"] == "teams@comma.test"
    assert body["To"] == "admin@acme.test,creator@acme.test"
    assert body["Subject"] =~ "Research"
    assert body["TextBody"] =~ "HTTP 503"
    assert body["TextBody"] =~ "https://teams.comma.test/orgs/acme/projects/#{project.id}/agents"

    assert [%OwnerNotification{status: "sent"}] = Repo.all(OwnerNotification)
    assert {:ok, 0} = Worker.run_once()
  end

  test "a reconnect alert names the connection and links to its page", %{project: project} do
    :ok =
      OwnerNotifications.owner_alert(
        project.salix_group_id,
        "reauthorization_required",
        "google/work",
        %{
          "provider" => "google",
          "alias" => "work"
        }
      )

    assert {:ok, 1} = Worker.run_once()
    assert [%{body: body}] = MockPostmark.requests()
    assert body["Subject"] =~ "reconnect Google"
    assert body["TextBody"] =~ "/projects/#{project.id}/connections"
  end

  test "alerts for groups that are not a live swarm, or of unknown kinds, are ignored", %{
    project: project
  } do
    :ok = OwnerNotifications.owner_alert("grp1_1_2", "model_failing", "agt1_x", %{})
    :ok = OwnerNotifications.owner_alert(project.salix_group_id, "free_text", "x", %{})
    {:ok, _} = Projects.archive_project(project)
    :ok = OwnerNotifications.owner_alert(project.salix_group_id, "model_failing", "agt1_x", %{})

    assert Repo.all(OwnerNotification) == []
  end

  test "nothing is sent while the teams sender is not configured", %{project: project} do
    SystemsRuntime.put_env(:bridge_for_teams_core, :teams_postmark_server_token, "")
    :ok = OwnerNotifications.owner_alert(project.salix_group_id, "model_failing", "agt1_x", %{})

    assert {:ok, 0} = Worker.run_once()
    assert MockPostmark.requests() == []
    assert [%OwnerNotification{status: "pending"}] = Repo.all(OwnerNotification)
  end
end
