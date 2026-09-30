defmodule SalixStore.Repo.Migrations.ExternalSessionActivityRevisionCutover do
  @moduledoc """
  Exclusive forward-only boundary for external Session Activity schema v2.

  The release controller records this migration only after it has scaled every
  legacy lifecycle writer to zero. The migration intentionally does not scan or
  rewrite S3: the new runtime certifies each exact v1 object by conditional CAS
  on first read. Its durable ledger row makes that lazy certification safe by
  prohibiting a rolling release or restoration of the v1 writer afterward.
  """

  use Ecto.Migration

  def up, do: :ok

  def down do
    raise "external Session Activity schema v2 is a forward-only cutover"
  end
end
