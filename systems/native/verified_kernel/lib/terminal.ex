defmodule SalixVerifiedKernel.Terminal do
  @moduledoc """
  A VT100 terminal emulator with common xterm extensions, implemented in
  `VerifiedKernel.Terminal` (Lean) and resident behind a NIF resource.

  A terminal is mutable: `feed/2` and `resize/3` change it in place and
  return it. One process owns a terminal at a time; the resource serializes
  concurrent calls. See the Lean module for the supported sequences and
  bounds.
  """

  alias SalixVerifiedKernel.Native

  @opaque t :: reference()

  @doc "Clamp a requested size to the supported bounds."
  @spec clamp_size(integer(), integer()) :: {pos_integer(), pos_integer()}
  def clamp_size(cols, rows), do: {cols |> max(10) |> min(500), rows |> max(2) |> min(200)}

  @doc "A blank terminal of `cols` × `rows`."
  @spec new(integer(), integer()) :: t()
  def new(cols \\ 80, rows \\ 24) do
    {cols, rows} = clamp_size(cols, rows)
    Native.terminal_new(cols, rows)
  end

  @doc """
  Process output bytes from the remote side. Returns the terminal and the
  replies it owes the remote side, such as a cursor position report.
  """
  @spec feed(t(), binary()) :: {t(), binary()}
  def feed(terminal, data) when is_binary(data),
    do: {terminal, Native.terminal_feed(terminal, data)}

  @doc """
  Change the screen size. Content keeps its top-left position; when the
  cursor would fall below the new last row, the top rows scroll off.
  """
  @spec resize(t(), integer(), integer()) :: t()
  def resize(terminal, cols, rows) do
    {cols, rows} = clamp_size(cols, rows)
    :ok = Native.terminal_resize(terminal, cols, rows)
    terminal
  end

  @doc """
  The visible screen: one string per row (trailing blanks removed), the
  1-based cursor position and visibility, the title, and whether the
  alternate screen (used by full-screen programs) is active.
  """
  @spec snapshot(t()) :: map()
  def snapshot(terminal), do: :erlang.binary_to_term(Native.terminal_snapshot(terminal))

  @doc "Whether the remote side selected application cursor keys (DECCKM)."
  @spec application_cursor?(t()) :: boolean()
  def application_cursor?(terminal), do: Native.terminal_app_cursor(terminal)
end
