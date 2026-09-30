defmodule BridgeForTeams.FeishuAppBindingsTest do
  # async: false — the bot fan-out swaps the global `:salix_client` app env, so
  # these tests can't run concurrently with other suites that read it (same
  # convention as OrgOAuthAppsTest).
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{FeishuAppBindings, Observability, Orgs}

  defmodule CapturingSalixClient do
    @moduledoc false
    # Records the tenant id + attrs the bot fan-out forwards to Salix so a test
    # can assert the erpc was called with the right shape. Returns the public
    # view (secrets stripped), mirroring Salix.Control.Tenants.put_feishu_tenant_app/2.
    def put_feishu_tenant_app(tenant_id, attrs) do
      send(self(), {:put_feishu_tenant_app, tenant_id, attrs})

      {:ok,
       %{
         "tenant_id" => tenant_id,
         "app_id" => attrs["app_id"],
         "app_secret_configured" => Map.has_key?(attrs, "app_secret"),
         "verification_token_configured" => Map.has_key?(attrs, "verification_token"),
         "encrypt_key_configured" => Map.has_key?(attrs, "encrypt_key")
       }}
    end

    def delete_feishu_tenant_app(tenant_id) do
      send(self(), {:delete_feishu_tenant_app, tenant_id})
      :ok
    end
  end

  defmodule UnavailableSalixClient do
    @moduledoc false
    def put_feishu_tenant_app(_tenant_id, _attrs), do: {:error, :unavailable}
    def delete_feishu_tenant_app(_tenant_id), do: {:error, :unavailable}
  end

  setup do
    # Default every test onto the capturing client: any binding that enables bot
    # with a secret will record its erpc call rather than attempt a real :erpc.
    with_client(CapturingSalixClient)
    :ok
  end

  defp with_client(mod) do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, mod)
    on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev) end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp org! do
    {:ok, org} = Orgs.create_org(%{name: "Co", slug: "co-#{System.unique_integer([:positive])}"})
    org
  end

  test "upsert creates a binding and derives configured flags from provided secrets" do
    org = org!()

    assert {:ok, binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_abc",
               "display_name" => "Co Feishu",
               "sso_enabled" => true,
               "bot_enabled" => true,
               "app_secret" => "s3cret",
               "verification_token" => "vtok"
             })

    assert binding.app_id == "cli_abc"
    assert binding.display_name == "Co Feishu"
    assert binding.sso_enabled and binding.bot_enabled
    assert binding.app_secret_configured
    assert binding.verification_token_configured
    refute binding.encrypt_key_configured
  end

  test "upsert and delete can record a redacted audit trail" do
    org = org!()

    assert {:ok, binding} =
             FeishuAppBindings.upsert_binding(
               org.id,
               %{
                 "app_id" => "cli_audit",
                 "display_name" => "Audit Feishu",
                 "sso_enabled" => true,
                 "bot_enabled" => true,
                 "app_secret" => "s3cret",
                 "verification_token" => "vtok"
               },
               actor_label: "owner@example.com"
             )

    assert [created] =
             Observability.list_audit_logs(org.id, action: "feishu_app_binding.created")

    assert created.resource_id == binding.id

    assert Enum.sort(created.metadata["submitted_credential_fields"]) == [
             "app_credential",
             "verification_credential"
           ]

    assert created.redacted_diff["app_credential_configured"] == %{"from" => nil, "to" => "true"}
    refute inspect(created) =~ "s3cret"
    refute inspect(created) =~ "vtok"

    assert {:ok, updated} =
             FeishuAppBindings.upsert_binding(
               org.id,
               %{
                 "id" => binding.id,
                 "display_name" => "Audit Feishu Renamed",
                 "sso_enabled" => false,
                 "bot_enabled" => false
               },
               actor_label: "owner@example.com"
             )

    assert [update] =
             Observability.list_audit_logs(org.id, action: "feishu_app_binding.updated")

    assert update.resource_id == updated.id

    assert update.redacted_diff["display_name"] == %{
             "from" => "Audit Feishu",
             "to" => "Audit Feishu Renamed"
           }

    assert {:ok, _deleted} =
             FeishuAppBindings.delete_binding(org.id, binding.id,
               actor_label: "owner@example.com"
             )

    assert [deleted] =
             Observability.list_audit_logs(org.id, action: "feishu_app_binding.deleted")

    assert deleted.resource_id == binding.id
  end

  test "re-saving an SSO binding without scope preserves the connection's provider_config (B1)" do
    org = org!()

    {:ok, _} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_cfg",
        "sso_enabled" => true,
        "app_secret" => "s",
        "scope" => "contact:user.base:readonly contact:contact.base:readonly"
      })

    # The SSO card sets a tenant_key + provisioning_policy the binding form never sees.
    {:ok, _} =
      Orgs.upsert_sso_connection(org.id, %{
        "provider" => "feishu",
        "client_id" => "cli_cfg",
        "client_secret" => "s",
        "provider_config" => %{
          "tenant_key" => "tnt_123",
          "provisioning_policy" => "existing_identity"
        }
      })

    # A routine re-save (rename) that omits scope must NOT reset scope to the
    # default or wipe tenant_key / provisioning_policy.
    {:ok, _} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_cfg",
        "display_name" => "Renamed",
        "sso_enabled" => true,
        "app_secret" => ""
      })

    cfg = Orgs.get_sso_connection(org.id).provider_config
    assert cfg["scope"] == "contact:user.base:readonly contact:contact.base:readonly"
    assert cfg["tenant_key"] == "tnt_123"
    assert cfg["provisioning_policy"] == "existing_identity"
  end

  test "re-upsert keeps configured flags when the secret is left blank (write-only keep)" do
    org = org!()

    {:ok, _} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_x",
        "sso_enabled" => true,
        "app_secret" => "s"
      })

    assert {:ok, binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_x",
               "display_name" => "Renamed",
               "sso_enabled" => true,
               "app_secret" => ""
             })

    assert binding.display_name == "Renamed"
    assert binding.app_secret_configured
  end

  test "list_bindings + get_binding_for_app are org-scoped" do
    org = org!()
    other = org!()
    {:ok, b} = FeishuAppBindings.upsert_binding(org.id, %{"app_id" => "cli_1"})

    assert [listed] = FeishuAppBindings.list_bindings(org.id)
    assert listed.id == b.id
    assert FeishuAppBindings.list_bindings(other.id) == []
    assert FeishuAppBindings.get_binding_for_app(org.id, "cli_1").id == b.id
    assert is_nil(FeishuAppBindings.get_binding_for_app(org.id, "nope"))
    assert is_nil(FeishuAppBindings.get_binding_for_app(other.id, "cli_1"))
  end

  test "requires app_id" do
    org = org!()
    assert {:error, cs} = FeishuAppBindings.upsert_binding(org.id, %{"display_name" => "x"})
    assert %{app_id: _} = errors_on(cs)
  end

  test "validation failures record redacted Feishu Operations events" do
    org = org!()

    assert {:error, {:missing_bot_secret, :app_secret}} =
             FeishuAppBindings.upsert_binding(
               org.id,
               %{
                 "app_id" => "cli_no_secret",
                 "bot_enabled" => true,
                 "verification_token" => "verification-secret"
               },
               actor_label: "owner@example.com",
               request_id: "req_feishu_validation_failed"
             )

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "feishu_app_binding.created",
               result: "failed"
             )

    assert audit.resource_label == "cli_no_secret"
    assert audit.reason_class == "missing_bot_secret"
    assert audit.request_id == "req_feishu_validation_failed"
    assert audit.metadata["write_attempt"] == "true"
    assert audit.metadata["surface"] == "feishu"
    assert audit.metadata["app_id"] == "cli_no_secret"
    assert audit.metadata["bot_enabled"] == "true"
    assert audit.metadata["submitted_credential_fields"] == ["verification_credential"]

    assert [audit_event] = Observability.list_events(org.id, audit_log_id: audit.id)
    assert audit_event.event_type == "audit.feishu_app_binding.created"
    assert audit_event.severity == "error"
    assert audit_event.status == "failed"
    assert audit_event.reason_class == "missing_bot_secret"
    assert audit_event.correlation_id == "req_feishu_validation_failed"

    assert [event] =
             Observability.list_events(org.id,
               domain: "integration",
               resource_type: "feishu_app_binding"
             )

    assert event.event_type == "feishu.validation.failed"
    assert event.status == "fail"
    assert event.reason_class == "missing_bot_secret"
    assert event.evidence["settings_path"] == "settings/feishu"
    assert event.evidence["app_id"] == "cli_no_secret"
    assert event.evidence["submitted_credential_fields"] == ["verification_credential"]
    refute inspect([audit, audit_event, event]) =~ "verification-secret"
  end

  test "enabling SSO fans the credentials out to the org Feishu SSO connection" do
    org = org!()

    assert {:ok, _binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_sso",
               "sso_enabled" => true,
               "app_secret" => "s3cret"
             })

    sso = Orgs.get_sso_connection(org.id)
    assert sso.provider == "feishu"
    assert sso.client_id == "cli_sso"
    assert sso.client_secret == "s3cret"
  end

  test "SSO fan-out audits share the Feishu binding request id" do
    org = org!()
    request_id = "req_feishu_sso_fanout"

    assert {:ok, binding} =
             FeishuAppBindings.upsert_binding(
               org.id,
               %{
                 "app_id" => "cli_sso_audit",
                 "sso_enabled" => true,
                 "app_secret" => "s3cret"
               },
               actor_label: "owner@example.com",
               request_id: request_id
             )

    sso = Orgs.get_sso_connection(org.id)
    assert sso.provider == "feishu"
    assert sso.client_id == "cli_sso_audit"

    assert [binding_audit] =
             Observability.list_audit_logs(org.id,
               action: "feishu_app_binding.created",
               request_id: request_id
             )

    assert binding_audit.resource_id == binding.id

    assert [sso_audit] =
             Observability.list_audit_logs(org.id,
               action: "sso_connection.created",
               request_id: request_id
             )

    assert sso_audit.resource_id == sso.id
    assert sso_audit.metadata["provider"] == "feishu"
    assert sso_audit.metadata["client_id"] == "cli_sso_audit"
    assert sso_audit.metadata["credential_changed"] == "true"
    refute inspect([binding_audit, sso_audit]) =~ "s3cret"

    delete_request_id = "req_feishu_sso_fanout_delete"

    assert {:ok, _updated} =
             FeishuAppBindings.upsert_binding(
               org.id,
               %{
                 "id" => binding.id,
                 "sso_enabled" => false,
                 "bot_enabled" => false
               },
               actor_label: "owner@example.com",
               request_id: delete_request_id
             )

    assert is_nil(Orgs.get_sso_connection(org.id))

    assert [_binding_update] =
             Observability.list_audit_logs(org.id,
               action: "feishu_app_binding.updated",
               request_id: delete_request_id
             )

    assert [sso_delete] =
             Observability.list_audit_logs(org.id,
               action: "sso_connection.deleted",
               request_id: delete_request_id
             )

    assert sso_delete.resource_id == sso.id
    assert sso_delete.metadata["provider"] == "feishu"
  end

  test "enabling a new SSO binding replaces the previous active Feishu SSO app" do
    org = org!()

    assert {:ok, old_binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_old_sso",
               "sso_enabled" => true,
               "app_secret" => "old-secret"
             })

    assert {:ok, new_binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_new_sso",
               "sso_enabled" => true,
               "app_secret" => "new-secret"
             })

    {:ok, old_binding} = FeishuAppBindings.get_binding(org.id, old_binding.id)
    {:ok, new_binding} = FeishuAppBindings.get_binding(org.id, new_binding.id)

    refute old_binding.sso_enabled
    assert new_binding.sso_enabled

    sso = Orgs.get_sso_connection(org.id)
    assert sso.provider == "feishu"
    assert sso.client_id == "cli_new_sso"
    assert sso.client_secret == "new-secret"
  end

  test "a bot-only binding does not create an SSO connection" do
    org = org!()

    {:ok, _} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_botonly",
        "bot_enabled" => true,
        "app_secret" => "botsecret"
      })

    assert is_nil(Orgs.get_sso_connection(org.id))
  end

  test "enabling bot with a secret fans the bot app out to the org's Salix tenant" do
    org = org!()

    assert {:ok, _binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_bot",
               "bot_enabled" => true,
               "app_secret" => "botsecret",
               "verification_token" => "vtok",
               "encrypt_key" => "ek"
             })

    # The bot secret VALUES go to Salix, keyed by the org's tenant id; the binding
    # row only keeps the non-secret `*_configured` posture.
    assert_received {:put_feishu_tenant_app, tenant_id, attrs}
    assert tenant_id == org.salix_tenant_id
    assert attrs["app_id"] == "cli_bot"
    assert attrs["app_secret"] == "botsecret"
    assert attrs["verification_token"] == "vtok"
    assert attrs["encrypt_key"] == "ek"
  end

  test "a bot-only binding without any app secret is rejected before saving" do
    org = org!()

    assert {:error, {:missing_bot_secret, :app_secret}} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_nosecret",
               "bot_enabled" => true
             })

    refute_received {:put_feishu_tenant_app, _tenant_id, _attrs}
    assert is_nil(Orgs.get_sso_connection(org.id))
    assert is_nil(FeishuAppBindings.get_binding_for_app(org.id, "cli_nosecret"))
  end

  test "a blank optional secret is dropped so Salix's pointer-merge keeps the stored one" do
    org = org!()

    assert {:ok, _binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_blank",
               "bot_enabled" => true,
               "app_secret" => "botsecret",
               "verification_token" => "   ",
               "encrypt_key" => ""
             })

    assert_received {:put_feishu_tenant_app, _tenant_id, attrs}
    assert attrs["app_secret"] == "botsecret"
    refute Map.has_key?(attrs, "verification_token")
    refute Map.has_key?(attrs, "encrypt_key")
  end

  test "rotating bot verification token does not require re-entering the app secret" do
    org = org!()

    assert {:ok, _binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_rotate_token",
               "bot_enabled" => true,
               "app_secret" => "botsecret"
             })

    assert_received {:put_feishu_tenant_app, _tenant_id, _attrs}

    assert {:ok, _binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_rotate_token",
               "bot_enabled" => true,
               "verification_token" => "new-vtok"
             })

    assert_received {:put_feishu_tenant_app, tenant_id, attrs}
    assert tenant_id == org.salix_tenant_id
    assert attrs["app_id"] == "cli_rotate_token"
    assert attrs["verification_token"] == "new-vtok"
    refute Map.has_key?(attrs, "app_secret")
    refute Map.has_key?(attrs, "encrypt_key")
  end

  test "enabling bot on an SSO binding fans out the existing SSO app secret" do
    org = org!()

    assert {:ok, _binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_sso_to_bot",
               "sso_enabled" => true,
               "app_secret" => "sso-secret"
             })

    refute_received {:put_feishu_tenant_app, _tenant_id, _attrs}

    assert {:ok, binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_sso_to_bot",
               "sso_enabled" => true,
               "bot_enabled" => true,
               "app_secret" => ""
             })

    assert binding.bot_enabled
    assert binding.app_secret_configured

    assert %{app_secret_configured: true} =
             FeishuAppBindings.get_binding_for_app(org.id, "cli_sso_to_bot")

    assert_received {:put_feishu_tenant_app, tenant_id, attrs}
    assert tenant_id == org.salix_tenant_id
    assert attrs["app_id"] == "cli_sso_to_bot"
    assert attrs["app_secret"] == "sso-secret"
  end

  test "only one Feishu app can be bot-enabled per org until multi-route support lands" do
    org = org!()

    assert {:ok, _binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_bot_one",
               "bot_enabled" => true,
               "app_secret" => "first-secret"
             })

    assert {:error, :bot_app_already_enabled} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_bot_two",
               "bot_enabled" => true,
               "app_secret" => "second-secret"
             })

    refute FeishuAppBindings.get_binding_for_app(org.id, "cli_bot_two")
  end

  test "an SSO-only binding does not fan out to the bot store" do
    org = org!()

    assert {:ok, _binding} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "app_id" => "cli_ssoonly",
               "sso_enabled" => true,
               "app_secret" => "s3cret"
             })

    refute_received {:put_feishu_tenant_app, _tenant_id, _attrs}
  end

  test "editing by id keeps the app id immutable" do
    org = org!()

    {:ok, binding} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_original",
        "sso_enabled" => true,
        "app_secret" => "s3cret"
      })

    assert {:error, :app_id_immutable} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "id" => binding.id,
               "app_id" => "cli_other",
               "sso_enabled" => true
             })

    assert FeishuAppBindings.get_binding_for_app(org.id, "cli_original")
    refute FeishuAppBindings.get_binding_for_app(org.id, "cli_other")
  end

  test "disabling SSO on a binding deletes the matching SSO connection" do
    org = org!()

    {:ok, binding} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_disable_sso",
        "sso_enabled" => true,
        "app_secret" => "s3cret"
      })

    assert Orgs.get_sso_connection(org.id).client_id == "cli_disable_sso"

    assert {:ok, updated} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "id" => binding.id,
               "app_id" => "cli_disable_sso",
               "display_name" => "No SSO",
               "sso_enabled" => false,
               "bot_enabled" => false
             })

    refute updated.sso_enabled
    assert is_nil(Orgs.get_sso_connection(org.id))
  end

  test "enabling Feishu SSO does not overwrite an existing generic OIDC connection" do
    org = org!()
    request_id = "req_feishu_sso_provider_conflict"

    {:ok, oidc} =
      Orgs.upsert_sso_connection(org.id, %{
        "provider" => "generic_oidc",
        "issuer" => "https://accounts.google.com",
        "client_id" => "google-client",
        "client_secret" => "google-secret",
        "allowed_domains" => ["comma.surf"]
      })

    assert {:error, {:sso_provider_conflict, "generic_oidc"}} =
             FeishuAppBindings.upsert_binding(
               org.id,
               %{
                 "app_id" => "cli_google_org",
                 "sso_enabled" => true,
                 "app_secret" => "feishu-secret"
               },
               actor_label: "owner@example.com",
               request_id: request_id
             )

    assert %{
             provider: "generic_oidc",
             issuer: "https://accounts.google.com",
             client_id: "google-client"
           } = Orgs.get_sso_connection(org.id)

    refute FeishuAppBindings.get_binding_for_app(org.id, "cli_google_org")
    assert Orgs.get_sso_connection(org.id).id == oidc.id

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "feishu_app_binding.created",
               result: "failed",
               request_id: request_id
             )

    assert audit.reason_class == "sso_provider_conflict"
    assert audit.resource_label == "cli_google_org"
    assert audit.metadata["existing_sso_provider"] == "generic_oidc"
    assert audit.metadata["sso_enabled"] == "true"
    assert audit.metadata["submitted_credential_fields"] == ["app_credential"]

    assert [audit_event] = Observability.list_events(org.id, audit_log_id: audit.id)
    assert audit_event.event_type == "audit.feishu_app_binding.created"
    assert audit_event.status == "failed"
    assert audit_event.reason_class == "sso_provider_conflict"
    assert audit_event.correlation_id == request_id
    refute inspect([audit, audit_event]) =~ "feishu-secret"
  end

  test "partial edits inherit existing capability flags instead of disabling stores" do
    org = org!()

    {:ok, binding} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_partial",
        "display_name" => "Comma",
        "sso_enabled" => true,
        "bot_enabled" => true,
        "app_secret" => "shared-secret",
        "verification_token" => "vtok"
      })

    assert_received {:put_feishu_tenant_app, _tenant_id, _attrs}
    assert Orgs.get_sso_connection(org.id).client_id == "cli_partial"

    assert {:ok, updated} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "id" => binding.id,
               "display_name" => "Comma renamed",
               "verification_token" => "rotated-vtok"
             })

    assert updated.display_name == "Comma renamed"
    assert updated.sso_enabled
    assert updated.bot_enabled
    assert updated.app_secret_configured
    assert updated.verification_token_configured
    assert Orgs.get_sso_connection(org.id).client_id == "cli_partial"

    assert_received {:put_feishu_tenant_app, tenant_id,
                     %{
                       "app_id" => "cli_partial",
                       "verification_token" => "rotated-vtok"
                     }}

    assert tenant_id == org.salix_tenant_id
    refute_received {:delete_feishu_tenant_app, _tenant_id}
  end

  test "disabling bot deletes the tenant Feishu app store" do
    org = org!()

    {:ok, binding} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_disable_bot",
        "bot_enabled" => true,
        "app_secret" => "botsecret",
        "verification_token" => "vtok"
      })

    assert_received {:put_feishu_tenant_app, _tenant_id, _attrs}

    assert {:ok, updated} =
             FeishuAppBindings.upsert_binding(org.id, %{
               "id" => binding.id,
               "app_id" => "cli_disable_bot",
               "bot_enabled" => false,
               "sso_enabled" => false
             })

    refute updated.bot_enabled
    refute updated.app_secret_configured
    refute updated.verification_token_configured
    assert_received {:delete_feishu_tenant_app, tenant_id}
    assert tenant_id == org.salix_tenant_id
  end

  test "delete_binding removes binding, matching SSO connection, and tenant bot store" do
    org = org!()

    {:ok, binding} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_delete",
        "sso_enabled" => true,
        "bot_enabled" => true,
        "app_secret" => "shared-secret"
      })

    assert_received {:put_feishu_tenant_app, _tenant_id, _attrs}
    assert Orgs.get_sso_connection(org.id).client_id == "cli_delete"

    assert {:ok, deleted} = FeishuAppBindings.delete_binding(org.id, binding.id)

    assert deleted.id == binding.id
    assert is_nil(FeishuAppBindings.get_binding_for_app(org.id, "cli_delete"))
    assert is_nil(Orgs.get_sso_connection(org.id))
    assert_received {:delete_feishu_tenant_app, tenant_id}
    assert tenant_id == org.salix_tenant_id
  end

  test "a bot fan-out erpc failure surfaces as an error (the binding has already committed)" do
    org = org!()
    with_client(UnavailableSalixClient)

    assert {:error, {:bot_fan_out, :unavailable}} =
             FeishuAppBindings.upsert_binding(
               org.id,
               %{
                 "app_id" => "cli_fail",
                 "bot_enabled" => true,
                 "app_secret" => "botsecret"
               },
               actor_label: "owner@example.com",
               request_id: "req_feishu_bot_fan_out_failed"
             )

    # The binding row committed before the (failed) fan-out, so it persists; a
    # later rotate re-attempts the fan-out idempotently.
    assert binding = FeishuAppBindings.get_binding_for_app(org.id, "cli_fail")
    assert binding.bot_enabled

    assert [audit] =
             Observability.list_audit_logs(org.id, request_id: "req_feishu_bot_fan_out_failed")

    assert audit.action == "feishu_app_binding.created"
    assert audit.result == "failed"
    assert audit.reason_class == "bot_fan_out"
    assert audit.resource_id == binding.id
    assert audit.metadata["app_id"] == "cli_fail"
    assert audit.metadata["submitted_credential_fields"] == ["app_credential"]

    assert [audit_event] = Observability.list_events(org.id, audit_log_id: audit.id)
    assert audit_event.event_type == "audit.feishu_app_binding.created"
    assert audit_event.severity == "error"
    assert audit_event.status == "failed"
    assert audit_event.reason_class == "bot_fan_out"
  end

  test "delete_binding records failed write attempts when bot cleanup fails" do
    org = org!()

    {:ok, binding} =
      FeishuAppBindings.upsert_binding(org.id, %{
        "app_id" => "cli_delete_fail",
        "bot_enabled" => true,
        "app_secret" => "botsecret"
      })

    assert_received {:put_feishu_tenant_app, _tenant_id, _attrs}
    with_client(UnavailableSalixClient)

    assert {:error, {:bot_delete, :unavailable}} =
             FeishuAppBindings.delete_binding(org.id, binding.id,
               actor_label: "owner@example.com",
               request_id: "req_feishu_delete_failed"
             )

    assert [audit] = Observability.list_audit_logs(org.id, request_id: "req_feishu_delete_failed")
    assert audit.action == "feishu_app_binding.deleted"
    assert audit.result == "failed"
    assert audit.reason_class == "bot_delete"
    assert audit.resource_id == binding.id
  end
end
