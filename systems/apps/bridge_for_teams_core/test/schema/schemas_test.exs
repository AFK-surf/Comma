defmodule BridgeForTeams.SchemasTest do
  @moduledoc """
  Changeset validation + DB-constraint coverage for the design §5 schemas:
  required fields, role/status/platform inclusion, the unique indexes
  (org slug, optional user email[citext], (org,user), (project,slug), (project,platform),
  token/key hashes), citext case-insensitivity, and the UUID v7 primary-key
  default applied DB-side.
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
    ApiKey,
    ReconcileOutbox,
    AuditLog
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp agent_id,
    do: SalixStore.Ids.new_agent_id(SalixStore.Ids.new_group_id(SalixStore.Ids.new_tenant_id()))

  # --- organizations ----------------------------------------------------

  describe "Organization.changeset/2" do
    test "requires name and slug" do
      cs = Organization.changeset(%Organization{}, %{})
      refute cs.valid?

      assert %{
               name: ["can't be blank"],
               slug: ["can't be blank"],
               billing_account_id: ["can't be blank"],
               salix_tenant_id: ["can't be blank"]
             } = errors_on(cs)
    end

    test "defaults status to active and a valid binary_id" do
      org = org!()
      assert org.status == "active"
      assert {:ok, _} = Ecto.UUID.dump(org.id)
    end

    test "DB-side primary-key default mints UUID v7 (design: all ids UUID v7)" do
      # Ecto's `@primary_key autogenerate: true` mints the id client-side (v4),
      # but the column default `uuid_generate_v7()` covers any non-Ecto insert
      # path. Exercise it by inserting without supplying an id.
      {:ok, res} =
        Repo.query(
          "INSERT INTO organizations " <>
            "(name, slug, salix_tenant_id, billing_account_id, created_at, updated_at) " <>
            "VALUES ($1, $2, $3, $4, now(), now()) RETURNING id",
          ["Raw", uniq("raw"), "org_raw_#{System.unique_integer([:positive])}", uniq("ba-raw")]
        )

      id = res.rows |> hd() |> hd() |> Ecto.UUID.cast!()
      # Version nibble (char 14) is 7; variant nibble (char 19) is one of 8..b.
      assert String.at(id, 14) == "7"
      assert String.at(id, 19) in ~w(8 9 a b)
    end

    test "DB default ids are time-ordered across milliseconds (UUID v7)" do
      mint = fn ->
        {:ok, res} = Repo.query("SELECT uuid_generate_v7()")
        res.rows |> hd() |> hd() |> Ecto.UUID.cast!()
      end

      a = mint.()
      # Advance the clock past the 48-bit ms timestamp boundary.
      Repo.query!("SELECT pg_sleep(0.005)")
      b = mint.()

      assert a < b
    end

    test "slug is unique" do
      org = org!()

      {:error, cs} =
        %Organization{}
        |> Organization.changeset(%{
          name: "Dup",
          slug: org.slug,
          salix_tenant_id: SalixStore.Ids.new_tenant_id(),
          billing_account_id: "bridge-ba-dup-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert()

      assert %{slug: ["has already been taken"]} = errors_on(cs)
    end

    test "icon must be an inline image data URL" do
      cs =
        Organization.changeset(%Organization{}, %{
          name: "Acme",
          slug: uniq("acme"),
          salix_tenant_id: SalixStore.Ids.new_tenant_id(),
          billing_account_id: "bridge-ba-icon-#{System.unique_integer([:positive])}",
          icon: "https://example.com/icon.png"
        })

      assert %{icon: ["must be an inline PNG, JPEG, GIF, or WebP data URL"]} = errors_on(cs)
    end
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

    test "normalizes blank email to nil" do
      {:ok, user} =
        %User{}
        |> User.changeset(%{email: "", name: "Blank Email"})
        |> Repo.insert()

      assert user.email == nil
    end

    test "email unique is case-insensitive (citext)" do
      _u = user!(%{email: "Mixed@Case.com"})

      {:error, cs} =
        %User{}
        |> User.changeset(%{email: "mixed@case.com"})
        |> Repo.insert()

      assert %{email: ["has already been taken"]} = errors_on(cs)
    end

    test "email is looked up case-insensitively" do
      _u = user!(%{email: "Find@Me.com"})
      assert Repo.get_by(User, email: "find@me.com")
    end
  end

  # --- org_memberships --------------------------------------------------

  describe "OrgMembership.changeset/2" do
    test "validates role inclusion" do
      cs =
        OrgMembership.changeset(%OrgMembership{}, %{
          org_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          role: "bogus"
        })

      assert %{role: ["is invalid"]} = errors_on(cs)
      assert "owner" in OrgMembership.roles()
    end

    test "unique(org_id, user_id)" do
      org = org!()
      user = user!()

      {:ok, _} =
        %OrgMembership{}
        |> OrgMembership.changeset(%{org_id: org.id, user_id: user.id, role: "owner"})
        |> Repo.insert()

      {:error, cs} =
        %OrgMembership{}
        |> OrgMembership.changeset(%{org_id: org.id, user_id: user.id, role: "member"})
        |> Repo.insert()

      assert errors_on(cs)[:org_id] == ["has already been taken"]
    end
  end

  # --- projects ---------------------------------------------------------

  describe "Project.changeset/2" do
    test "requires org_id, name, slug" do
      cs = Project.changeset(%Project{}, %{})
      assert %{org_id: _, name: _, slug: _} = errors_on(cs)
    end

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
    test "requires project_id and role; role inclusion" do
      cs = Agent.changeset(%Agent{}, %{})
      assert %{project_id: _, role: _} = errors_on(cs)

      bad = Agent.changeset(%Agent{}, %{project_id: Ecto.UUID.generate(), role: "boss"})
      assert %{role: ["is invalid"]} = errors_on(bad)
      assert Agent.roles() == ["router", "worker"]
    end

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

    test "validates external runtime config as a worker-only Codex runtime" do
      project_id = Ecto.UUID.generate()

      valid =
        Agent.changeset(%Agent{}, %{
          project_id: project_id,
          salix_agent_id: agent_id(),
          role: "worker",
          runtime_config: %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "device-codex",
            "runtime_id" => "runtime-codex",
            "device_runtime_id" => "device-runtime-codex"
          }
        })

      assert valid.valid?

      router =
        Agent.changeset(%Agent{}, %{
          project_id: project_id,
          salix_agent_id: agent_id(),
          role: "router",
          runtime_config: %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "device-codex",
            "runtime_id" => "runtime-codex",
            "device_runtime_id" => "device-runtime-codex"
          }
        })

      assert %{role: ["must be worker for external runtime agents"]} = errors_on(router)

      missing_runtime =
        Agent.changeset(%Agent{}, %{
          project_id: project_id,
          salix_agent_id: agent_id(),
          role: "worker",
          runtime_config: %{
            "kind" => "external",
            "provider" => "codex",
            "device_id" => "device-codex",
            "runtime_id" => "runtime-codex"
          }
        })

      assert %{runtime_config: ["must include device_runtime_id"]} = errors_on(missing_runtime)

      internal_with_extra =
        Agent.changeset(%Agent{}, %{
          project_id: project_id,
          salix_agent_id: agent_id(),
          role: "worker",
          runtime_config: %{
            "kind" => "internal",
            "env_id" => "env_mac"
          }
        })

      assert %{runtime_config: ["must only include kind for internal runtime"]} =
               errors_on(internal_with_extra)
    end
  end

  # --- auth_sessions ----------------------------------------------------

  describe "AuthSession.changeset/2" do
    test "requires user_id, token_hash, expires_at; token_hash unique" do
      cs = AuthSession.changeset(%AuthSession{}, %{})
      assert %{user_id: _, token_hash: _, expires_at: _} = errors_on(cs)

      user = user!()
      exp = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} =
        %AuthSession{}
        |> AuthSession.changeset(%{user_id: user.id, token_hash: "h1", expires_at: exp})
        |> Repo.insert()

      {:error, dup} =
        %AuthSession{}
        |> AuthSession.changeset(%{user_id: user.id, token_hash: "h1", expires_at: exp})
        |> Repo.insert()

      assert errors_on(dup)[:token_hash] == ["has already been taken"]
    end
  end

  # --- cli_device_authorizations ----------------------------------------

  describe "CliDeviceAuthorization.changeset/2" do
    test "requires user_code, device_code_hash, status, expires_at; user_code unique" do
      cs = CliDeviceAuthorization.changeset(%CliDeviceAuthorization{}, %{})
      assert %{user_code: _, device_code_hash: _, expires_at: _} = errors_on(cs)

      exp = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, inserted} =
        %CliDeviceAuthorization{}
        |> CliDeviceAuthorization.changeset(%{
          user_code: "ABC12345",
          device_code_hash: "hash1",
          status: "pending",
          expires_at: exp
        })
        |> Repo.insert()

      assert inserted.created_at
      assert inserted.updated_at

      {:error, dup} =
        %CliDeviceAuthorization{}
        |> CliDeviceAuthorization.changeset(%{
          user_code: "ABC12345",
          device_code_hash: "hash2",
          status: "pending",
          expires_at: exp
        })
        |> Repo.insert()

      assert errors_on(dup)[:user_code] == ["has already been taken"]
    end
  end

  # --- org_sso_connections ----------------------------------------------

  describe "OrgSsoConnection.changeset/2" do
    test "generic OIDC requires org_id, issuer, client_id; array + default_role defaults" do
      cs = OrgSsoConnection.changeset(%OrgSsoConnection{}, %{})
      assert %{org_id: _, issuer: _, client_id: _} = errors_on(cs)

      org = org!()

      {:ok, conn} =
        %OrgSsoConnection{}
        |> OrgSsoConnection.changeset(%{
          org_id: org.id,
          issuer: "https://idp.example.com",
          client_id: "cid",
          allowed_domains: ["example.com"]
        })
        |> Repo.insert()

      assert conn.default_role == "member"
      assert conn.allowed_domains == ["example.com"]
      assert conn.provider == "generic_oidc"
    end

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
          org_id: Ecto.UUID.generate(),
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
    test "requires org/user/provider subject and allows mobile-only profile" do
      org = org!()
      user = user!(%{email: nil})

      cs = OrgSsoIdentity.changeset(%OrgSsoIdentity{}, %{})

      assert %{
               org_id: _,
               user_id: _,
               provider: _,
               provider_subject_type: _,
               provider_subject: _
             } = errors_on(cs)

      {:ok, identity} =
        %OrgSsoIdentity{}
        |> OrgSsoIdentity.changeset(%{
          org_id: org.id,
          user_id: user.id,
          provider: "feishu",
          provider_subject_type: "user_id",
          provider_subject: "feishu-user",
          mobile: "+10000000005",
          display_name: "Mobile Only"
        })
        |> Repo.insert()

      assert identity.email == nil
      assert identity.mobile == "+10000000005"
    end

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
    test "requires org_id, key_hash; key_hash unique; scopes default []" do
      cs = ApiKey.changeset(%ApiKey{}, %{})
      assert %{org_id: _, key_hash: _} = errors_on(cs)

      org = org!()

      {:ok, key} =
        %ApiKey{}
        |> ApiKey.changeset(%{org_id: org.id, name: "ci", key_hash: "kh1"})
        |> Repo.insert()

      assert key.scopes == []

      {:error, dup} =
        %ApiKey{}
        |> ApiKey.changeset(%{org_id: org.id, key_hash: "kh1"})
        |> Repo.insert()

      assert errors_on(dup)[:key_hash] == ["has already been taken"]
    end
  end

  # --- reconcile_outbox -------------------------------------------------

  describe "ReconcileOutbox.changeset/2" do
    test "requires aggregate, aggregate_id, op; status inclusion + defaults" do
      cs = ReconcileOutbox.changeset(%ReconcileOutbox{}, %{})
      assert %{aggregate: _, aggregate_id: _, op: _} = errors_on(cs)

      bad =
        ReconcileOutbox.changeset(%ReconcileOutbox{}, %{
          aggregate: "project",
          aggregate_id: "p1",
          op: "create_tenant",
          status: "weird"
        })

      assert %{status: ["is invalid"]} = errors_on(bad)
      assert ReconcileOutbox.statuses() == ["pending", "done", "failed"]

      {:ok, row} =
        %ReconcileOutbox{}
        |> ReconcileOutbox.changeset(%{
          aggregate: "project",
          aggregate_id: "p1",
          op: "create_tenant",
          payload: %{"x" => 1}
        })
        |> Repo.insert()

      assert row.status == "pending"
      assert row.attempts == 0
    end

    test "FOR UPDATE SKIP LOCKED claim query runs" do
      org = org!()
      project = project!(org)

      {:ok, _} =
        %ReconcileOutbox{}
        |> ReconcileOutbox.changeset(%{
          aggregate: "project",
          aggregate_id: project.id,
          op: "create_tenant"
        })
        |> Repo.insert()

      q =
        from(r in ReconcileOutbox,
          where: r.status == "pending",
          order_by: [asc: r.created_at],
          limit: 10,
          lock: "FOR UPDATE SKIP LOCKED"
        )

      assert [%ReconcileOutbox{}] = Repo.all(q)
    end
  end

  # --- audit_logs -------------------------------------------------------

  describe "AuditLog.changeset/2" do
    test "requires action; bare binary_id columns accept ids without FK" do
      cs = AuditLog.changeset(%AuditLog{}, %{})
      assert %{action: ["can't be blank"]} = errors_on(cs)

      {:ok, log} =
        %AuditLog{}
        |> AuditLog.changeset(%{
          org_id: Ecto.UUID.generate(),
          actor_user_id: Ecto.UUID.generate(),
          action: "project.create",
          target: "proj_1",
          metadata: %{"ip" => "127.0.0.1"}
        })
        |> Repo.insert()

      assert log.action == "project.create"
      assert log.metadata == %{"ip" => "127.0.0.1"}
    end
  end
end
