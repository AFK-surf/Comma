defmodule Mix.Tasks.BridgeForTeams.Agents.TransferConfiguration do
  @moduledoc """
  Inspect or transfer one bounded page after the final runtime rollout has completed.

      mix bridge_for_teams.agents.transfer_configuration --limit 20 --after UUID
      mix bridge_for_teams.agents.transfer_configuration --project UUID --cursor TOKEN
      mix bridge_for_teams.agents.transfer_configuration --apply --agent UUID_OR_CANONICAL_ID

  Complete both the product-reference inventory and each project's native Salix
  pages. The latter includes older Salix-created Workers without a BFT row.
  Inspection is read-only; an apply never imports a BFT configuration snapshot.
  """
  use Mix.Task
  alias BridgeForTeams.Agents
  alias BridgeForTeams.Agents.ConfigurationTransfer
  alias SalixStore.Ids
  @requirements ["app.start"]
  @shortdoc "Transfer a bounded Agent page to canonical Salix configuration"

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          apply: :boolean,
          limit: :integer,
          after: :string,
          agent: :string,
          project: :string,
          cursor: :string
        ]
      )

    limit = Keyword.get(opts, :limit, 20)

    if invalid != [] or rest != [] or limit not in 1..50,
      do:
        Mix.raise(
          "Use --limit 1..50, --after UUID, --project UUID [--cursor TOKEN], --agent UUID_OR_CANONICAL_ID and/or --apply"
        )

    for key <- [:after, :project], opts[key] do
      if Ecto.UUID.cast(opts[key]) == :error, do: Mix.raise("#{key} must be a UUID")
    end

    if opts[:agent] && Ecto.UUID.cast(opts[:agent]) == :error &&
         not Ids.valid_agent_id?(opts[:agent]),
       do: Mix.raise("agent must be a product UUID or canonical Agent id")

    if (opts[:agent] && (opts[:after] || opts[:project] || opts[:cursor])) ||
         (opts[:project] && opts[:after]) || (opts[:cursor] && not opts[:project]),
       do: Mix.raise("Choose one inventory: --agent, --project [--cursor], or [--after]")

    {agents, next} = ConfigurationTransfer.inventory(opts, limit)

    results =
      Enum.map(agents, fn agent ->
        result =
          if opts[:apply] && agent.needs_transfer,
            do: Agents.transfer_configuration(agent.id),
            else: {:ok, agent}

        case result do
          {:ok, current} ->
            %{
              agent_id: agent.id,
              salix_agent_id: agent.salix_agent_id,
              authority: current.configuration_authority,
              needs_transfer: if(opts[:apply], do: false, else: agent.needs_transfer)
            }

          {:error, reason} ->
            %{
              agent_id: agent.id,
              authority: agent.configuration_authority,
              error: inspect(reason)
            }
        end
      end)

    Mix.shell().info(
      Jason.encode!(%{applied: opts[:apply] == true, results: results, next_cursor: next},
        pretty: true
      )
    )

    if Enum.any?(results, &Map.has_key?(&1, :error)),
      do:
        Mix.raise(
          "Some transfers require attention. Retry those Agent ids to finish the online handoff."
        )
  end
end
