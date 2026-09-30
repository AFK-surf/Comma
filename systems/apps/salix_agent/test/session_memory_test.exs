defmodule SalixAgent.SessionMemoryTest do
  use ExUnit.Case, async: false
  alias SalixAgent.SessionMemory

  setup do
    path = Path.join(System.tmp_dir!(), "salix-memory-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    keys = [:session_cgroup_path, :session_memory_budget_bytes]
    previous = Map.new(keys, &{&1, Application.get_env(:salix_agent, &1)})
    Application.put_env(:salix_agent, :session_cgroup_path, path)
    Application.delete_env(:salix_agent, :session_memory_budget_bytes)

    on_exit(fn ->
      File.rm_rf!(path)

      Enum.each(previous, fn {key, value} ->
        if value == nil,
          do: Application.delete_env(:salix_agent, key),
          else: Application.put_env(:salix_agent, key, value)
      end)
    end)

    %{path: path}
  end

  test "reads container charge separately from reclaimable file cache", %{path: path} do
    File.write!(Path.join(path, "memory.current"), "900\n")
    File.write!(Path.join(path, "memory.max"), "1000\n")
    File.write!(Path.join(path, "memory.stat"), "anon 600\ninactive_file 200\n")
    Application.put_env(:salix_agent, :session_memory_budget_bytes, 123_456_789)
    assert SessionMemory.sample() == {:ok, %{used: 900, limit: 1000, reclaimable: 200}}
  end

  test "unlimited, malformed, and missing cgroups use the default 4 GiB budget", %{path: path} do
    assert {:ok, %{used: used, limit: 4_294_967_296}} = SessionMemory.sample()
    assert used > 0
    File.write!(Path.join(path, "memory.current"), "900\n")
    File.write!(Path.join(path, "memory.max"), "max\n")
    assert {:ok, %{used: used, limit: 4_294_967_296}} = SessionMemory.sample()
    assert used > 0
    File.write!(Path.join(path, "memory.max"), "-1\n")
    assert {:ok, %{used: used, limit: 4_294_967_296}} = SessionMemory.sample()
    assert used > 0
    Application.put_env(:salix_agent, :session_memory_budget_bytes, 123_456_789)
    assert {:ok, %{used: used, limit: 123_456_789}} = SessionMemory.sample()
    assert used > 0
    Application.put_env(:salix_agent, :session_memory_budget_bytes, 0)
    assert SessionMemory.sample() == {:error, :invalid_memory_budget}
  end
end
