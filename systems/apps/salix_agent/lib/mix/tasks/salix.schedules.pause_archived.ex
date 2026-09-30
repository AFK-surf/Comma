defmodule Mix.Tasks.Salix.Schedules.PauseArchived do
  @shortdoc "Pause the schedules of every already-archived agent"

  @moduledoc """
  Operator-triggered sweep for #849: archiving an agent now pauses its
  agent-receiver schedules, but agents archived before that existed (and any
  archive whose pause failed after the record was written) still have active
  definitions that the sweeper re-attempts, blocked, on every pass. This
  pauses them once. Idempotent; user-paused rows are left alone.

      mix salix.schedules.pause_archived
      mix salix.schedules.pause_archived --dry-run

  Deployed pods ship an OTP release without Mix — run the same sweep there
  through the release entry:

      bin/comma eval 'Comma.Release.pause_archived_agent_schedules()'
      bin/comma eval 'Comma.Release.pause_archived_agent_schedules(dry_run: true)'
  """

  use Mix.Task

  alias SalixAgent.ArchivedScheduleSweep

  @switches [dry_run: :boolean]

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix salix.schedules.pause_archived [--dry-run]")
    end

    {:ok, _started} = Application.ensure_all_started(:salix_store)

    case ArchivedScheduleSweep.run(dry_run: Keyword.get(opts, :dry_run, false)) do
      {:ok, summary} ->
        Mix.shell().info("archived-schedule sweep: #{inspect(summary)}")

      {:error, %{failed: failed} = summary} ->
        Mix.shell().info("archived-schedule sweep: #{inspect(summary)}")
        Mix.raise("archived-schedule sweep failed for #{length(failed)} agent(s)")

      {:error, reason} ->
        Mix.raise("archived-schedule sweep failed: #{inspect(reason)}")
    end
  end
end
