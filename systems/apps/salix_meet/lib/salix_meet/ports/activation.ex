defmodule SalixMeet.Ports.Activation do
  @moduledoc false

  @callback handoff(state :: map(), summary :: map() | nil) :: :ok | :skip | {:error, term()}

  @spec handoff(map(), map() | nil) :: :ok | :skip | {:error, term()}
  def handoff(state, summary) when is_map(state), do: impl().handoff(state, summary)

  defp impl do
    Application.get_env(:salix_meet, :activation_mod, __MODULE__.None)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.Activation

    @impl true
    def handoff(_state, _summary), do: :skip
  end
end
