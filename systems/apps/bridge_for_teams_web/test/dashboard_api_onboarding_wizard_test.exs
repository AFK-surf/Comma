defmodule BridgeForTeamsWeb.DashboardAPIOnboardingWizardTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The first-run onboarding wizard (`/onboarding`, React) and its API: the
  first-run gate with its exempt pages, the wizard pages, the swarm created
  for a user who owns none, each step's write and validation, the Composio
  connect with its swarm-owner rule and denied audit, finishing, skipping,
  restarting, resuming, CSRF protection, and query counts that do not grow
  with the organization.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  import Ecto.Query

  alias BridgeForTeams.{Memberships, Observability, Projects, Repo, UserOnboardings}
  alias BridgeForTeams.Schema.UserOnboarding
  alias BridgeForTeams.TestSupport.CanonicalAgentClient

  @api "/dashboard/api/v1/onboarding"

  defmodule UnconfiguredComposioClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc "An org without Composio and without IM connects."

    def get_composio_settings(_tenant_id),
      do: %{
        "enabled" => false,
        "api_key_configured" => false,
        "base_url" => "",
        "source" => "none"
      }

    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
  end

  defmodule ComposioClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc "An org with Composio configured, one gmail account already connected."

    def get_composio_settings(_tenant_id),
      do: %{
        "enabled" => true,
        "api_key_configured" => true,
        "base_url" => "",
        "source" => "tenant"
      }

    def list_composio_connected_accounts(_tenant_id, group_id) do
      {:ok,
       [
         %{
           "id" => "ca_gmail",
           "user_id" => group_id,
           "toolkit" => %{"slug" => "gmail"},
           "status" => "ACTIVE"
         }
       ]}
    end

    def create_composio_connect_link(_tenant_id, _group_id, toolkit, attrs) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :onboarding_test_pid) do
        SystemsRuntime.Proc.send(pid, {:connect_link_requested, toolkit, attrs})
      end

      {:ok,
       %{
         "redirect_url" => "https://connect.composio.dev/link/lk_onboarding",
         "connected_account_id" => "ca_new"
       }}
    end

    def list_group_im_connects(_group_id, _provider),
      do: {:ok, [%{"provider" => "feishu", "connect_id" => "fc_1", "status" => "active"}]}
  end

  defmodule UnreachableComposioClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc "Composio is configured but its accounts cannot be read."

    def get_composio_settings(_tenant_id),
      do: %{
        "enabled" => true,
        "api_key_configured" => true,
        "base_url" => "",
        "source" => "tenant"
      }

    def list_composio_connected_accounts(_tenant_id, _group_id), do: {:error, :unavailable}
    def list_group_im_connects(_group_id, _provider), do: {:ok, []}
  end

  defp log_in_fresh_owner(conn) do
    %{user: user, org: org} = org_with_owner_fixture()
    %{conn: log_in_user(conn, user, onboarded: false), user: user, org: org}
  end

  defp with_salix_client(mod) do
    prev = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, mod)
    BridgeForTeams.TestConversationStore.reset(Module.concat(mod, Store))

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :onboarding_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      if prev do
        SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
      end

      SystemsRuntime.delete_env(:bridge_for_teams_core, :onboarding_test_pid)
    end)
  end

  defp provisioned_swarm(org, user) do
    {:ok, project} =
      CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "P", "slug" => "p-#{SystemsRuntime.Proc.unique_integer([:positive])}"},
        creator_user_id: user.id
      )

    project
  end

  describe "the first-run gate" do
    test "sends a fresh user from the dashboard to /onboarding", %{conn: conn} do
      %{conn: conn, org: org} = log_in_fresh_owner(conn)

      assert redirected_to(get(conn, ~p"/")) == "/onboarding"
      assert conn |> get(~p"/orgs/#{org.slug}/settings") |> redirected_to() == "/onboarding"
      assert redirected_to(get(conn, "/onboarding/tasks")) == "/onboarding"
    end
  end

  describe "GET /dashboard/api/v1/onboarding" do
    test "lists the capability groups with their defaults and the user's identity",
         %{conn: conn} do
      %{conn: conn, user: user, org: org} = log_in_fresh_owner(conn)

      data = conn |> get(@api) |> json_response(200) |> data()

      assert data["status"] == "in_progress"
      assert data["step"] == "capabilities"

      assert Enum.map(data["capability_groups"], & &1["key"]) ==
               ~w(inbox informed meetings calendar notifications memory)

      assert data["capabilities"]["inbox.draft_replies"] == true
      assert data["capabilities"]["inbox.archive_unimportant"] == false
      assert data["user"] == %{"name" => user.name, "email" => user.email}
      assert data["org"] == %{"slug" => org.slug, "name" => org.name, "role" => "owner"}
    end

    test "creates a swarm the user owns, once", %{conn: conn} do
      %{conn: conn, user: user, org: org} = log_in_fresh_owner(conn)
      assert Projects.default_project_for_user(org.id, user.id) == nil

      conn |> get(@api) |> json_response(200)

      owned = Projects.default_project_for_user(org.id, user.id)
      assert owned.created_by_user_id == user.id

      conn |> get(@api) |> json_response(200)
      assert length(Projects.list_projects(org.id)) == 1
    end

    test "costs the same queries however large the organization", %{conn: conn} do
      %{conn: conn, user: user, org: org} = log_in_fresh_owner(conn)
      conn |> get(@api) |> json_response(200)
      small = query_count(conn, @api)

      for _ <- 1..6 do
        {:ok, _} = Memberships.put_org_member(org.id, user_fixture().id, "member")
      end

      {:ok, _} = Memberships.put_org_member(org_fixture().id, user.id, "member")

      # Joining another org can change which org the wizard opens first; that
      # first read then creates the user's swarm there once. Measure after it.
      conn |> get(@api) |> json_response(200)
      assert query_count(conn, @api) == small
    end
  end

  describe "the capabilities step" do
    test "saves the grants, keeps the rest, and moves on to the profile", %{conn: conn} do
      %{conn: conn, user: user} = log_in_fresh_owner(conn)

      data =
        conn
        |> put_req_header("content-type", "application/json")
        |> put(
          @api <> "/capabilities",
          Jason.encode!(%{"capabilities" => %{"inbox.draft_replies" => false}})
        )
        |> json_response(200)
        |> data()

      assert data["step"] == "profile"
      assert data["capabilities"]["inbox.draft_replies"] == false

      {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
      assert onboarding.current_step == "profile"
      assert onboarding.capabilities["inbox.draft_replies"] == false
      assert onboarding.capabilities["meetings.meeting_briefing"] == true
      assert onboarding.capabilities["inbox.archive_unimportant"] == false
    end
  end

  describe "the profile step" do
    test "captures identity, real contacts and honest plans, then moves on", %{conn: conn} do
      %{conn: conn, user: user, org: org} = log_in_fresh_owner(conn)
      with_salix_client(UnconfiguredComposioClient)
      teammate = user_fixture(%{name: "Terry Teammate"})
      {:ok, _} = Memberships.put_org_member(org.id, teammate.id, "member")
      conn |> get(@api) |> json_response(200)

      assert %{"step" => "integrations"} =
               conn |> post(@api <> "/profile") |> json_response(200) |> data()

      {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
      assert onboarding.current_step == "integrations"

      assert onboarding.profile["identity"] == %{
               "name" => user.name,
               "email" => user.email,
               "role" => "owner",
               "org" => org.name
             }

      assert onboarding.profile["key_contacts"] == [
               %{"name" => "Terry Teammate", "email" => teammate.email, "role" => "member"}
             ]

      # Nothing is connected: the agent plans to learn, it has not learned.
      assert onboarding.profile["work_patterns"] == %{"status" => "planned", "source" => "google"}
    end
  end

  describe "the integrations step" do

    test "a plain member works on their own new swarm, never someone else's", %{conn: conn} do
      %{org: org} = org_with_owner_fixture()
      foreign = bare_project_fixture(org)
      member = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
      conn = log_in_user(conn, member, onboarded: false)
      with_salix_client(UnconfiguredComposioClient)

      conn |> get(@api) |> json_response(200)
      data = conn |> get(@api <> "/integrations") |> json_response(200) |> data()

      own = Projects.default_project_for_user(org.id, member.id)
      assert own.created_by_user_id == member.id
      assert data["project"]["id"] == own.id
      refute data["project"]["id"] == foreign.id
      assert data["can_connect"]
      refute data["org_admin"]
    end
  end

  describe "POST /dashboard/api/v1/onboarding/connect" do
    test "answers the Connect Link, which returns to the integrations step", %{conn: conn} do
      %{conn: conn, user: user, org: org} = log_in_fresh_owner(conn)
      with_salix_client(ComposioClient)
      provisioned_swarm(org, user)

      assert %{"redirect_url" => "https://connect.composio.dev/link/lk_onboarding"} =
               conn
               |> post(@api <> "/connect", %{"toolkit" => "notion"})
               |> json_response(200)
               |> data()

      assert_received {:connect_link_requested, "notion", attrs}
      assert attrs["callback_url"] =~ ~r{^https?://[^/]+/onboarding/integrations$}

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_composio_connection.authorization_started"
               )

      assert audit.actor_user_id == user.id
    end

    test "a swarm owner who is only an org member may connect", %{conn: conn} do
      %{org: org} = org_with_owner_fixture()
      member = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
      conn = log_in_user(conn, member, onboarded: false)
      with_salix_client(ComposioClient)

      conn |> get(@api) |> json_response(200)

      assert %{"redirect_url" => _} =
               conn
               |> post(@api <> "/connect", %{"toolkit" => "notion"})
               |> json_response(200)
               |> data()
    end

    test "someone who only uses a swarm is refused, with a denied audit", %{conn: conn} do
      %{org: org, user: owner} = org_with_owner_fixture()
      project = provisioned_swarm(org, owner)
      member = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")
      conn = log_in_user(conn, member, onboarded: false)
      with_salix_client(ComposioClient)

      assert %{"ask_admin" => 6, "connected" => 1} =
               conn
               |> get(@api <> "/integrations")
               |> json_response(200)
               |> data()
               |> Map.fetch!("toolkits")
               |> Enum.frequencies_by(& &1["state"])

      assert %{"error" => %{"code" => "forbidden"}} =
               conn |> post(@api <> "/connect", %{"toolkit" => "notion"}) |> json_response(403)

      refute_received {:connect_link_requested, _, _}

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project_composio_connection.authorization_started",
                 result: "denied"
               )

      assert audit.actor_user_id == member.id
      assert audit.metadata["project_id"] == project.id
    end
  end

  describe "finishing, skipping and restarting" do
    test "finishing opens the dashboard on the first organization", %{conn: conn} do
      %{conn: conn, user: user, org: org} = log_in_fresh_owner(conn)

      assert %{"redirect" => redirect, "notice" => "You're all set."} =
               conn |> post(@api <> "/complete") |> json_response(200) |> data()

      assert redirect == "/orgs/#{org.slug}"
      assert UserOnboardings.onboarded?(user.id)
      assert conn |> get(~p"/") |> html_response(200) =~ ~s(id="root")
    end

    test "restart reopens the wizard without wiping captured answers", %{conn: conn} do
      %{conn: conn, user: user} = log_in_fresh_owner(conn)

      conn
      |> put_req_header("content-type", "application/json")
      |> put(
        @api <> "/capabilities",
        Jason.encode!(%{"capabilities" => %{"inbox.label_new_mail" => false}})
      )
      |> json_response(200)

      conn |> post(@api <> "/complete") |> json_response(200)
      {:ok, %{capabilities: before}} = UserOnboardings.get_onboarding(user.id)

      conn = post(conn, ~p"/onboarding/restart")
      assert redirected_to(conn) == "/onboarding"

      {:ok, onboarding} = UserOnboardings.get_onboarding(user.id)
      assert onboarding.status == "in_progress"
      assert onboarding.current_step == "capabilities"
      assert onboarding.completed_at == nil
      assert onboarding.capabilities == before
      refute UserOnboardings.onboarded?(user.id)

      conn = recycle(conn)
      assert conn |> get(~p"/onboarding") |> html_response(200) =~ ~s(<div id="root"></div>)

      assert %{"status" => "in_progress", "capabilities" => %{"inbox.label_new_mail" => false}} =
               conn |> get(@api) |> json_response(200) |> data()
    end
  end

  test "writes need the page's CSRF token", %{conn: conn} do
    %{conn: conn, user: user} = log_in_fresh_owner(conn)
    conn = get(conn, ~p"/onboarding")

    [_, token] =
      Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

    conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)

    assert_error_sent(403, fn -> post(conn, @api <> "/skip") end)
    refute UserOnboardings.onboarded?(user.id)

    assert %{"ok" => true} =
             conn
             |> put_req_header("x-csrf-token", token)
             |> post(@api <> "/skip")
             |> json_response(200)
  end

  defp data(%{"data" => data}), do: data

  defp query_count(conn, path) do
    test_pid = SystemsRuntime.Proc.self()
    handler = "onboarding-wizard-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if SystemsRuntime.Proc.self() == test_pid,
            do: SystemsRuntime.Proc.send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      SystemsRuntime.Telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    SystemsRuntime.Proc.receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end
end
