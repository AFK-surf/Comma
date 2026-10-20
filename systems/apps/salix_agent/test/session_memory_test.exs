defmodule SalixAgent.SessionMemoryTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.SessionMemory

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "salix-memory-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    keys = [:session_cgroup_path, :session_memory_budget_bytes]
    previous = Map.new(keys, &{&1, SystemsRuntime.get_env(:salix_agent, &1)})
    SystemsRuntime.put_env(:salix_agent, :session_cgroup_path, path)
    SystemsRuntime.delete_env(:salix_agent, :session_memory_budget_bytes)

    on_exit(fn ->
      File.rm_rf!(path)

      Enum.each(previous, fn {key, value} ->
        if value == nil,
          do: SystemsRuntime.delete_env(:salix_agent, key),
          else: SystemsRuntime.put_env(:salix_agent, key, value)
      end)
    end)

    %{path: path}
  end

  test "reads container charge separately from reclaimable file cache", %{path: path} do
    File.write!(Path.join(path, "memory.current"), "900\n")
    File.write!(Path.join(path, "memory.max"), "1000\n")
    File.write!(Path.join(path, "memory.stat"), "anon 600\ninactive_file 200\n")
    SystemsRuntime.put_env(:salix_agent, :session_memory_budget_bytes, 123_456_789)
    assert SessionMemory.sample() == {:ok, %{used: 900, limit: 1000, reclaimable: 200}}
  end
end
