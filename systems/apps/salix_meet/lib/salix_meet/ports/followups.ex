defmodule SalixMeet.Ports.Followups do
  @moduledoc """
  The follow-up list a product keeps from meetings.

  `minutes_published/1` hands published minutes (with action-item owners that
  attribution resolved) to the product once. `team_section/1` returns the
  product's Markdown section for a meeting's preparation notice: the previous
  meeting's commitments with their status, and the team's open items. Both
  are best-effort: a failure never blocks minutes or the notice.
  """

  require Logger

  @callback minutes_published(state :: map()) :: :ok | :skip | {:error, term()}
  @callback team_section(plan :: map()) :: String.t()

  @spec minutes_published(map()) :: :ok | :skip | {:error, term()}
  def minutes_published(state) when is_map(state) do
    impl().minutes_published(state)
  rescue
    e ->
      Logger.warning("meeting followups crashed: #{Exception.message(e)}")
      {:error, :crashed}
  end

  @spec team_section(map()) :: String.t()
  def team_section(plan) when is_map(plan) do
    case impl().team_section(plan) do
      section when is_binary(section) -> section
      _other -> ""
    end
  rescue
    e ->
      Logger.warning("meeting followups section crashed: #{Exception.message(e)}")
      ""
  end

  defp impl, do: SystemsRuntime.get_env(:salix_meet, :followups_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.Followups

    @impl true
    def minutes_published(_state), do: :skip

    @impl true
    def team_section(_plan), do: ""
  end
end
