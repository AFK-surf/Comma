defmodule SalixStore.Repo do
  @moduledoc """
  Salix control-plane PostgreSQL repository (database `salix`).

  Owns online Agent, Session, Conversation, Message, Participant, and receipt facts.
  Transactions also update their query projections and pending work targets.
  S3 retains immutable attachments and sealed history bodies. PostgreSQL directories
  identify published history. See `docs/storage-search.md`.

  The repo lives in `salix_store` (not a product app) because control metadata
  must be readable on every node that runs the `salix` subsystem, including the
  comma-product workload. It starts only when `:start_repo` is set, which
  `config/runtime.exs` derives from the presence of `salix.database.url`.
  """

  use Ecto.Repo,
    otp_app: :salix_store,
    adapter: Ecto.Adapters.Postgres
end
