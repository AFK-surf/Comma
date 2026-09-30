defmodule SalixIM.Triage.SourceMode do
  @moduledoc """
  Resolves the one context authority for a sealed Triage generation.

  A generation normally contains one physical source mode. The only mixed
  steady-state shape is a ClickHouse generation carrying an internal scheduled
  recheck. Slack content itself always remains ClickHouse-owned.
  """

  @allowed ~w(
    callback clickhouse_etl historical_thread_reenactment periodic_patrol scheduled_recheck
  )

  @spec resolve([map()]) :: {:ok, String.t()} | {:error, atom()}
  def resolve([_ | _] = events) do
    source_modes = Enum.map(events, & &1["source_mode"])

    cond do
      Enum.any?(source_modes, &is_nil/1) ->
        {:error, :identity_source_mode_missing}

      not Enum.all?(source_modes, &(&1 in @allowed)) ->
        {:error, :invalid_identity_source_mode}

      length(Enum.uniq(source_modes)) == 1 ->
        {:ok, hd(source_modes)}

      Enum.any?(source_modes, &(&1 == "clickhouse_etl")) and
          Enum.all?(events, &clickhouse_compatible?/1) ->
        {:ok, "clickhouse_etl"}

      true ->
        {:error, :mixed_identity_source_mode}
    end
  end

  def resolve(_events), do: {:error, :invalid_identity_source_mode}

  defp clickhouse_compatible?(%{"source_mode" => "clickhouse_etl"}), do: true

  defp clickhouse_compatible?(%{"source_mode" => "scheduled_recheck"}), do: true
  defp clickhouse_compatible?(_event), do: false
end
