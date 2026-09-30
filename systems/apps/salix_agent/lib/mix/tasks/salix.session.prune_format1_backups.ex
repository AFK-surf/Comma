defmodule Mix.Tasks.Salix.Session.PruneFormat1Backups do
  @shortdoc "Delete format-1 session backups after the retention window"

  @moduledoc """
  Operator-triggered cleanup of the format-1 backups the format-2 migration
  left behind — the explicit deletion step the plan requires so backups are
  removed by decision, not by forgetting.

  Refuses to run unless the cutover marker is at least 14 days old (override
  with `--retention-days`). Before deleting anything it samples up to 100
  migrated sessions (all of them below that count) and verifies each decodes
  as format 2 and that every terminal result recorded in its backup is
  byte-equal readable at its seq in the format-2 window or archive.

      mix salix.session.prune_format1_backups
      mix salix.session.prune_format1_backups --retention-days 30 --dry-run

  Deployed pods ship an OTP release without Mix — run the same prune there
  through the release entry:

      bin/comma eval 'Comma.Release.prune_salix_format1_backups()'
  """

  use Mix.Task

  alias SalixAgent.InternalSessionFormat2Cutover, as: Cutover
  alias SalixAgent.SessionFormat1BackupPrune

  @switches [retention_days: :integer, dry_run: :boolean]

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix salix.session.prune_format1_backups [--retention-days N] [--dry-run]")
    end

    {:ok, _started} = Application.ensure_all_started(:salix_store)

    unless Cutover.marker_present?() do
      Mix.raise("refusing to prune: the format-2 cutover marker is absent")
    end

    case SessionFormat1BackupPrune.run(opts) do
      {:ok, report} ->
        Mix.shell().info(Jason.encode_to_iodata!(report, pretty: true) |> IO.iodata_to_binary())

      {:error, reason} ->
        Mix.raise("backup prune failed: #{inspect(reason)}")
    end
  end
end
