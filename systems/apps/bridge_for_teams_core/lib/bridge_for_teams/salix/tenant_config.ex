defmodule BridgeForTeams.Salix.TenantConfig do
  @moduledoc """
  BFT-owned tenant configuration applied to the matching Salix tenant.

  This module never writes from startup or request paths directly. New
  organizations enqueue an outbox row; existing organizations are checked by
  `BridgeForTeams.Salix.TenantConfigChecker`.
  """

  import Ecto.Query

  alias BridgeForTeams.{Outbox, Repo}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.Organization

  @conversation_links_config "conversation_links"
  @conversation_url_path "/tasks/{tenant_id}/{group_id}/{conversation_id}"

  @type ensure_result :: %{
          required(:org_id) => Ecto.UUID.t(),
          required(:tenant_id) => String.t(),
          required(:status) => String.t(),
          optional(:changed) => boolean(),
          optional(:reason) => term()
        }

  @spec conversation_links_config_name() :: String.t()
  def conversation_links_config_name, do: @conversation_links_config

  @spec expected_conversation_links_config() :: {:ok, map()} | {:error, term()}
  def expected_conversation_links_config do
    with {:ok, base_url} <- public_base_url() do
      {:ok,
       %{
         "conversation_url_template" => base_url <> @conversation_url_path
       }}
    end
  end

  @spec enqueue_ensure_tenant_config(Organization.t(), keyword()) ::
          :ok | {:error, term()}
  def enqueue_ensure_tenant_config(%Organization{} = org, opts \\ []) do
    payload = %{
      "org_id" => org.id,
      "tenant_id" => org.salix_tenant_id
    }

    case Outbox.enqueue("organization", org.id, "ensure_tenant_config", payload, opts) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_all(keyword()) :: map()
  def ensure_all(opts \\ []) do
    organizations = Keyword.get_lazy(opts, :organizations, &list_organizations/0)

    results = Enum.map(organizations, &ensure_org/1)

    %{
      total: length(results),
      ok: Enum.count(results, &(&1.status == "ok")),
      changed: Enum.count(results, &(&1[:changed] == true)),
      skipped: Enum.count(results, &(&1.status == "skipped")),
      failed: Enum.filter(results, &(&1.status == "failed")),
      results: results
    }
  end

  @spec ensure_org(Organization.t() | String.t()) :: ensure_result()
  def ensure_org(%Organization{} = org) do
    tenant_id = trim(org.salix_tenant_id)

    with true <- tenant_id != "",
         {:ok, _tenant} <- Client.impl().get_tenant(tenant_id),
         :ok <- publish_role_defaults(org, tenant_id),
         {:ok, expected} <- expected_conversation_links_config(),
         {:ok, current} <-
           Client.impl().get_tenant_config(tenant_id, @conversation_links_config, %{}) do
      changed? = not same_conversation_links_config?(current, expected)

      if changed? do
        write_and_verify(org, tenant_id, expected)
      else
        ensure_result(org, tenant_id, "ok", changed: false)
      end
    else
      {:error, reason} ->
        ensure_result(org, tenant_id, "failed", reason: reason)

      false ->
        ensure_result(org, tenant_id, "skipped", reason: :missing_salix_tenant_id)
    end
  rescue
    e ->
      ensure_result(org, trim(org.salix_tenant_id), "failed", reason: {:exception, e})
  end

  def ensure_org(org_ref) when is_binary(org_ref) do
    case get_org_by_id(org_ref) do
      {:ok, org} ->
        ensure_org(org)

      {:error, reason} ->
        %{
          org_id: org_ref,
          tenant_id: "",
          status: "failed",
          reason: reason
        }
    end
  end

  @spec reconcile_ensure_org(String.t()) :: {:ok, ensure_result()} | {:error, term()}
  def reconcile_ensure_org(org_id) when is_binary(org_id) do
    case ensure_org(org_id) do
      %{status: "ok"} = result ->
        {:ok, result}

      %{status: "skipped"} = result ->
        {:ok, result}

      %{status: "failed", reason: reason} ->
        {:error, classify_reconcile_failure(reason)}

      other ->
        {:error, {:unexpected_tenant_config_result, other}}
    end
  end

  # The org's per-role defaults are the Salix tenant layer. A nil org default
  # clears the tenant pointer so the role defers to the platform default.
  defp publish_role_defaults(org, tenant_id) do
    with {:ok, current} <- Client.impl().get_tenant_config(tenant_id, "agent_defaults", %{}),
         {:ok, _} <-
           Client.impl().update_tenant_config(
             tenant_id,
             "agent_defaults",
             current
             |> Map.put("router_template_id", org.default_router_template_id)
             |> Map.put("worker_template_id", org.default_template_id)
           ) do
      :ok
    end
  end

  defp write_and_verify(org, tenant_id, expected) do
    with {:ok, _written} <-
           Client.impl().update_tenant_config(tenant_id, @conversation_links_config, expected),
         {:ok, current} <-
           Client.impl().get_tenant_config(tenant_id, @conversation_links_config, %{}),
         true <- same_conversation_links_config?(current, expected) do
      ensure_result(org, tenant_id, "ok", changed: true)
    else
      false ->
        ensure_result(org, tenant_id, "failed", reason: :tenant_config_readback_mismatch)

      {:error, reason} ->
        ensure_result(org, tenant_id, "failed", reason: reason)
    end
  end

  defp same_conversation_links_config?(current, expected) when is_map(current) do
    trim(current["conversation_url_template"]) == trim(expected["conversation_url_template"])
  end

  defp same_conversation_links_config?(_current, _expected), do: false

  defp classify_reconcile_failure(reason)
       when reason in [:not_found, :public_base_url_not_configured],
       do: {:transient, reason}

  defp classify_reconcile_failure(reason), do: reason

  defp ensure_result(%Organization{} = org, tenant_id, status, opts) do
    result = %{
      org_id: org.id,
      tenant_id: tenant_id,
      status: status
    }

    result
    |> maybe_put(:changed, opts[:changed])
    |> maybe_put(:reason, opts[:reason])
  end

  defp public_base_url do
    case Application.get_env(:bridge_for_teams_web, :public_base_url) |> trim() do
      "" -> {:error, :public_base_url_not_configured}
      base_url -> {:ok, String.trim_trailing(base_url, "/")}
    end
  end

  defp list_organizations do
    from(o in Organization,
      order_by: [asc: o.created_at]
    )
    |> Repo.all()
  end

  defp get_org_by_id(ref) do
    case Ecto.UUID.cast(ref) do
      {:ok, id} ->
        case Repo.get(Organization, id) do
          %Organization{} = org -> {:ok, org}
          nil -> {:error, :organization_not_found}
        end

      :error ->
        {:error, :invalid_org_id}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
