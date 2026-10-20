defmodule SalixAgent.SessionStorageRevision do
  @moduledoc false

  @spec new() :: String.t()
  def new, do: SystemsRuntime.Proc.random_bytes(16) |> Base.encode16(case: :lower)
end
