defmodule SalixMeet.Ports.CalendarPreparation do
  @moduledoc false

  @callback write(plan :: map()) :: {:ok, map()} | {:error, term()}

  def write(plan) do
    Application.get_env(:salix_meet, :calendar_preparation_mod, __MODULE__.None).write(plan)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.CalendarPreparation

    @impl true
    def write(_plan), do: {:error, :calendar_preparation_not_configured}
  end
end
