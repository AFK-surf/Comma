defmodule SalixStore.Repo.Migrations.RecordAgentVMMRevocationReason do
  @moduledoc """
  Record why an Agent VMM registration was revoked, in the transaction that
  revokes it: `authorization_expired` for the 7-day authorization deadline,
  `revoked` for any explicit revocation. Comma Main reinstalls automatically
  only after expiry (RFC 42 §3.4), so it must tell the two apart.

  No existing fact does: `status` is `revoked` for both, and comparing
  `updated_at` with `authorization_expires_at` misreads an explicit removal
  made after the deadline but before the expiry sweep.

  Expand step: old runtimes ignore the column. Rows revoked before this
  release keep NULL, which the projection reports as `revoked`, so no old row
  is reinstalled automatically.
  """
  use Ecto.Migration

  def change do
    alter table(:agent_vmm_registrations) do
      add(:revocation_reason, :text)
    end

    create(
      constraint(:agent_vmm_registrations, :agent_vmm_registrations_revocation_reason_check,
        check:
          "revocation_reason IS NULL OR revocation_reason IN ('authorization_expired', 'revoked')"
      )
    )
  end
end
