defmodule SalixMeet.Ports.CalendarOccurrences do
  @moduledoc false

  @type occurrence :: %{required(String.t()) => term()}

  @typedoc "The (start, event id) key a paged list continues after."
  @type page_key :: %{required(String.t()) => term()}

  # A group with "paged" => true asks for one page after its "page_after" key
  # and gets the next page key back (nil at the end of the range).
  @callback list(group :: map(), range_start_ms :: integer(), range_end_ms :: integer()) ::
              {:ok, [occurrence()]} | {:ok, [occurrence()], page_key() | nil} | {:error, term()}
  @callback revalidate(group :: map(), occurrence()) :: :ok | {:error, term()}
  # A member unit's indexed copy left its calendar: the unit stops holding
  # the meeting.
  @callback release(group :: map(), occurrence()) :: :ok | {:error, term()}
  @optional_callbacks release: 2

  def list(group, range_start_ms, range_end_ms),
    do: impl().list(group, range_start_ms, range_end_ms)

  def revalidate(group, occurrence), do: impl().revalidate(group, occurrence)

  def release(group, occurrence) do
    impl = impl()

    if Code.ensure_loaded?(impl) and function_exported?(impl, :release, 2),
      do: impl.release(group, occurrence),
      else: :ok
  end

  defp impl,
    do: SystemsRuntime.get_env(:salix_meet, :calendar_occurrences_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.CalendarOccurrences

    @impl true
    def list(_group, _range_start_ms, _range_end_ms), do: {:error, :not_configured}

    @impl true
    def revalidate(_group, _occurrence), do: {:error, :not_configured}
  end
end
