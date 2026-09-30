defmodule CommaLogTest do
  @moduledoc """
  The opt-in JSONL diagnostic log: path resolution (`--log-file` flag /
  app env, default disabled), runtime enable/disable, line shape, and the
  sanitizer (truncation, redaction, non-JSON terms).
  """
  use ExUnit.Case, async: false

  alias CommaLog

  setup do
    path = Path.join(System.tmp_dir!(), "salix-jsonl-#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn ->
      CommaLog.disable()
      File.rm(path)
    end)

    {:ok, path: path}
  end

  defp lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  describe "resolve_path/1" do
    test "default is disabled (nil)" do
      assert CommaLog.resolve_path([]) == nil
    end

    test "--log-file <path> and --log-file=<path> forms" do
      assert CommaLog.resolve_path(["--log-file", "/tmp/a.jsonl"]) == "/tmp/a.jsonl"

      assert CommaLog.resolve_path(["x", "--log-file=/tmp/b.jsonl", "y"]) == "/tmp/b.jsonl"
    end

    test "flag beats app config; comma_log app config beats legacy salix_store config" do
      previous_comma = Application.get_env(:comma_log, :log_file)
      previous_salix = Application.get_env(:salix_store, :log_file)

      Application.put_env(:comma_log, :log_file, "/tmp/comma.jsonl")
      Application.put_env(:salix_store, :log_file, "/tmp/salix.jsonl")

      on_exit(fn ->
        restore_app_env(:comma_log, :log_file, previous_comma)
        restore_app_env(:salix_store, :log_file, previous_salix)
      end)

      assert CommaLog.resolve_path(["--log-file", "/tmp/flag.jsonl"]) == "/tmp/flag.jsonl"
      assert CommaLog.resolve_path([]) == "/tmp/comma.jsonl"

      Application.delete_env(:comma_log, :log_file)
      assert CommaLog.resolve_path([]) == "/tmp/salix.jsonl"
    end

    test "log path environment variables are ignored" do
      previous_comma = System.get_env("COMMA_LOG_FILE")
      previous_salix = System.get_env("SALIX_LOG_FILE")

      System.put_env("COMMA_LOG_FILE", "/tmp/comma-env.jsonl")
      System.put_env("SALIX_LOG_FILE", "/tmp/salix-env.jsonl")

      on_exit(fn ->
        restore_env("COMMA_LOG_FILE", previous_comma)
        restore_env("SALIX_LOG_FILE", previous_salix)
      end)

      assert CommaLog.resolve_path([]) == nil
    end
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  test "disabled by default: log/2 writes nothing and is a no-op", %{path: path} do
    refute CommaLog.enabled?()
    assert :ok = CommaLog.log("never", %{a: 1})
    CommaLog.flush()
    refute File.exists?(path)
  end

  test "enable → log → disable round trip", %{path: path} do
    assert :ok = CommaLog.enable(path)
    assert CommaLog.enabled?()
    assert CommaLog.path() == path

    CommaLog.log("hello", %{agent_id: "a1", n: 42})
    CommaLog.flush()

    assert [opened, hello] = lines(path)
    assert opened["event"] == "log_opened"
    assert hello["event"] == "hello"
    assert hello["agent_id"] == "a1"
    assert hello["n"] == 42
    assert hello["node"] == Atom.to_string(node())
    assert {:ok, _, _} = DateTime.from_iso8601(hello["ts"])

    assert :ok = CommaLog.disable()
    refute CommaLog.enabled?()
    CommaLog.log("after-disable", %{})
    before = length(lines(path))
    CommaLog.flush()
    assert length(lines(path)) == before
  end

  test "sanitizer: tuples, atoms, pids, structs, binaries never break encoding", %{path: path} do
    :ok = CommaLog.enable(path)

    CommaLog.log("weird", %{
      outcome: {:wait, %{until: 5}},
      who: self(),
      set: MapSet.new([1, 2]),
      raw: <<0xFF, 0xFE>>,
      atom: :final,
      keyword: [a: 1]
    })

    CommaLog.flush()
    [_opened, weird] = lines(path)
    assert weird["outcome"] == ["wait", %{"until" => 5}]
    assert weird["who"] =~ "#PID"
    assert Enum.sort(weird["set"]) == [1, 2]
    assert weird["raw"] =~ "non-UTF8"
    assert weird["atom"] == "final"
    assert weird["keyword"] == [["a", 1]]
  end

  test "sanitizer: secrets redacted, long strings truncated", %{path: path} do
    :ok = CommaLog.enable(path)

    CommaLog.log("secrets", %{
      llm: %{"api_key" => "sk-very-secret", "model" => "m1"},
      authorization: "Bearer xyz",
      content: String.duplicate("x", 10_000)
    })

    CommaLog.flush()
    [_opened, entry] = lines(path)
    assert entry["llm"]["api_key"] == "[redacted]"
    assert entry["llm"]["model"] == "m1"
    assert entry["authorization"] == "[redacted]"
    assert entry["content"] =~ "[truncated, 10000 bytes total]"
    assert byte_size(entry["content"]) < 10_000
  end
end
