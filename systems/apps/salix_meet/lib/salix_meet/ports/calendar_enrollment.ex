defmodule SalixMeet.Ports.CalendarEnrollment do
  @moduledoc false

  @callback resolve_identities(entries :: [map()]) ::
              {:ok, %{optional(String.t()) => {:ok, map()} | {:error, term()}}}
              | {:error, term()}
  @callback resolve(entry :: map(), identity :: map()) :: {:ok, map()} | {:error, term()}
  @callback resolve(entry :: map()) :: {:ok, map()} | {:error, term()}

  @spec resolve_identities([map()]) ::
          {:ok, %{optional(String.t()) => {:ok, map()} | {:error, term()}}} | {:error, term()}
  def resolve_identities(entries), do: impl().resolve_identities(entries)

  @spec resolve(map(), map()) :: {:ok, map()} | {:error, term()}
  def resolve(entry, identity), do: impl().resolve(entry, identity)

  @spec resolve(map()) :: {:ok, map()} | {:error, term()}
  def resolve(entry), do: impl().resolve(entry)

  defp impl, do: Application.get_env(:salix_meet, :calendar_enrollment_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.CalendarEnrollment

    @impl true
    def resolve_identities(entries) do
      {:ok,
       Map.new(entries, fn entry ->
         connect_id = Map.get(entry, "connect_id")
         {connect_id, {:error, :not_configured}}
       end)}
    end

    @impl true
    def resolve(_entry, _identity), do: {:error, :not_configured}

    @impl true
    def resolve(_entry), do: {:error, :not_configured}
  end
end
