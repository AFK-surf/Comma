defmodule SalixMCP.ConfigurationReadsTest do
  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMcp", "Elixir.SalixMCP"]
  alias SalixStore.Keys

  defmodule Storage do
    def list(_prefix, _opts) do
      {_, records} = SystemsRuntime.PersistentTerm.get(__MODULE__)
      {:ok, %{objects: Enum.map(Map.keys(records), &%{key: &1}), next: nil}}
    end

    # Background processes read through the same backend, and processes an
    # earlier test or app left in this VM may read the same keys. Only reads
    # made on behalf of the test process are held and reported.
    def get(key, _opts) do
      {owner, records} = SystemsRuntime.PersistentTerm.get(__MODULE__)

      case Map.fetch(records, key) do
        {:ok, record} ->
          if owner in Process.get(:"$callers", []) do
            SystemsRuntime.Proc.send(owner, {:read, SystemsRuntime.Proc.self(), key})

            SystemsClock.vreceive do
              :release -> {:ok, %{body: Jason.encode!(record)}}
            after
              5_000 -> {:error, :test_read_not_released}
            end
          else
            {:ok, %{body: Jason.encode!(record)}}
          end

        :error ->
          {:error, :not_found}
      end
    end
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, Storage)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, previous),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)

      SystemsRuntime.PersistentTerm.erase(Storage)
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

    SystemsRuntime.PersistentTerm.put(Storage, {SystemsRuntime.Proc.self(), records})

    task =
      SystemsRuntime.Task.async(fn ->
        SalixMCP.Store.list_group_bindings("tenant", "group", include_disabled: false)
      end)

    readers =
      for _ <- 1..4 do
        settle_receive({:read, pid, _key})
        pid
      end

    assert length(Enum.uniq(readers)) == 4
    settle_refute_receive({:read, _, _}, 30)
    Enum.each(readers, &send(&1, :release))
    bindings = finish_reads(task)

    assert Enum.map(bindings, & &1["alias"]) == Enum.map(3..9, &"alias#{&1}")
    assert Enum.all?(bindings, &(&1["connection"]["status"] == "configured"))
    assert Enum.all?(bindings, &(&1["config_configured"] == true))
    refute Enum.any?(bindings, &Map.has_key?(&1, "config_values"))
  end

  defp finish_reads(%Task{ref: ref} = task) do
    SystemsClock.vreceive do
      {:read, pid, _key} ->
        SystemsRuntime.Proc.send(pid, :release)
        finish_reads(task)

      {^ref, result} ->
        SystemsRuntime.Proc.demonitor(ref, [:flush])
        result
    after
      5_000 -> flunk("configuration reads did not finish")
    end
  end
end
