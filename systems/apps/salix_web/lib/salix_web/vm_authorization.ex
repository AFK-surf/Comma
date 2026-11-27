defmodule SalixWeb.VMAuthorization do
  @moduledoc false
  @callback authorize_vm(map()) :: :ok | {:error, term()}

  defmodule Noop do
    @moduledoc false
    @behaviour SalixWeb.VMAuthorization

    @impl true
    def authorize_vm(_attrs), do: :ok
  end

  defmodule BillingCore do
    @moduledoc false
    @behaviour SalixWeb.VMAuthorization

    @impl true
    def authorize_vm(attrs) do
      owner = attrs[:billing_owner] || %{}

      account_id = owner["billing_account_id"] || owner[:billing_account_id]
      entrypoint = attrs[:entrypoint] || "cloud_vm_reconcile"
      actor_type = attrs[:actor_type] || "system"

      request =
        Module.concat([:BillingCore, :FeeControl, :Request])
        |> struct(%{
          billing_account_id: owner["billing_account_id"] || owner[:billing_account_id],
          resource_kind: :vm,
          action: attrs[:action] || :resume,
          mode: :enforce,
          estimated_credits: 1,
          balance_snapshot: attrs[:balance_snapshot] || owner["balance_snapshot"] || 0,
          provider: attrs[:provider] || "cloudflare",
          sku: attrs[:sku] || "runtime-minimum",
          typed_sink: attrs[:typed_sink],
          source: "vm_authorization",
          source_key: attrs[:source_key] || "vm:#{account_id}:#{entrypoint}",
          row_context: %{
            "billing_account_id" => account_id,
            "surface" => owner["surface"] || owner[:surface] || "unknown",
            "product_owner_type" =>
              owner["product_owner_type"] || owner[:product_owner_type] || "unknown",
            "product_owner_id" =>
              owner["product_owner_id"] || owner[:product_owner_id] || "unknown",
            "tenant_id" => owner["salix_tenant_id"] || owner[:salix_tenant_id] || "",
            "group_id" => owner["salix_group_id"] || owner[:salix_group_id] || "",
            "entrypoint" => entrypoint,
            "actor_type" => actor_type
          }
        })

      fee_control = Module.concat([:BillingCore, :FeeControl])

      case apply(fee_control, :authorize, [request]) do
        {:ok, %{allowed?: true}} -> :ok
        {:ok, decision} -> {:error, {:billing_unavailable, decision}}
        {:error, _} = err -> err
      end
    end
  end
end
