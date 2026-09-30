defmodule BridgeForTeams.Billing do
  @moduledoc """
  Thin Bridge billing surface over BillingCore/BillingCommerce facts.
  """

  alias BridgeForTeams.Orgs
  alias BridgeForTeams.Schema.Organization
  alias BillingCore.Entitlements.Policy

  @spec issue_manual_contract_grant(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def issue_manual_contract_grant(org_id, attrs) when is_map(attrs) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id) do
      attrs
      |> Map.merge(%{
        billing_account_id: org.billing_account_id,
        organization_id: org.id,
        source_type: "manual_contract",
        product_owner_type: "organization",
        product_owner_id: org.id
      })
      |> BillingCommerce.issue_bridge_org_grant()
    end
  end

  @spec issue_license_grant(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def issue_license_grant(org_id, attrs) when is_map(attrs) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id),
         {:ok, license} <- license_payload(attrs),
         {:ok, period} <- period(attrs) do
      grant_attrs =
        attrs
        |> Map.merge(%{
          billing_account_id: org.billing_account_id,
          organization_id: org.id,
          source_type: "license_period",
          source_id: license.id,
          source_event_id: license.event_id,
          idempotency_key: license_idempotency_key(license.id, period.valid_from),
          valid_from: period.valid_from,
          expires_at: period.expires_at,
          product_owner_type: "organization",
          product_owner_id: org.id,
          metadata: Map.merge(attrs[:metadata] || attrs["metadata"] || %{}, license.metadata)
        })

      BillingCommerce.issue_bridge_org_grant(grant_attrs)
    end
  end

  @spec org_billing_summary(Ecto.UUID.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def org_billing_summary(org_id, opts \\ []) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id) do
      at = opts[:at] || opts["at"] || DateTime.utc_now()

      %{rows: [[credits]]} =
        Ecto.Adapters.SQL.query!(
          BillingCore.Repo,
          """
          SELECT COALESCE(SUM(GREATEST(remaining_credits, 0)), 0)
          FROM credit_grants
          WHERE billing_account_id = $1
            AND status = 'active'
            AND remaining_credits > 0
            AND valid_from <= $2
            AND (expires_at IS NULL OR expires_at > $2)
          """,
          [org.billing_account_id, at]
        )

      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          BillingCore.Repo,
          """
          SELECT id, package_code, package_version, remaining_credits, valid_from,
            expires_at, source_type, source_id, policy_snapshot
          FROM credit_grants
          WHERE billing_account_id = $1
            AND status = 'active'
            AND valid_from <= $2
            AND (expires_at IS NULL OR expires_at > $2)
          ORDER BY expires_at NULLS LAST, id
          """,
          [org.billing_account_id, at]
        )

      {:ok,
       %{
         billing_account_id: org.billing_account_id,
         current_credits: credits,
         entitlement_mode: entitlement_mode(rows),
         active_grants: Enum.map(rows, &grant_row/1)
       }}
    end
  end

  defp entitlement_mode(rows) do
    rows
    |> Enum.map(fn row -> row |> List.last() |> decode_json() end)
    |> Policy.active_usage_mode()
    |> Atom.to_string()
  end

  defp license_payload(attrs) do
    license_id = required(attrs, :license_id)

    {:ok,
     %{
       id: license_id,
       event_id:
         attrs[:license_event_id] || attrs["license_event_id"] ||
           attrs[:source_event_id] || attrs["source_event_id"] || license_id,
       metadata: %{
         "license_id" => license_id,
         "license_issuer" => attrs[:license_issuer] || attrs["license_issuer"]
       }
     }}
  rescue
    KeyError -> {:error, :license_id_required}
  end

  defp period(attrs) do
    valid_from = required(attrs, :valid_from)
    expires_at = required(attrs, :expires_at)

    if match?(%DateTime{}, valid_from) and match?(%DateTime{}, expires_at) and
         DateTime.compare(valid_from, expires_at) == :lt do
      {:ok, %{valid_from: valid_from, expires_at: expires_at}}
    else
      {:error, :explicit_valid_from_and_expires_at_required}
    end
  rescue
    KeyError -> {:error, :explicit_valid_from_and_expires_at_required}
  end

  defp license_idempotency_key(license_id, %DateTime{} = valid_from),
    do: "license:#{license_id}:#{DateTime.to_iso8601(valid_from)}"

  defp grant_row([
         id,
         package_code,
         package_version,
         remaining,
         valid_from,
         expires_at,
         source_type,
         source_id,
         policy_snapshot
       ]) do
    policy_snapshot = decode_json(policy_snapshot)

    %{
      id: id,
      package_code: package_code,
      package_version: package_version,
      remaining_credits: remaining,
      valid_from: valid_from,
      expires_at: expires_at,
      source_type: source_type,
      source_id: source_id,
      entitlement_mode: Policy.usage_mode(policy_snapshot) |> Atom.to_string()
    }
  end

  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(value), do: value || %{}

  defp required(attrs, key) do
    value = attrs[key] || attrs[to_string(key)]

    if is_nil(value), do: raise(KeyError, key: key, term: attrs), else: value
  end
end
