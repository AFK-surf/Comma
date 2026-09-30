defmodule Comma.Schema do
  @moduledoc "Comma database schema readiness contract for release and Pod lifecycle checks."

  @cutover_marker_version 20_260_723_000_003
  @runtime_schema_version 20_260_724_000_001
  @required_versions [@cutover_marker_version, @runtime_schema_version]

  def ready?(repo \\ Comma.Repo) do
    case Ecto.Adapters.SQL.query(
           repo,
           """
           SELECT COUNT(*)::bigint
           FROM schema_migrations
           WHERE version = ANY($1::bigint[])
           """,
           [@required_versions]
         ) do
      {:ok, %{rows: [[count]]}} -> count == length(@required_versions)
      _ -> false
    end
  rescue
    _error -> false
  end
end
