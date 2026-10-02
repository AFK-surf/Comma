defmodule BridgeForTeamsWeb.DashboardCase do
  @moduledoc """
  Test case for the LiveView dashboard (port 4101 endpoint). Provides
  `Phoenix.ConnTest` + `Phoenix.LiveViewTest` against
  `BridgeForTeamsWeb.DashboardEndpoint`, checks out the Ecto SQL sandbox (the
  dashboard drives `bridge_for_teams_core`'s repo), and exposes:

    * `log_in_user(conn, user)` — creates a REAL session via
      `BridgeForTeams.Auth.Sessions` and writes the opaque token into the signed
      dashboard session cookie (same key the on_mount hook reads).
    * `register_and_log_in_user/1` (setup tag) — creates user+org+membership and
      logs in.
    * fixtures: `user_fixture/1`, `org_fixture/1`, `org_with_owner_fixture/1`,
      `bare_project_fixture/1`.

  The OIDC provider is injected in tests. Salix calls go through the real erpc
  boundary against the in-process Salix apps.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: BridgeForTeamsWeb.DashboardEndpoint,
        router: BridgeForTeamsWeb.DashboardRouter

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import BridgeForTeamsWeb.DashboardCase

      @endpoint BridgeForTeamsWeb.DashboardEndpoint
    end
  end

  alias BridgeForTeams.{Accounts, Memberships, Orgs}
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeamsWeb.Dashboard.Auth, as: DashAuth

  setup tags do
    bridge_owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(BridgeForTeams.Repo, shared: not tags[:async])

    billing_owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: not tags[:async])

    on_exit(fn ->
      _ = BridgeForTeams.EnvironmentRuntimeObserver.drain(30_000)
      Ecto.Adapters.SQL.Sandbox.stop_owner(bridge_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates a real session for `user` and stores its opaque token in the signed
  dashboard session cookie (the same `comma_session` key the on_mount auth hook
  and the `fetch_current_user` plug read).

  Also marks the user's first-run onboarding completed so the
  `:require_onboarded` gate doesn't bounce the test to `/onboarding`; pass
  `onboarded: false` to log in a fresh user and exercise the gate itself.
  """
  @spec log_in_user(Plug.Conn.t(), map(), keyword()) :: Plug.Conn.t()
  def log_in_user(conn, user, opts \\ []) do
    if Keyword.get(opts, :onboarded, true), do: complete_onboarding(user)

    {:ok, %{token: token}} = Sessions.create(user, [])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(DashAuth.session_token_key(), token)
  end

  @doc "Setup helper: create user + org + owner membership and log in. Returns %{conn, user, org}."
  def register_and_log_in_user(%{conn: conn}) do
    %{user: user, org: org} = org_with_owner_fixture()
    %{conn: log_in_user(conn, user), user: user, org: org}
  end

  @doc "Mark `user`'s first-run onboarding as completed (passes the mount gate)."
  def complete_onboarding(user) do
    {:ok, onboarding} = BridgeForTeams.UserOnboardings.ensure_onboarding(user.id)
    {:ok, onboarding} = BridgeForTeams.UserOnboardings.complete(onboarding)
    onboarding
  end

  # ---- fixtures ----

  @doc "Create a user (default active)."
  def user_fixture(attrs \\ %{}) do
    email = attrs[:email] || "user-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(%{"email" => email, "name" => attrs[:name] || "Test User"})
    user
  end

  @doc "Create an org."
  def org_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{
        "name" => attrs[:name] || "Org #{n}",
        "slug" => attrs[:slug] || "org-#{n}"
      })

    org
  end

  @doc "Create an org + user + owner membership. Returns %{org, user, membership}."
  def org_with_owner_fixture(attrs \\ %{}) do
    user = user_fixture(attrs[:user] || %{})
    org = org_fixture(attrs[:org] || %{})
    {:ok, membership} = Memberships.put_org_member(org.id, user.id, "owner")
    %{org: org, user: user, membership: membership}
  end

  @doc """
  Insert a bare project row (no Salix group or agent provisioning) — the swarm
  a board task/pref can reference when the test only needs the Postgres model.
  Use `BridgeForTeams.Projects.create_project/2` instead when the test needs a
  provisioned router agent.
  """
  def bare_project_fixture(org, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    BridgeForTeams.Repo.insert!(%BridgeForTeams.Schema.Project{
      org_id: org.id,
      name: attrs[:name] || "Project #{n}",
      slug: attrs[:slug] || "project-#{n}",
      salix_group_id: SalixStore.Ids.new_group_id(org.salix_tenant_id)
    })
  end
end
