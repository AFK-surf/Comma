defmodule SalixStore.S3Case do
  @moduledoc """
  Test helper for exercising a backend with a unique key prefix per test so
  parallel tests don't collide on the shared MinIO bucket.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import SalixStore.S3Case
    end
  end

  @doc "A unique key prefix for the running test."
  def unique_prefix(tag \\ "t") do
    "itest/#{tag}/#{System.unique_integer([:positive])}/"
  end
end
