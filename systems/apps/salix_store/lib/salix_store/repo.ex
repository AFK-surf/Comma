defmodule SalixStore.Repo do
  @moduledoc """
  Salix control-plane PostgreSQL repository (database `salix`).

  Holds queryable control metadata — unique lookups, filtered/ordered listings,
  transactions — per `docs/storage-search.md`. Authoritative
  conversation/session content, blobs, and append-shaped data stay in S3 behind
  `SalixStore.S3`; PostgreSQL may hold explicitly rebuildable, bounded query
  projections derived from that owner-committed state.

  The repo lives in `salix_store` (not a product app) because control metadata
  must be readable on every node that runs the `salix` subsystem, including the
  comma-product workload. It starts only when `:start_repo` is set, which
  `config/runtime.exs` derives from the presence of `salix.database.url`.
  """

  use Ecto.Repo,
    otp_app: :salix_store,
    adapter: Ecto.Adapters.Postgres
end
