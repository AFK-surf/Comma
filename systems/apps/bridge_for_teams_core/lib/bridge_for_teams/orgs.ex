defmodule BridgeForTeams.Orgs do
  @moduledoc """
  Organization context (design §6.1). An org maps 1:1 onto a Salix **tenant**
  (the IM/OAuth/API-key isolation root); creating one assigns
  a canonical Salix tenant id and enqueues a create-tenant reconcile row in
  the same Ecto transaction as the row insert (transactional outbox).
  """
  import Ecto.Query
  require Logger

  alias BridgeForTeams.{Observability, Outbox, Repo}
  alias BridgeForTeams.Salix.Identity
  alias BridgeForTeams.Salix.TenantConfig
  alias BridgeForTeams.Schema.{Organization, OrgMembership, OrgSsoConnection, Project}
  alias SalixStore.Ids

  @doc "Create an organization (allocates its Salix tenant + enqueues reconcile)."
  @spec create_org(map()) :: {:ok, Organization.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_org(attrs) do
    attrs = normalize_attrs(attrs)
    Identity.retry_generated(fn -> create_org_once(attrs) end, [:salix_tenant_id])
  end

  defp create_org_once(attrs) do
    tenant_id = Ids.new_tenant_id()

    attrs =
      attrs
      |> Map.put("salix_tenant_id", tenant_id)
      |> put_default_billing_account_id(tenant_id)

    changeset = Organization.changeset(%Organization{}, attrs)

    Repo.transaction(fn ->
      case Repo.insert(changeset) do
        {:ok, org} ->
          outbox_base = DateTime.utc_now()

          with :ok <-
                 BillingCore.Accounts.ensure_account(%{
                   billing_account_id: org.billing_account_id,
                   surface: "bridge",
                   product_owner_type: "organization",
                   product_owner_id: org.id
                 }),
               :ok <- enqueue_create_tenant(org, DateTime.add(outbox_base, 0, :microsecond)),
               :ok <-
                 TenantConfig.enqueue_ensure_tenant_config(org,
                   created_at: DateTime.add(outbox_base, 1, :microsecond)
                 ),
               {:ok, _default_entitlement} <- issue_default_entitlement(org) do
            org
          else
            {:error, reason} ->
              Repo.rollback(reason)
          end

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  defp issue_default_entitlement(%Organization{} = org) do
    if billing_commerce_repo_started?() do
      BillingCommerce.issue_bridge_platform_unlimited(%{
        billing_account_id: org.billing_account_id,
        organization_id: org.id,
        product_owner_type: "organization",
        product_owner_id: org.id
      })
    else
      {:ok, %{skipped: :billing_commerce_repo_not_started}}
    end
  end

  defp billing_commerce_repo_started? do
    case Application.get_env(:billing_commerce, :repo) do
      repo when is_atom(repo) -> Process.whereis(repo) != nil
      _repo -> false
    end
  end

  defp enqueue_create_tenant(%Organization{} = org, created_at) do
    payload = %{"attrs" => %{"tenant_id" => org.salix_tenant_id, "name" => org.name}}

    {:ok, _} =
      Outbox.enqueue("organization", org.id, "create_tenant", payload, created_at: created_at)

    :ok
  end

  defp enqueue_group_billing_owner_updates(%Organization{} = org) do
    projects =
      from(p in Project,
        where: p.org_id == ^org.id and is_nil(p.archived_at),
        preload: [:agents]
      )
      |> Repo.all()

    Enum.each(projects, fn project ->
      router =
        Enum.find(project.agents, fn agent ->
          agent.slot == "router" and
            not is_nil(agent.salix_agent_id)
        end) ||
          Enum.find(project.agents, fn agent ->
            agent.role == "router" and
              not is_nil(agent.salix_agent_id)
          end)

      if router do
        payload = %{
          "group_id" => project.salix_group_id,
          "tenant_id" => org.salix_tenant_id,
          "attrs" => %{
            "billing_owner" => group_billing_owner(org, project, router.salix_agent_id)
          }
        }

        {:ok, _} = Outbox.enqueue("project", project.id, "update_group", payload)
      end
    end)
  end

  defp group_billing_owner(%Organization{} = org, %Project{} = project, router_agent_id) do
    %{
      "billing_account_id" => org.billing_account_id,
      "surface" => "bridge",
      "vm_profile_key" => "cf-standard-2",
      "product_owner_type" => "organization",
      "product_owner_id" => org.id,
      "project_id" => project.id,
      "salix_tenant_id" => org.salix_tenant_id,
      "salix_group_id" => project.salix_group_id,
      "router_agent_id" => router_agent_id,
      "charge_policy" => "platform_paid"
    }
  end

  @doc "Fetch an organization by id."
  @spec get_org(Ecto.UUID.t()) :: {:ok, Organization.t()} | {:error, :not_found}
  def get_org(id) do
    case Repo.get(Organization, id) do
      nil -> {:error, :not_found}
      org -> {:ok, org}
    end
  end

  @doc "Fetch an organization by slug."
  @spec get_org_by_slug(String.t()) :: {:ok, Organization.t()} | {:error, :not_found}
  def get_org_by_slug(slug) do
    case Repo.get_by(Organization, slug: slug) do
      nil -> {:error, :not_found}
      org -> {:ok, org}
    end
  end

  @doc "Fetch an organization by its Salix tenant id."
  @spec get_org_by_salix_tenant_id(String.t()) :: {:ok, Organization.t()} | {:error, :not_found}
  def get_org_by_salix_tenant_id(tenant_id) do
    case Repo.get_by(Organization, salix_tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      org -> {:ok, org}
    end
  end

  @doc "Update an organization."
  @spec update_org(Organization.t(), map(), keyword()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def update_org(%Organization{} = org, attrs, opts \\ []) do
    attrs =
      attrs
      |> normalize_attrs()
      |> preserve_billing_account(org)

    changeset = Organization.changeset(org, attrs)

    result =
      Repo.transaction(fn ->
        with {:ok, updated} <- Repo.update(changeset),
             :ok <- maybe_enqueue_billing_owner_updates(org, updated),
             :ok <- maybe_enqueue_worker_default(org, updated),
             {:ok, _audit} <- maybe_record_org_update_audit(org, updated, attrs, opts) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    maybe_record_model_validation_event(result, org, attrs, opts)
    maybe_record_org_update_write_attempt(result, org, attrs, opts)
    result
  end

  defp maybe_enqueue_worker_default(old, updated) do
    if old.default_template_id != updated.default_template_id or
         old.default_router_template_id != updated.default_router_template_id,
       do: TenantConfig.enqueue_ensure_tenant_config(updated),
       else: :ok
  end

  defp maybe_enqueue_billing_owner_updates(%Organization{} = old, %Organization{} = updated) do
    if old.billing_account_id != updated.billing_account_id do
      enqueue_group_billing_owner_updates(updated)
    end

    :ok
  end

  @doc "List organizations a user belongs to."
  @spec list_orgs_for_user(Ecto.UUID.t()) :: [Organization.t()]
  def list_orgs_for_user(user_id) do
    from(o in Organization,
      join: m in OrgMembership,
      on: m.org_id == o.id,
      where: m.user_id == ^user_id,
      order_by: [asc: o.name, asc: o.slug],
      distinct: true
    )
    |> Repo.all()
  end

  @doc "List organizations a user can manage as an owner or admin."
  @spec list_manageable_orgs_for_user(Ecto.UUID.t()) :: [Organization.t()]
  def list_manageable_orgs_for_user(user_id) do
    from(o in Organization,
      join: m in OrgMembership,
      on: m.org_id == o.id,
      where: m.user_id == ^user_id and m.role in ["owner", "admin"],
      order_by: [asc: o.name, asc: o.slug],
      distinct: true
    )
    |> Repo.all()
  end

  @doc "List organizations a user belongs to that have an SSO connection configured."
  @spec list_orgs_with_sso_for_user(Ecto.UUID.t()) :: [Organization.t()]
  def list_orgs_with_sso_for_user(user_id) do
    from(o in Organization,
      join: m in OrgMembership,
      on: m.org_id == o.id,
      join: sso in OrgSsoConnection,
      on: sso.org_id == o.id,
      where: m.user_id == ^user_id,
      order_by: [asc: o.name, asc: o.slug],
      distinct: true
    )
    |> Repo.all()
  end

  @doc """
  The default dashboard locale for a user's organizations, used to seed the
  locale of members without a personal preference. Returns the `default_locale`
  of the user's first org (alphabetical by name), or nil if none is set.
  """
  @spec default_locale_for_user(Ecto.UUID.t()) :: String.t() | nil
  def default_locale_for_user(user_id) do
    from(o in Organization,
      join: m in OrgMembership,
      on: m.org_id == o.id,
      where: m.user_id == ^user_id and not is_nil(o.default_locale),
      order_by: [asc: o.name],
      select: o.default_locale,
      limit: 1
    )
    |> Repo.one()
  end

  # ---- SSO connections (design §5 org_sso_connections, §7) ----

  @doc "Fetch the org's single SSO connection, if configured."
  @spec get_sso_connection(Ecto.UUID.t()) :: OrgSsoConnection.t() | nil
  def get_sso_connection(org_id) do
    Repo.get_by(OrgSsoConnection, org_id: org_id)
  end

  @doc """
  A changeset for the org's SSO connection (existing or new), suitable for a
  dashboard form. `client_secret` is a virtual, write-only field — never reflect
  the stored secret back into the form.
  """
  @spec change_sso_connection(OrgSsoConnection.t() | nil, map()) :: Ecto.Changeset.t()
  def change_sso_connection(conn, attrs \\ %{}) do
    OrgSsoConnection.changeset(conn || %OrgSsoConnection{}, attrs)
  end

  @doc """
  Create or update the org's SSO connection. Accepts a `"client_secret"`
  (stored as-is, no encryption at rest); a blank secret leaves the stored secret
  untouched when the provider is unchanged. `"allowed_domains"` may be a
  comma/whitespace-separated string or a list for generic OIDC.
  """
  @spec upsert_sso_connection(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, OrgSsoConnection.t()} | {:error, Ecto.Changeset.t()}
  def upsert_sso_connection(org_id, attrs, opts \\ []) do
    existing = get_sso_connection(org_id)

    attrs =
      attrs
      |> normalize_attrs()
      |> normalize_provider_config(existing)
      |> Map.put("org_id", org_id)
      |> put_secret(existing)
      |> normalize_domains()
      |> normalize_sso_provider_fields()

    changeset =
      (existing || %OrgSsoConnection{})
      |> OrgSsoConnection.changeset(attrs)

    result =
      if audit_enabled?(opts) do
        Repo.transaction(fn ->
          with {:ok, sso} <- Repo.insert_or_update(changeset),
               {:ok, _audit} <- record_sso_audit(org_id, existing, sso, attrs, opts) do
            sso
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      else
        Repo.insert_or_update(changeset)
      end

    maybe_record_sso_validation_event(result, org_id, existing, attrs, opts)
    maybe_record_sso_write_attempt(result, org_id, existing, attrs, opts)
    result
  end

  @doc "Delete the org's SSO connection, if one exists."
  @spec delete_sso_connection(Ecto.UUID.t(), keyword()) ::
          {:ok, OrgSsoConnection.t() | nil} | {:error, Ecto.Changeset.t()}
  def delete_sso_connection(org_id, opts \\ []) do
    case get_sso_connection(org_id) do
      nil ->
        {:ok, nil}

      %OrgSsoConnection{} = conn ->
        if audit_enabled?(opts) do
          Repo.transaction(fn ->
            with {:ok, deleted} <- Repo.delete(conn),
                 {:ok, _audit} <- record_sso_delete_audit(org_id, deleted, opts) do
              deleted
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
        else
          Repo.delete(conn)
        end
    end
  end

  defp maybe_record_org_update_audit(old, updated, attrs, opts) do
    if audit_enabled?(opts) do
      Observability.record_audit(%{
        org_id: updated.id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: org_update_action(attrs),
        resource_type: "organization_settings",
        resource_id: updated.id,
        resource_label: updated.name,
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: %{
          "org_id" => updated.id,
          "org_name" => updated.name,
          "org_slug" => updated.slug,
          "settings_surface" => org_settings_surface(attrs),
          "changed_fields" => Map.keys(org_update_diff(old, updated, attrs))
        },
        redacted_diff: org_update_diff(old, updated, attrs)
      })
    else
      {:ok, nil}
    end
  end

  @model_setting_fields ~w(allowed_template_ids default_template_id default_router_template_id)

  defp org_update_action(attrs) do
    if Enum.any?(Map.keys(attrs), &(&1 in @model_setting_fields)) do
      "org.model_settings.updated"
    else
      "org.settings.updated"
    end
  end

  defp org_settings_surface(attrs) do
    if Enum.any?(Map.keys(attrs), &(&1 in @model_setting_fields)) do
      "models"
    else
      "general"
    end
  end

  defp org_update_diff(old, updated, attrs) do
    attrs
    |> Map.keys()
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn field, acc ->
      old_value = org_audit_field(old, field)
      new_value = org_audit_field(updated, field)

      if old_value != new_value do
        Map.put(acc, field, %{"from" => old_value, "to" => new_value})
      else
        acc
      end
    end)
  end

  defp org_audit_field(%Organization{} = org, "name"), do: org.name
  defp org_audit_field(%Organization{} = org, "slug"), do: org.slug
  defp org_audit_field(%Organization{} = org, "default_locale"), do: org.default_locale
  defp org_audit_field(%Organization{} = org, "billing_account_id"), do: org.billing_account_id

  defp org_audit_field(%Organization{} = org, "allowed_template_ids"),
    do: org.allowed_template_ids || []

  defp org_audit_field(%Organization{} = org, "default_template_id"), do: org.default_template_id

  defp org_audit_field(%Organization{} = org, "default_router_template_id"),
    do: org.default_router_template_id

  defp org_audit_field(%Organization{} = org, "icon"), do: icon_audit_value(org.icon)
  defp org_audit_field(_org, _field), do: nil

  defp icon_audit_value(value) when is_binary(value) and value != "",
    do: %{"configured" => true, "bytes" => byte_size(value)}

  defp icon_audit_value(_value), do: %{"configured" => false}

  defp record_sso_audit(org_id, existing, %OrgSsoConnection{} = sso, attrs, opts) do
    Observability.record_audit(%{
      org_id: org_id,
      actor_user_id: Keyword.get(opts, :actor_user_id),
      actor_label: Keyword.get(opts, :actor_label),
      action: if(existing, do: "sso_connection.updated", else: "sso_connection.created"),
      resource_type: "sso_connection",
      resource_id: sso.id,
      resource_label: sso.provider,
      result: "ok",
      request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
      metadata: %{
        "provider" => sso.provider,
        "client_id" => sso.client_id,
        "default_role" => sso.default_role,
        "allowed_domains" => sso.allowed_domains || [],
        "credential_changed" => present?(attrs["client_secret"]),
        "credential_configured" => present?(sso.client_secret),
        "provider_config_keys" => Map.keys(sso.provider_config || %{})
      },
      redacted_diff: sso_diff(existing, sso, attrs)
    })
  end

  defp record_sso_delete_audit(org_id, %OrgSsoConnection{} = sso, opts) do
    Observability.record_audit(%{
      org_id: org_id,
      actor_user_id: Keyword.get(opts, :actor_user_id),
      actor_label: Keyword.get(opts, :actor_label),
      action: "sso_connection.deleted",
      resource_type: "sso_connection",
      resource_id: sso.id,
      resource_label: sso.provider,
      result: "ok",
      request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
      metadata: %{
        "provider" => sso.provider,
        "client_id" => sso.client_id,
        "default_role" => sso.default_role,
        "allowed_domains" => sso.allowed_domains || [],
        "credential_configured" => present?(sso.client_secret)
      },
      redacted_diff: %{"deleted" => %{"from" => false, "to" => true}}
    })
  end

  defp maybe_record_org_update_write_attempt({:error, reason}, %Organization{} = org, attrs, opts) do
    if audit_enabled?(opts) do
      record_write_attempt(%{
        org_id: org.id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: org_update_action(attrs),
        resource_type: "organization_settings",
        resource_id: org.id,
        resource_label: org.name,
        result: "failed",
        reason: reason,
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        surface: org_settings_surface(attrs),
        metadata: %{
          "org_id" => org.id,
          "settings_surface" => org_settings_surface(attrs),
          "changed_fields" => Map.keys(attrs)
        }
      })
    end
  end

  defp maybe_record_org_update_write_attempt(_result, _org, _attrs, _opts), do: :ok

  defp maybe_record_sso_write_attempt({:error, reason}, org_id, existing, attrs, opts) do
    if audit_enabled?(opts) do
      action = if(existing, do: "sso_connection.updated", else: "sso_connection.created")

      record_write_attempt(%{
        org_id: org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: action,
        resource_type: "sso_connection",
        resource_id: existing && existing.id,
        resource_label: attrs["provider"] || "sso",
        result: "failed",
        reason: reason,
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        surface: "sso",
        metadata: %{
          "provider" => attrs["provider"],
          "client_id_configured" => present?(attrs["client_id"]),
          "credential_submitted" => present?(attrs["client_secret"]),
          "credential_configured" => existing_secret_configured?(existing),
          "default_role" => attrs["default_role"],
          "allowed_domain_count" => attrs |> Map.get("allowed_domains", []) |> lengthish(),
          "provider_config_keys" => attrs |> Map.get("provider_config", %{}) |> map_keys()
        }
      })
    end
  end

  defp maybe_record_sso_write_attempt(_result, _org_id, _existing, _attrs, _opts), do: :ok

  defp record_write_attempt(attrs) do
    case Observability.record_write_attempt(attrs) do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning("settings_write_attempt_audit_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp maybe_record_model_validation_event(result, %Organization{} = org, attrs, opts) do
    if audit_enabled?(opts) and org_settings_surface(attrs) == "models" do
      resource_label =
        case result do
          {:ok, %Organization{name: name}} when is_binary(name) and name != "" -> name
          _ -> org.name
        end

      record_validation_event(%{
        org_id: org.id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        surface: "models",
        resource_type: "model_settings",
        resource_id: org.id,
        resource_label: resource_label,
        status: validation_status(result),
        reason_class: validation_reason(result),
        evidence: %{
          "allowed_template_count" => attrs |> Map.get("allowed_template_ids", []) |> lengthish(),
          "default_template_configured" => present?(attrs["default_template_id"]),
          "changed_fields" => Map.keys(attrs),
          "field_errors" => validation_field_errors(result)
        }
      })
    end
  end

  defp maybe_record_sso_validation_event(result, org_id, existing, attrs, opts) do
    if audit_enabled?(opts) do
      resource_id =
        case result do
          {:ok, %OrgSsoConnection{id: id}} -> id
          _ -> existing && existing.id
        end

      record_validation_event(%{
        org_id: org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        surface: "sso",
        provider: attrs["provider"],
        resource_type: "sso_connection",
        resource_id: resource_id,
        resource_label: attrs["provider"] || "sso",
        status: validation_status(result),
        reason_class: validation_reason(result),
        evidence: %{
          "provider" => attrs["provider"],
          "client_id_configured" => present?(attrs["client_id"]),
          "credential_submitted" => present?(attrs["client_secret"]),
          "credential_configured" => sso_credential_configured?(result, existing, attrs),
          "default_role" => attrs["default_role"],
          "allowed_domain_count" => attrs |> Map.get("allowed_domains", []) |> lengthish(),
          "provider_config_keys" => attrs |> Map.get("provider_config", %{}) |> map_keys(),
          "field_errors" => validation_field_errors(result)
        }
      })
    end
  end

  defp record_validation_event(attrs) do
    case Observability.record_validation_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("settings_validation_observability_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp validation_status({:ok, _value}), do: "ok"
  defp validation_status({:error, _reason}), do: "fail"

  defp validation_reason({:ok, _value}), do: nil
  defp validation_reason({:error, %Ecto.Changeset{}}), do: "changeset_invalid"
  defp validation_reason({:error, reason}), do: reason_to_class(reason)

  defp validation_field_errors({:error, %Ecto.Changeset{} = changeset}) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Map.new(fn {field, errors} -> {validation_error_field(field), errors} end)
  end

  defp validation_field_errors(_result), do: nil

  defp validation_error_field(field) when field in [:client_secret, "client_secret"],
    do: "credential"

  defp validation_error_field(field), do: to_string(field)

  defp sso_credential_configured?(
         {:ok, %OrgSsoConnection{client_secret: secret}},
         _existing,
         _attrs
       ),
       do: present?(secret)

  defp sso_credential_configured?(_result, existing, attrs),
    do: present?(attrs["client_secret"]) or existing_secret_configured?(existing)

  defp reason_to_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_to_class({tag, _reason}) when is_atom(tag), do: Atom.to_string(tag)

  defp reason_to_class(reason) when is_binary(reason), do: reason

  defp reason_to_class(_reason), do: "unknown"

  defp lengthish(value) when is_list(value), do: length(value)
  defp lengthish(value) when is_map(value), do: map_size(value)
  defp lengthish(_value), do: 0

  defp map_keys(value) when is_map(value), do: Map.keys(value)
  defp map_keys(_value), do: []

  defp sso_diff(existing, sso, attrs) do
    fields = ~w(provider issuer client_id allowed_domains default_role provider_config)

    base =
      Enum.reduce(fields, %{}, fn field, acc ->
        old_value = sso_audit_field(existing, field)
        new_value = sso_audit_field(sso, field)

        if old_value != new_value do
          Map.put(acc, field, %{"from" => old_value, "to" => new_value})
        else
          acc
        end
      end)

    if present?(attrs["client_secret"]) do
      Map.put(base, "credential_configured", %{
        "from" => existing_secret_configured?(existing),
        "to" => true
      })
    else
      base
    end
  end

  defp sso_audit_field(nil, _field), do: nil
  defp sso_audit_field(%OrgSsoConnection{} = sso, "provider"), do: sso.provider
  defp sso_audit_field(%OrgSsoConnection{} = sso, "issuer"), do: sso.issuer
  defp sso_audit_field(%OrgSsoConnection{} = sso, "client_id"), do: sso.client_id

  defp sso_audit_field(%OrgSsoConnection{} = sso, "allowed_domains"),
    do: sso.allowed_domains || []

  defp sso_audit_field(%OrgSsoConnection{} = sso, "default_role"), do: sso.default_role

  defp sso_audit_field(%OrgSsoConnection{} = sso, "provider_config"),
    do: sso.provider_config || %{}

  defp existing_secret_configured?(%OrgSsoConnection{client_secret: secret}), do: present?(secret)
  defp existing_secret_configured?(_), do: false

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      present?(Keyword.get(opts, :actor_user_id)) ||
      present?(Keyword.get(opts, :actor_label))
  end

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp put_default_billing_account_id(attrs, tenant_id) do
    if blank?(attrs["billing_account_id"]) do
      Map.put(attrs, "billing_account_id", "bridge-ba-" <> tenant_id)
    else
      attrs
    end
  end

  defp preserve_billing_account(attrs, %Organization{billing_account_id: account_id}) do
    if blank?(account_id) do
      attrs
    else
      Map.delete(attrs, "billing_account_id")
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false

  defp normalize_provider_config(%{"provider_config" => config} = attrs, existing)
       when is_map(config) do
    provider = Map.get(attrs, "provider") || (existing && existing.provider) || "generic_oidc"

    config =
      config
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> allowed_provider_config(provider)

    # Merge onto the existing connection's provider_config so keys the caller did
    # not supply (e.g. tenant_key set on another path, or an unchanged
    # scope/provisioning_policy) are preserved rather than wiped by a partial
    # save. A wholesale replace here silently regressed Feishu SSO config on any
    # binding re-upsert that omitted scope. (Review B1, findings #1/#7.)
    existing_config = (existing && existing.provider_config) || %{}
    Map.put(attrs, "provider_config", Map.merge(existing_config, config))
  end

  defp normalize_provider_config(attrs, _existing), do: attrs

  defp allowed_provider_config(config, "feishu") do
    config
    |> Map.take(["scope", "tenant_key", "provisioning_policy"])
    |> normalize_feishu_provider_config()
  end

  defp allowed_provider_config(config, _provider), do: config

  defp normalize_feishu_provider_config(config) do
    case Map.get(config, "provisioning_policy") do
      policy when policy in ["jit", "existing_identity"] ->
        config

      _ ->
        Map.delete(config, "provisioning_policy")
    end
  end

  # Store a non-blank secret; a blank one keeps the existing stored secret.
  defp put_secret(attrs, existing) do
    provider = Map.get(attrs, "provider") || (existing && existing.provider) || "generic_oidc"

    case Map.get(attrs, "client_secret") do
      secret when is_binary(secret) and secret != "" ->
        Map.put(attrs, "client_secret", secret)

      _ ->
        if existing && existing.provider == provider do
          Map.put(attrs, "client_secret", existing.client_secret)
        else
          Map.put(attrs, "client_secret", nil)
        end
    end
  end

  defp normalize_domains(attrs) do
    case Map.get(attrs, "allowed_domains") do
      domains when is_binary(domains) ->
        list =
          domains
          |> String.split([",", " ", "\n"], trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(attrs, "allowed_domains", list)

      _ ->
        attrs
    end
  end

  defp normalize_sso_provider_fields(%{"provider" => "feishu"} = attrs) do
    attrs
    |> Map.put("issuer", nil)
    |> Map.put("allowed_domains", [])
  end

  defp normalize_sso_provider_fields(attrs) do
    Map.put_new(attrs, "provider", "generic_oidc")
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
