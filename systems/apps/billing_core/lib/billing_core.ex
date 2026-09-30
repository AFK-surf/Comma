defmodule BillingCore do
  @moduledoc """
  Neutral billing primitives for pricing, credit charging, backfill, and
  fee-control shadow checks.

  The core is intentionally storage-neutral. Public functions accept
  and return `%BillingCore.State{}` values so behavior is deterministic in unit
  tests and can be composed with a database transaction without changing the
  business rules.
  """
end
