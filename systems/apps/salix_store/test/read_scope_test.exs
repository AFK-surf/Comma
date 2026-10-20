defmodule SalixStore.ReadScopeTest do
  use SystemsClock.Case, async: true

  alias SystemsRuntime.Agent
  alias SalixStore.ReadScope

  defp counting_read(counter, result) do
    fn ->
      Agent.update(counter, &(&1 + 1))
      result
    end
  end

  test "a scope serves repeated successful reads from the first read" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    read = counting_read(counter, {:ok, %{"v" => 1}})

    ReadScope.run(fn ->
      assert ReadScope.active?()
      assert {:ok, %{"v" => 1}} = ReadScope.fetch(:key, read)
      assert {:ok, %{"v" => 1}} = ReadScope.fetch(:key, read)
      assert {:ok, %{"v" => 1}} = ReadScope.fetch(:key, counting_read(counter, {:ok, :other}))
    end)

    assert Agent.get(counter, & &1) == 1
    refute ReadScope.active?()
    assert {:ok, :other} = ReadScope.fetch(:key, counting_read(counter, {:ok, :other}))
  end

  test "errors are not memoized and invalidation forgets a key" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    ReadScope.run(fn ->
      assert {:error, :not_found} =
               ReadScope.fetch(:key, counting_read(counter, {:error, :not_found}))

      assert {:ok, 1} = ReadScope.fetch(:key, counting_read(counter, {:ok, 1}))
      assert {:ok, 1} = ReadScope.fetch(:key, counting_read(counter, {:ok, 2}))
      :ok = ReadScope.invalidate(:key)
      assert {:ok, 2} = ReadScope.fetch(:key, counting_read(counter, {:ok, 2}))
    end)

    assert Agent.get(counter, & &1) == 3
  end
end
