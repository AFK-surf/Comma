defmodule SalixStore.Repo.Migrations.SchedulesCutover do
  @moduledoc """
  Exclusive-stage authority cutover for schedule definitions
  (docs/salix/control-metadata-postgres.md). Runs at zero replicas via the
  release engine's cutover stage: import every legacy S3 object, verify strict
  S3<->PG set equality, persist the cutover marker. Idempotent; a failed attempt
  retries the exact same step (forward-only, no down). Run claims are not
  imported (see SalixStore.SchedulesCutover).
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

    case SalixStore.SchedulesCutover.run() do
      :ok -> :ok
      {:error, reason} -> raise "schedules cutover failed: #{inspect(reason)}"
    end
  end
end
