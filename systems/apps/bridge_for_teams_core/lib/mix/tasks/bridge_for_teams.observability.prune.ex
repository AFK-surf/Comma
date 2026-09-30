defmodule Mix.Tasks.BridgeForTeams.Observability.Prune do
  @moduledoc """
  Prune expired BridgeForTeams observability rows.

      mix bridge_for_teams.observability.prune
  """
  use Mix.Task

  alias BridgeForTeams.Observability

  @shortdoc "Prune expired BFT Operations observability rows"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {_opts, _argv, invalid} = OptionParser.parse(args, strict: [])

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    {:ok, counts} = Observability.prune_expired()

    counts
    |> Jason.encode!(pretty: true)
    |> Mix.shell().info()
  end
end
