defmodule SalixMeet.Ports.Memory do
  @moduledoc false

  @callback project(state :: map()) :: :ok | :skip | {:error, term()}

  @spec project(map()) :: :ok | :skip | {:error, term()}
  def project(state) when is_map(state), do: impl().project(state)

  defp impl do
    Application.get_env(:salix_meet, :memory_mod, __MODULE__.None)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.Memory

    @impl true
    def project(_state), do: :skip
  end
end
