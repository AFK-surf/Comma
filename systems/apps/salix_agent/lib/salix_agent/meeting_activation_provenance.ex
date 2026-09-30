defmodule SalixAgent.MeetingActivationProvenance do
  @moduledoc """
  Runtime port for rejecting standalone schedules whose later execution cannot
  retain a meeting activation's original provider authorization boundary.
  """

  @callback authorize_schedule(map()) :: :ok | {:error, term()}

  @spec authorize_schedule(map()) :: :ok | {:error, term()}
  def authorize_schedule(ctx) when is_map(ctx) do
    case impl() do
      nil -> :ok
      mod -> mod.authorize_schedule(ctx)
    end
  end

  defp impl, do: Application.get_env(:salix_agent, :meeting_activation_provenance_mod)
end
