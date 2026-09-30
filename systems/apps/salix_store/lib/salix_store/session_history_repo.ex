defmodule SalixStore.SessionHistoryRepo do
  @moduledoc "Separate search connection pool. Search never borrows the chat pool."
  use Ecto.Repo, otp_app: :salix_store, adapter: Ecto.Adapters.Postgres
end
