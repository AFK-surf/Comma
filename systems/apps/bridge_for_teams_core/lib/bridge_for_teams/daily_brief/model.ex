defmodule BridgeForTeams.DailyBrief.Model do
  @moduledoc """
  The model boundary of the daily brief: writing the team's brief and each
  member's. The implementation runs in Salix on the Swarm Router's model; BFT
  checks the written text (`Compose`).
  """

  @typedoc "A call that failed after the model answered carries what it cost."
  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}

  @typedoc "The brief as the model wrote it, in Markdown."
  @type composed :: %{required(:text) => String.t(), required(:usage) => usage()}

  @typedoc "A brief to write: a member's (the default) or the team's."
  @type compose_request :: %{
          required(:agent_id) => String.t(),
          required(:input) => map(),
          optional(:view) => :personal | :team
        }

  @callback compose(compose_request()) ::
              {:ok, composed()} | {:error, {term(), usage()}} | {:error, term()}

  @spec impl() :: module() | nil
  def impl, do: SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_model)
end
