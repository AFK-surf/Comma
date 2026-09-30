defmodule SalixWeb.SubscriptionBinding do
  @moduledoc "Typed credential projection shared by device-runtime and Workload bindings."
  alias SalixAgent.{AccountPool, SubscriptionStore}

  def managed_projection(tenant, provider, result) do
    case result do
      {:error, :not_found} ->
        {:ok,
         %{
           "source" => "self_configured",
           "state" => "unbound",
           "provider" => provider,
           "binding" => nil,
           "account" => nil,
           "actions" => ["bind"],
           "issue" => nil
         }}

      {:ok, %{binding: binding, status: status}} ->
        account =
          case SubscriptionStore.get(tenant, binding["account_id"]) do
            {:ok, value} -> SubscriptionStore.public(value)
            _ -> nil
          end

        state = managed_state(binding, status, account)

        {:ok,
         %{
           "source" => "organization",
           "state" => state,
           "provider" => provider,
           "binding" => binding,
           "account" => account,
           "actions" => managed_actions(state),
           "issue" => managed_issue(state)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp managed_state(%{"enabled" => false}, _status, _account), do: "revoking"
  defp managed_state(_binding, _status, %{"disabled" => true}), do: "account_disabled"
  defp managed_state(_binding, "ready", _account), do: "configured"
  defp managed_state(_binding, "delivery_failed", _account), do: "failed"
  defp managed_state(_binding, "account_unavailable", _account), do: "account_disabled"
  defp managed_state(_binding, _status, _account), do: "installing"

  defp managed_actions("failed"), do: ["refresh", "retry", "unbind"]
  defp managed_actions("revoking"), do: ["refresh"]
  defp managed_actions(_), do: ["refresh", "unbind"]

  defp managed_issue("failed"), do: "delivery_failed"
  defp managed_issue("account_disabled"), do: "account_disabled"
  defp managed_issue(_), do: nil

  def observe(deliver) do
    started = System.monotonic_time()
    result = deliver.()

    try do
      outcome = if match?({:ok, _}, result), do: "ok", else: "error"

      Salix.Telemetry.emit_operation(
        "salix_web",
        "subscription_runtime_delivery",
        "system",
        outcome,
        System.monotonic_time() - started
      )
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    result
  end

  def observe_configuration(action, configure) when action in [:bind, :unbind] do
    started = System.monotonic_time()
    result = configure.()

    try do
      Salix.Telemetry.emit_operation(
        "salix_web",
        "subscription_runtime_configuration",
        Atom.to_string(action),
        if(match?({:ok, _}, result), do: "accepted", else: "error"),
        System.monotonic_time() - started
      )
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    result
  end

  def delivery_access(id, rejected \\ nil) do
    delivery_access(id, "codex", rejected)
  end

  def delivery_access(id, provider, rejected) do
    case issue(id, provider, rejected) do
      {:ok, _} = ok ->
        ok

      _ ->
        # Revoke only from current pool authority. A database outage cannot
        # manufacture a revocation. The sequence fences older in-flight delivery.
        case SubscriptionStore.query(
               """
               UPDATE runtime_subscription_bindings b
               SET revision=nextval('runtime_subscription_delivery_revision'),last_delivery_revoked=true
               WHERE b.id=$1
                 AND (NOT b.enabled OR NOT EXISTS (SELECT 1 FROM subscription_accounts a
                   WHERE a.tenant_id=b.tenant_id AND a.id=b.account_id
                     AND a.value->>'disabled'='false' AND (
                       a.value->>'credential_kind'='provider_api_key'
                       OR (a.value->>'credential_kind'='subscription_oauth' AND (
                         a.value->>'status'='active'
                         OR (a.value->>'status'='reauthorization_required' AND
                           COALESCE((a.value->>'refresh_deadline')::bigint,0)>extract(epoch from now()))
                       ))
                     )))
               RETURNING b.account_id,b.revision
               """,
               [id]
             ) do
          {:ok, %{rows: [[account, revision]]}} ->
            {:ok,
             %{
               "revoked" => true,
               "subscription_account_id" => account,
               "delivery_revision" => revision
             }}

          _ ->
            {:error, :subscription_access_unavailable}
        end
    end
  end

  def issue(id, rejected), do: issue(id, "codex", rejected)

  def issue(id, provider, rejected) do
    with {:ok, %{rows: [[tenant, account]]}} <-
           SubscriptionStore.query(
             """
             SELECT tenant_id,account_id FROM runtime_subscription_bindings
             WHERE id=$1 AND enabled=true
             """,
             [id]
           ),
         {:ok, access} <- AccountPool.runtime_access(tenant, account, provider, rejected),
         {:ok, %{rows: [[revision]]}} <-
           SubscriptionStore.query(
             """
             UPDATE runtime_subscription_bindings b SET revision=nextval('runtime_subscription_delivery_revision'),last_delivery_revoked=false
             FROM subscription_accounts a
             WHERE b.id=$1
               AND b.enabled=true AND b.account_id=$4 AND a.tenant_id=b.tenant_id AND a.id=b.account_id AND a.version=$2
               AND a.value->>'credential_kind'=$3 AND a.value->>'disabled'='false'
               AND (a.value->>'credential_kind'='provider_api_key' OR a.value->>'status'='active')
             RETURNING b.revision
             """,
             [id, access["account_version"], access["credential_kind"], account]
           ) do
      {:ok,
       access
       |> Map.merge(%{"bound" => true, "delivery_revision" => revision})}
    else
      _ -> {:error, :subscription_access_unavailable}
    end
  end
end
