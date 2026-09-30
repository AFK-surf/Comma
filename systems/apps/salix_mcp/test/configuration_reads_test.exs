defmodule SalixMCP.ConfigurationReadsTest do
  use ExUnit.Case, async: false

  alias SalixStore.Keys

  defmodule Storage do
    def list(_prefix, _opts) do
      {_, records} = :persistent_term.get(__MODULE__)
      {:ok, %{objects: Enum.map(Map.keys(records), &%{key: &1}), next: nil}}
    end

    def get(key, _opts) do
      {owner, records} = :persistent_term.get(__MODULE__)
      send(owner, {:read, self(), key})

      receive do
        :release ->
          case Map.fetch(records, key) do
            {:ok, record} -> {:ok, %{body: Jason.encode!(record)}}
            :error -> {:error, :not_found}
          end
      after
        5_000 -> {:error, :test_read_not_released}
      end
    end
  end

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, Storage)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_store, :s3_backend, previous),
        else: Application.delete_env(:salix_store, :s3_backend)

      :persistent_term.erase(Storage)
    end)
  end

  test "configuration reads overlap at most four bindings and preserve filtering and projections" do
    prefix = Keys.ctl_mcp_group_bindings_prefix("tenant", "group")

    records =
      Map.new(1..9, fn n ->
        {prefix <> "binding#{n}/state.json",
         %{
           "tenant_id" => "tenant",
           "group_id" => "group",
           "binding_id" => "binding#{n}",
           "alias" => "alias#{10 - n}",
           "enabled" => n != 8,
           "deleted_at" => if(n == 9, do: 1),
           "config_values" => %{"secret" => "never return"}
         }}
      end)

    :persistent_term.put(Storage, {self(), records})

    task =
      Task.async(fn ->
        SalixMCP.Store.list_group_bindings("tenant", "group", include_disabled: false)
      end)

    readers =
      for _ <- 1..4 do
        assert_receive {:read, pid, _key}, 1_000
        pid
      end

    assert length(Enum.uniq(readers)) == 4
    refute_receive {:read, _, _}, 30
    Enum.each(readers, &send(&1, :release))
    bindings = finish_reads(task)

    assert Enum.map(bindings, & &1["alias"]) == Enum.map(3..9, &"alias#{&1}")
    assert Enum.all?(bindings, &(&1["connection"]["status"] == "configured"))
    assert Enum.all?(bindings, &(&1["config_configured"] == true))
    refute Enum.any?(bindings, &Map.has_key?(&1, "config_values"))
  end

  defp finish_reads(%Task{ref: ref} = task) do
    receive do
      {:read, pid, _key} ->
        send(pid, :release)
        finish_reads(task)

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result
    after
      5_000 -> flunk("configuration reads did not finish")
    end
  end
end
