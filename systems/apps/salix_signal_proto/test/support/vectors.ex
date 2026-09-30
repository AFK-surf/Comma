defmodule SalixSignalProto.Test.Vectors do
  @moduledoc false
  # Loads test vectors: public standards in test/fixtures/public and approved
  # CRS vectors in test/fixtures/crs/<section>.

  @fixtures Path.expand("../fixtures", __DIR__)

  def load!(relative_path) do
    @fixtures |> Path.join(relative_path) |> File.read!() |> JSON.decode!()
  end

  def hex!(hex), do: Base.decode16!(hex, case: :mixed)
end
