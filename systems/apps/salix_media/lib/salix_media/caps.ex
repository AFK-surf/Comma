defmodule SalixMedia.Caps do
  @moduledoc """
  Per-turn expensive tool caps. A single agent turn may run at most
  2 `image.generate`, 1 `video.generate`, and 5 `script.run` calls.
  """

  @caps %{
    "image.generate" => 2,
    "video.generate" => 1,
    "script.run" => 5
  }

  @doc "The per-turn cap map keyed by canonical tool name."
  @spec limits() :: %{String.t() => pos_integer()}
  def limits, do: @caps

  @doc """
  Check whether one more `tool` call is allowed given `counts` already used this
  turn. `counts` is a map of canonical tool-name => non-negative integer.
  Returns `:ok` if the tool is
  uncapped or has headroom, `{:error, :cap_exceeded}` otherwise.
  """
  @spec check(map(), String.t()) :: :ok | {:error, :cap_exceeded}
  def check(counts, tool) when is_map(counts) and is_binary(tool) do
    case Map.fetch(@caps, tool) do
      {:ok, cap} ->
        used = Map.get(counts, tool) || 0
        if used < cap, do: :ok, else: {:error, :cap_exceeded}

      :error ->
        :ok
    end
  end
end
