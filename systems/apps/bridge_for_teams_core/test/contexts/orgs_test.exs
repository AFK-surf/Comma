defmodule BridgeForTeams.OrgsTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Memberships, Observability, Orgs, Projects}
  alias BridgeForTeams.Schema.{Organization, ReconcileOutbox}

  describe "create_org/1" do
    test "creates with name+slug" do
      assert {:ok, %Organization{} = org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
      assert org.name == "Acme"
      assert org.status == "active"
      assert SalixStore.Ids.valid_tenant_id?(org.salix_tenant_id)
      assert org.billing_account_id == "bridge-ba-" <> org.salix_tenant_id
    end

    test "enqueues tenant creation and tenant config ensure in order" do
      assert {:ok, %Organization{} = org} =
               Orgs.create_org(%{name: "Acme", slug: "acme-outbox"})

      rows =
        Repo.all(
          from(r in ReconcileOutbox,
            where: r.aggregate == "organization" and r.aggregate_id == ^org.id,
            order_by: [asc: r.created_at]
          )
        )

      assert Enum.map(rows, & &1.op) == ["create_tenant", "ensure_tenant_config"]

      [create_row, ensure_row] = rows
      assert create_row.payload["attrs"]["tenant_id"] == org.salix_tenant_id
      assert ensure_row.payload == %{"org_id" => org.id, "tenant_id" => org.salix_tenant_id}
    end

    test "defaults blank billing account to the current owner account" do
      assert {:ok, %Organization{} = org} =
               Orgs.create_org(%{
                 name: "Acme",
                 slug: "acme-blank-ba",
                 billing_account_id: " "
               })

      assert org.billing_account_id == "bridge-ba-" <> org.salix_tenant_id
    end

    test "does not require a started billing commerce repo" do
      previous_repo = SystemsRuntime.get_env(:billing_commerce, :repo)
      SystemsRuntime.put_env(:billing_commerce, :repo, __MODULE__.UnstartedBillingRepo)

      on_exit(fn ->
        if is_nil(previous_repo) do
          SystemsRuntime.delete_env(:billing_commerce, :repo)
        else
          SystemsRuntime.put_env(:billing_commerce, :repo, previous_repo)
        end
      end)

      assert {:ok, %Organization{} = org} =
               Orgs.create_org(%{name: "No Billing", slug: "no-billing"})

      assert org.billing_account_id == "bridge-ba-" <> org.salix_tenant_id
      assert default_entitlement_count(org.billing_account_id) == 0
    end
  end

  describe "lookups" do
  end

  test "update_org/2" do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    assert {:ok, updated} = Orgs.update_org(org, %{name: "Acme Inc"})
    assert updated.name == "Acme Inc"
  end

  test "update_org/2 does not switch billing accounts" do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    {:ok, project} = Projects.create_project(org.id, %{name: "P", slug: "p"})

    assert {:ok, updated} = Orgs.update_org(org, %{billing_account_id: "bridge-ba-new"})
    assert updated.billing_account_id == org.billing_account_id

    rows =
      ReconcileOutbox
      |> Repo.all()
      |> Enum.filter(
        &(&1.op == "update_group" and &1.aggregate_id == project.id and
            get_in(&1.payload, ["attrs", "billing_owner", "billing_account_id"]) ==
              "bridge-ba-new")
      )

    assert rows == []
  end

  test "list_orgs_for_user/1 returns only orgs the user is a member of" do
    {:ok, org1} = Orgs.create_org(%{name: "One", slug: "one"})
    {:ok, _org2} = Orgs.create_org(%{name: "Two", slug: "two"})
    {:ok, user} = Accounts.create_user(%{email: "u@example.com"})
    {:ok, _} = Memberships.put_org_member(org1.id, user.id, "owner")

    assert [found] = Orgs.list_orgs_for_user(user.id)
    assert found.id == org1.id
  end

  describe "SSO connections" do
    test "persists only safe Feishu provider config keys" do
      {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})

      assert {:ok, sso} =
               Orgs.upsert_sso_connection(org.id, %{
                 provider: "feishu",
                 client_id: "feishu-app",
                 client_secret: "feishu-secret",
                 provider_config: %{
                   scope: "contact:user.base:readonly",
                   tenant_key: "tenant-abc",
                   provisioning_policy: "existing_identity",
                   authorize_endpoint: "http://127.0.0.1:1/authorize",
                   token_endpoint: "http://127.0.0.1:1/token",
                   user_info_endpoint: "http://127.0.0.1:1/user_info"
                 }
               })

      assert sso.provider_config == %{
               "scope" => "contact:user.base:readonly",
               "tenant_key" => "tenant-abc",
               "provisioning_policy" => "existing_identity"
             }
    end

    test "requires a Feishu client secret for a usable SSO connection" do
      {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
      {:ok, actor} = Accounts.create_user(%{email: "sso-owner@example.com"})

      assert {:error, changeset} =
               Orgs.upsert_sso_connection(
                 org.id,
                 %{
                   provider: "feishu",
                   client_id: "feishu-app"
                 },
                 actor_user_id: actor.id,
                 actor_label: actor.email,
                 request_id: "req_sso_failed"
               )

      assert %{client_secret: ["can't be blank"]} = errors_on(changeset)

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "sso_connection.created",
                 result: "failed"
               )

      assert audit.actor_user_id == actor.id
      assert audit.resource_label == "feishu"
      assert audit.reason_class == "validation_failed"
      assert audit.request_id == "req_sso_failed"
      assert audit.metadata["write_attempt"] == "true"
      assert audit.metadata["surface"] == "sso"
      assert audit.metadata["client_id_configured"] == "true"
      assert audit.metadata["credential_submitted"] == "false"
      assert audit.metadata["credential_configured"] == "false"
      assert audit.metadata["error_fields"] == ["client_secret"]

      assert [audit_event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert audit_event.event_type == "audit.sso_connection.created"
      assert audit_event.severity == "error"
      assert audit_event.status == "failed"
      assert audit_event.reason_class == "validation_failed"
      assert audit_event.correlation_id == "req_sso_failed"

      assert [event] =
               Observability.list_events(org.id,
                 domain: "integration",
                 resource_type: "sso_connection"
               )

      assert event.actor_user_id == actor.id
      assert event.event_type == "sso.validation.failed"
      assert event.status == "fail"
      assert event.severity == "error"
      assert event.reason_class == "changeset_invalid"
      assert event.evidence["settings_path"] == "settings/sso"
      assert event.evidence["field_errors"]["credential"] == ["can't be blank"]
    end

    test "upsert and delete record SSO audit without leaking the client secret" do
      {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
      {:ok, actor} = Accounts.create_user(%{email: "owner@example.com"})

      assert {:ok, sso} =
               Orgs.upsert_sso_connection(
                 org.id,
                 %{
                   issuer: "https://idp.example.com",
                   client_id: "client-abc",
                   client_secret: "s3cret",
                   allowed_domains: "example.com",
                   default_role: "admin"
                 },
                 actor_user_id: actor.id,
                 actor_label: actor.email
               )

      assert [created] =
               Observability.list_audit_logs(org.id, action: "sso_connection.created")

      assert created.resource_id == sso.id
      assert created.metadata["credential_changed"] == "true"

      assert created.redacted_diff["credential_configured"] == %{
               "from" => "false",
               "to" => "true"
             }

      refute inspect(created) =~ "s3cret"

      assert {:ok, _deleted} =
               Orgs.delete_sso_connection(org.id,
                 actor_user_id: actor.id,
                 actor_label: actor.email
               )

      assert [deleted] =
               Observability.list_audit_logs(org.id, action: "sso_connection.deleted")

      assert deleted.resource_id == sso.id
      assert deleted.metadata["credential_configured"] == "true"
      refute inspect(deleted) =~ "s3cret"
    end
  end

  defp default_entitlement_count(account_id) do
    {:ok, count, _started} =
      Ecto.Migrator.with_repo(BillingCore.Repo, fn repo ->
        Ecto.Adapters.SQL.query!(
          repo,
          """
          SELECT count(*)
          FROM credit_grants
          WHERE billing_account_id = $1 AND source_type = 'default_entitlement'
          """,
          [account_id]
        ).rows
        |> hd()
        |> hd()
      end)

    count
  end
end
