defmodule SalixSignalProto.Session.Record do
  @moduledoc """
  The session record for one remote address (CRS-04 §8.1): one current
  session or none, and up to 40 previous sessions, newest first.

  `encode/1` and `decode/1` give a storage form. It is local to Comma and is
  not an interoperability format (CRS-03 §1).
  """

  alias SalixSignalProto.Session.State

  @max_previous 40
  @format_version 1

  defstruct current: nil, previous: []

  @type t :: %__MODULE__{current: State.t() | nil, previous: [State.t()]}

  @doc "A record with no session."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Makes `state` current. The old current session, if any, becomes the newest
  previous session.
  """
  @spec promote(t(), State.t()) :: t()
  def promote(%__MODULE__{current: nil} = record, state), do: %{record | current: state}

  def promote(%__MODULE__{current: current, previous: previous}, state),
    do: %__MODULE__{current: state, previous: Enum.take([current | previous], @max_previous)}

  @doc "Moves the current session to the previous sessions."
  @spec archive_current(t()) :: t()
  def archive_current(%__MODULE__{current: nil} = record), do: record

  def archive_current(%__MODULE__{current: current, previous: previous}),
    do: %__MODULE__{current: nil, previous: Enum.take([current | previous], @max_previous)}

  @doc """
  Replaces the session at `position` in `sessions/1` with `state` and makes it
  current (CRS-04 §8.3 rule 2, §8.4 item 3).
  """
  @spec accept(t(), non_neg_integer(), State.t()) :: t()
  def accept(%__MODULE__{current: current} = record, 0, state) when current != nil,
    do: %{record | current: state}

  def accept(%__MODULE__{current: current, previous: previous}, position, state) do
    index = if current == nil, do: position, else: position - 1
    promote(%__MODULE__{current: current, previous: List.delete_at(previous, index)}, state)
  end

  @doc "The sessions in trial order: the current one first, then previous, newest first."
  @spec sessions(t()) :: [State.t()]
  def sessions(%__MODULE__{current: nil, previous: previous}), do: previous
  def sessions(%__MODULE__{current: current, previous: previous}), do: [current | previous]

  @doc "Encodes the record for storage."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = record) do
    :erlang.term_to_binary({__MODULE__, @format_version, record}, [:deterministic])
  end

  @doc """
  Decodes a stored record. Returns `{:error, :invalid_record}` for bytes that
  `encode/1` did not produce.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_record}
  def decode(bytes) when is_binary(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      {__MODULE__, @format_version, %__MODULE__{current: current, previous: previous} = record}
      when is_list(previous) ->
        if (is_nil(current) or is_struct(current, State)) and
             Enum.all?(previous, &is_struct(&1, State)),
           do: {:ok, record},
           else: {:error, :invalid_record}

      _ ->
        {:error, :invalid_record}
    end
  rescue
    ArgumentError -> {:error, :invalid_record}
  end
end
