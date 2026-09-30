defmodule SalixStore.S3.FakeLifecycleTest do
  use ExUnit.Case, async: false

  alias SalixStore.S3.Fake

  test "duplicate supervised starts reset and ignore the existing fake backend" do
    unless Process.whereis(Fake) do
      start_supervised!(Fake)
    end

    assert {:ok, %{etag: _}} = Fake.put("leaky-key", "value", [])
    assert {:ok, %{key: "leaky-key"}} = Fake.head("leaky-key")

    assert :undefined = start_supervised!(Fake)
    assert {:error, :not_found} = Fake.head("leaky-key")
    assert Process.whereis(Fake)
  end
end
