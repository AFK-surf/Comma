defmodule SalixAgent.SessionStorageRevision do
  @moduledoc false

  @spec new() :: String.t()
  def new, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
