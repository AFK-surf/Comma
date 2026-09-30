defmodule SalixStore.Repo.Migrations.SlackTriageChannelAuthorityCutover do
  @moduledoc """
  Online fleet cutover for Slack Triage channel authority.

  Current runtimes coordinate legacy authority-changing writes through a
  durable preparation barrier. This release step freezes those writes,
  reconciles the dark PostgreSQL table to the exact legacy S3 authority set,
  re-verifies generation fences, and only then publishes the terminal marker.
  Sources without an explicit legacy channel remain uninitialized so the user
  still chooses their first channel after the cutover.
  """

  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    # The release migrator starts the repo only. The cutover also needs the S3
    # client owned by :salix_store; SalixIM's migration module itself is pure
    # orchestration over that already-started storage surface.
    case Application.ensure_all_started(:salix_store) do
      {:ok, _started} -> :ok
      {:error, reason} -> raise "failed to start salix_store for cutover: #{inspect(reason)}"
    end

    case SalixIM.Migrations.SlackTriageChannelAuthorityCutover.run() do
      {:ok, %{already_projected: true}} ->
        :ok

      {:ok, %{materialized: materialized, verified: verified}}
      when is_integer(materialized) and is_integer(verified) ->
        IO.puts(
          "Slack Triage channel authority projected: materialized=#{materialized} verified=#{verified}"
        )

        :ok

      {:error, reason} ->
        raise "Slack Triage channel authority cutover failed: #{inspect(reason)}"
    end
  end
end
