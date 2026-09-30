defmodule BridgeForTeams.Auth.ImportTokenTest do
  @moduledoc """
  Temporary My Space data-import tokens: mint authorization, expiry, single
  active token per (user, project), and use-time re-verification.
  """
  use BridgeForTeams.DataCase, async: true

  import Ecto.Query

  alias BridgeForTeams.{Accounts, Auth, Memberships, Observability, Orgs, Projects}
  alias BridgeForTeams.Schema.DashboardImportToken

  setup do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-#{uniq()}"})
    {:ok, project} = Projects.create_project(org.id, %{name: "Board", slug: "board-#{uniq()}"})
    %{org: org, project: project}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp user!(role_setup) do
    {:ok, user} = Accounts.create_user(%{email: "u-#{uniq()}@example.test"})
    role_setup.(user)
    user
  end

  defp active_token_count(user_id, project_id) do
    Repo.aggregate(
      from(t in DashboardImportToken,
        where: t.user_id == ^user_id and t.project_id == ^project_id and is_nil(t.revoked_at)
      ),
      :count,
      :id
    )
  end

  describe "create_import_token/4 authorization" do
    test "project admin may mint", %{org: org, project: project} do
      user =
        user!(fn u -> {:ok, _} = Memberships.put_project_member(project.id, u.id, "admin") end)

      assert {:ok, %{token: token, import_token: record, expires_at: %DateTime{}}} =
               Auth.create_import_token(user, org, project)

      assert String.starts_with?(token, "bfti_")
      assert record.user_id == user.id
      assert record.project_id == project.id
    end

    test "org owner may mint", %{org: org, project: project} do
      user = user!(fn u -> {:ok, _} = Memberships.put_org_member(org.id, u.id, "owner") end)
      assert {:ok, _} = Auth.create_import_token(user, org, project)
    end

    test "org admin may mint", %{org: org, project: project} do
      user = user!(fn u -> {:ok, _} = Memberships.put_org_member(org.id, u.id, "admin") end)
      assert {:ok, _} = Auth.create_import_token(user, org, project)
    end

    test "plain project user is forbidden", %{org: org, project: project} do
      user =
        user!(fn u -> {:ok, _} = Memberships.put_project_member(project.id, u.id, "user") end)

      assert {:error, :forbidden} = Auth.create_import_token(user, org, project)
    end

    test "plain org member with no project grant is forbidden", %{org: org, project: project} do
      user = user!(fn u -> {:ok, _} = Memberships.put_org_member(org.id, u.id, "member") end)
      assert {:error, :forbidden} = Auth.create_import_token(user, org, project)
    end

    test "non-member is forbidden", %{org: org, project: project} do
      user = user!(fn _ -> :ok end)
      assert {:error, :forbidden} = Auth.create_import_token(user, org, project)
    end

    test "mint is forbidden when the project belongs to another org", %{project: project} do
      {:ok, other_org} = Orgs.create_org(%{name: "Other", slug: "other-#{uniq()}"})
      user = user!(fn u -> {:ok, _} = Memberships.put_org_member(other_org.id, u.id, "owner") end)

      assert {:error, :forbidden} = Auth.create_import_token(user, other_org, project)
    end

    test "records an audit event", %{org: org, project: project} do
      user =
        user!(fn u -> {:ok, _} = Memberships.put_project_member(project.id, u.id, "admin") end)

      {:ok, %{import_token: record}} = Auth.create_import_token(user, org, project)

      logs = Observability.list_audit_logs(org.id, action: "dashboard_import_token.created")

      assert Enum.any?(logs, fn log -> log.resource_id == record.id end)
    end
  end

  describe "single active token per (user, project)" do
    test "minting again revokes the previous active token", %{org: org, project: project} do
      user =
        user!(fn u -> {:ok, _} = Memberships.put_project_member(project.id, u.id, "admin") end)

      {:ok, %{token: first}} = Auth.create_import_token(user, org, project)
      {:ok, %{token: second}} = Auth.create_import_token(user, org, project)

      assert active_token_count(user.id, project.id) == 1
      assert {:error, :unauthenticated} = Auth.authenticate_import_token(first)
      assert {:ok, _} = Auth.authenticate_import_token(second)
    end
  end

  describe "authenticate_import_token/1" do
    setup %{org: org, project: project} do
      user =
        user!(fn u -> {:ok, _} = Memberships.put_project_member(project.id, u.id, "admin") end)

      {:ok, %{token: token, import_token: record}} = Auth.create_import_token(user, org, project)
      %{user: user, token: token, record: record}
    end

    test "valid token returns the user and scope", %{
      user: user,
      org: org,
      project: project,
      token: token
    } do
      assert {:ok, %{user: %{id: id}, org_id: org_id, project_id: project_id}} =
               Auth.authenticate_import_token(token)

      assert id == user.id
      assert org_id == org.id
      assert project_id == project.id
    end

    test "unknown token is rejected" do
      assert {:error, :unauthenticated} = Auth.authenticate_import_token("bfti_nope")
    end

    test "token without the prefix is rejected", %{token: token} do
      raw = String.replace_prefix(token, "bfti_", "")
      assert {:error, :unauthenticated} = Auth.authenticate_import_token(raw)
    end

    test "expired token is rejected", %{record: record, token: token} do
      record
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      assert {:error, :unauthenticated} = Auth.authenticate_import_token(token)
    end

    test "revoked token is rejected", %{record: record, token: token} do
      record
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:error, :unauthenticated} = Auth.authenticate_import_token(token)
    end

    test "token is rejected once the user loses project write access", %{
      user: user,
      project: project,
      token: token
    } do
      # Membership revoked after mint: the use-time re-verification denies it.
      :ok = Memberships.remove_project_member(project.id, user.id)

      assert {:error, :unauthenticated} = Auth.authenticate_import_token(token)
    end

    test "custom ttl is honored", %{org: org, project: project, user: user} do
      {:ok, %{import_token: record}} =
        Auth.create_import_token(user, org, project, ttl_seconds: 5)

      diff = DateTime.diff(record.expires_at, DateTime.utc_now())
      assert diff <= 5 and diff >= 0
    end
  end
end
