defmodule SalixStore.Repo.Migrations.OauthAppsCutover do
  @moduledoc """
  Exclusive-stage authority cutover for OAuth static client credentials —
  provider apps and deployment defaults
  (docs/salix/control-metadata-postgres.md, PR-1; remote-MCP provider apps stay
  in S3 and migrate in a later PR). Runs at zero replicas via the
  release engine's cutover stage: import every legacy S3 record, verify strict
  S3<->PG set equality, persist the cutover marker. Idempotent; a failed attempt
  retries the exact same step (forward-only, no down).
  """

  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    # The migrator only starts the repo; the S3 client needs the :salix_store
    # application (Finch pool + storage config). `bin/comma eval` contexts do not
    # start applications on their own, so start it explicitly here.
    case Application.ensure_all_started(:salix_store) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "failed to start salix_store for cutover: #{inspect(reason)}"
    end

    case SalixStore.OAuthAppsCutover.run() do
      :ok -> :ok
      {:error, reason} -> raise "oauth-apps cutover failed: #{inspect(reason)}"
    end
  end
end
