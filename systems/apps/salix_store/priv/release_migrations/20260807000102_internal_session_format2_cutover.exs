defmodule SalixStore.Repo.Migrations.InternalSessionFormat2Cutover do
  @moduledoc """
  Exclusive-stage storage-format cutover for internal sessions
  (docs/salix/internal-session-segmented-storage.md). Runs at zero replicas via
  the release engine's cutover stage: back up every format-1 session object
  (create-once), rewrite it as format 2 (hot object + one archive object),
  verify zero format-1 objects remain by full scan, persist the
  `internal_session_format2_v1` marker. Idempotent; a failed attempt aborts
  without the marker and retries the exact same step (forward-only, no down) —
  already-rewritten sessions re-derive byte-identical output and converge.
  The salix serve gate (`Comma.PodLifecycle.ready(:salix)`) stays closed until
  the marker exists.
  """

  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    # The migrator only starts the repo; the S3 client needs the :salix_store
    # application (Finch pool + storage config). `bin/comma eval` contexts do not
    # start applications on their own, so start it explicitly here. The cutover
    # module lives in :salix_agent but touches only pure code plus
    # :salix_store's S3 and repo — no salix_agent runtime processes.
    case Application.ensure_all_started(:salix_store) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "failed to start salix_store for cutover: #{inspect(reason)}"
    end

    case SalixAgent.InternalSessionFormat2Cutover.run() do
      :ok -> :ok
      {:error, reason} -> raise "internal-session format-2 cutover failed: #{inspect(reason)}"
    end
  end
end
