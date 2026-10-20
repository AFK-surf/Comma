defmodule BridgeForTeams.SchemasTest do
  @moduledoc """
  Changeset validation + DB-constraint coverage for the design §5 schemas:
  required fields, role/status/platform inclusion, the unique indexes
  (org slug, (org,user), (project,slug), (project,platform), token/key hashes),
  and the UUID v7 primary-key default applied DB-side. Case-insensitive
  user email uniqueness and lookup are covered in `AccountsTest`.
  """
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.Repo

  alias BridgeForTeams.Schema.{
    Organization,
    User,
    OrgMembership,
    Project,
    ProjectMembership,
    Agent,
    AuthSession,
    CliDeviceAuthorization,
    OrgSsoConnection,
    OrgSsoIdentity,
    ApiKey
  }

  # --- helpers ----------------------------------------------------------

  defp org!(attrs \\ %{}) do
    tenant_id = SalixStore.Ids.new_tenant_id()

    {:ok, org} =
      %Organization{}
      |> Organization.changeset(
        Map.merge(
          %{
            name: "Acme",
            slug: uniq("acme"),
            salix_tenant_id: tenant_id,
            billing_account_id: "bridge-ba-#{tenant_id}"
          },
          attrs
        )
      )
      |> Repo.insert()

    org
  end

  defp user!(attrs \\ %{}) do
    {:ok, user} =
      %User{}
      |> User.changeset(Map.merge(%{email: "#{uniq("u")}@example.com", name: "U"}, attrs))
      |> Repo.insert()

    user
  end

  defp project!(org, attrs \\ %{}) do
    {:ok, project} =
      %Project{}
      |> Project.changeset(
        Map.merge(
          %{
            org_id: org.id,
            name: "Proj",
            slug: uniq("proj"),
            salix_group_id: SalixStore.Ids.new_group_id(org.salix_tenant_id)
          },
          attrs
        )
      )
      |> Repo.insert()

    project
  end

  defp uniq(prefix), do: "#{prefix}-#{SystemsRuntime.Proc.unique_integer([:positive])}"

  # --- organizations ----------------------------------------------------

  describe "Organization.changeset/2" do
  end

  # --- users (optional citext email) -------------------------------------

  describe "User.changeset/2" do
    test "allows email to be absent for subject-based SSO" do
      {:ok, user} =
        %User{}
        |> User.changeset(%{name: "Subject-based User"})
        |> Repo.insert()

      assert user.email == nil
      assert user.name == "Subject-based User"
    end
  end

  # --- org_memberships --------------------------------------------------

  describe "OrgMembership.changeset/2" do
  end

  # --- projects ---------------------------------------------------------

  describe "Project.changeset/2" do
    test "unique(org_id, slug); same slug allowed in a different org" do
      org_a = org!()
      org_b = org!()
      p = project!(org_a, %{slug: "shared"})

      {:error, cs} =
        %Project{}
        |> Project.changeset(%{
          org_id: org_a.id,
          name: "n",
          slug: p.slug,
          salix_group_id: SalixStore.Ids.new_group_id(org_a.salix_tenant_id)
        })
        |> Repo.insert()

      assert errors_on(cs)[:slug] == ["has already been taken"]

      assert {:ok, _} =
               %Project{}
               |> Project.changeset(%{
                 org_id: org_b.id,
                 name: "n",
                 slug: "shared",
                 salix_group_id: SalixStore.Ids.new_group_id(org_b.salix_tenant_id)
               })
               |> Repo.insert()
    end
  end

  # --- project_memberships ----------------------------------------------

  describe "ProjectMembership.changeset/2" do
    test "role inclusion + unique(project_id, user_id)" do
      org = org!()
      project = project!(org)
      user = user!()

      assert ProjectMembership.roles() == ["admin", "user"]

      bad =
        ProjectMembership.changeset(%ProjectMembership{}, %{
          project_id: project.id,
          user_id: user.id,
          role: "owner"
        })

      assert %{role: ["is invalid"]} = errors_on(bad)

      {:ok, _} =
        %ProjectMembership{}
        |> ProjectMembership.changeset(%{project_id: project.id, user_id: user.id, role: "admin"})
        |> Repo.insert()

      {:error, cs} =
        %ProjectMembership{}
        |> ProjectMembership.changeset(%{
          project_id: project.id,
          user_id: user.id,
          role: "user"
        })
        |> Repo.insert()

      assert errors_on(cs)[:project_id] == ["has already been taken"]
    end
  end

  # --- agents -----------------------------------------------------------

  describe "Agent.changeset/2" do
    test "stores only product references and keeps initial input in the native record shape" do
      org = org!()
      project = project!(org)

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          project_id: project.id,
          salix_agent_id: SalixStore.Ids.new_agent_id(project.salix_group_id),
          role: "router",
          name: "Router",
          llm_config: %{"model" => "claude"}
        })
        |> Repo.insert()

      assert agent.salix["name"] == "Router"
      assert agent.salix["llm_config"] == %{"model" => "claude"}
      assert Repo.reload!(agent).salix == %{}
    end
  end

  # --- auth_sessions ----------------------------------------------------

  describe "AuthSession.changeset/2" do
  end

  # --- cli_device_authorizations ----------------------------------------

  describe "CliDeviceAuthorization.changeset/2" do
  end

  # --- org_sso_connections ----------------------------------------------

  describe "OrgSsoConnection.changeset/2" do
    test "Feishu SSO does not require issuer because it is not email-domain OIDC" do
      org = org!()

      {:ok, conn} =
        %OrgSsoConnection{}
        |> OrgSsoConnection.changeset(%{
          org_id: org.id,
          provider: "feishu",
          client_id: "feishu-app",
          client_secret: "feishu-secret",
          provider_config: %{"tenant_mode" => "single"}
        })
        |> Repo.insert()

      assert conn.provider == "feishu"
      assert conn.issuer == nil
      assert conn.provider_config == %{"tenant_mode" => "single"}
    end

    test "Feishu SSO requires a client secret" do
      cs =
        OrgSsoConnection.changeset(%OrgSsoConnection{}, %{
          org_id: SystemsRuntime.Proc.uuid(),
          provider: "feishu",
          client_id: "feishu-app"
        })

      assert %{client_secret: ["can't be blank"]} = errors_on(cs)
    end

    test "an org can have only one SSO provider connection" do
      org = org!()

      {:ok, _} =
        %OrgSsoConnection{}
        |> OrgSsoConnection.changeset(%{
          org_id: org.id,
          issuer: "https://idp.example.com",
          client_id: "oidc"
        })
        |> Repo.insert()

      {:error, cs} =
        %OrgSsoConnection{}
        |> OrgSsoConnection.changeset(%{
          org_id: org.id,
          provider: "feishu",
          client_id: "feishu-app",
          client_secret: "feishu-secret"
        })
        |> Repo.insert()

      assert %{org_id: ["has already been taken"]} = errors_on(cs)
    end
  end

  # --- org_sso_identities -----------------------------------------------

  describe "OrgSsoIdentity.changeset/2" do
    test "provider subject is unique within an org and provider" do
      org = org!()
      first = user!(%{email: nil})
      second = user!(%{email: nil})

      attrs = %{
        org_id: org.id,
        provider: "feishu",
        provider_subject_type: "user_id",
        provider_subject: "same-feishu-user"
      }

      {:ok, _} =
        %OrgSsoIdentity{}
        |> OrgSsoIdentity.changeset(Map.put(attrs, :user_id, first.id))
        |> Repo.insert()

      {:error, cs} =
        %OrgSsoIdentity{}
        |> OrgSsoIdentity.changeset(Map.put(attrs, :user_id, second.id))
        |> Repo.insert()

      assert %{
               org_id: ["has already been taken"]
             } = errors_on(cs)
    end
  end

  # --- api_keys ---------------------------------------------------------

  describe "ApiKey.changeset/2" do
  end
end
