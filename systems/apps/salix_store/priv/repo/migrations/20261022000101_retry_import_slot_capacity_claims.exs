defmodule SalixStore.Repo.Migrations.RetryImportSlotCapacityClaims do
  @moduledoc """
  A busy Host import slot is transient (RFC 42 §3.8, O5). The command-result
  path no longer parks it as action required; the reconciler re-dispatches
  `allocation.ensure` with its normal claim backoff.

  Claims parked before this release stay excluded from reconciliation. Delete
  exactly those reconciler claims so the next sweep claims the Workload again.
  Claims are disposable reconciler scheduling state. Storage-headroom claims
  still need operator action and stay unchanged.
  """
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM compute_reconciler_claims
    WHERE provider = 'agent_vmm'
      AND claim_token = 'capacity-action-required'
      AND last_error->>'resource' = 'import_slot'
    """)
  end

  def down, do: :ok
end
