defmodule SystemsRuntime.ClockCalls do
  @moduledoc """
  Finds compiled modules that read time or arm timers without `SystemsClock`.
  A test cannot control such a call, so its result depends on the machine.

  It reads the import table of each `.beam` file, the remote functions the
  module calls, and its literal table, which holds captures such as
  `&Process.sleep/1`. So it needs no source parsing and sees every call and
  capture the compiler emitted. Test code (a source path with a `test`
  directory) and the clock modules themselves are not checked.
  """

  @replacements %{
    {DateTime, :utc_now} => "SystemsClock.utc_now/0",
    {NaiveDateTime, :utc_now} => "SystemsClock.utc_now/0 |> DateTime.to_naive/1",
    {System, :monotonic_time} => "SystemsClock.monotonic_time/1",
    {System, :system_time} => "SystemsClock.system_time/1",
    {System, :os_time} => "SystemsClock.system_time/1",
    {:erlang, :monotonic_time} => "SystemsClock.monotonic_time/1",
    {:erlang, :system_time} => "SystemsClock.system_time/1",
    {:os, :system_time} => "SystemsClock.system_time/1",
    {Process, :send_after} => "SystemsClock.send_after/4",
    {:erlang, :send_after} => "SystemsClock.send_after/4",
    {:erlang, :start_timer} => "SystemsClock.start_timer/3",
    {Process, :sleep} => "SystemsClock.sleep/1",
    {:timer, :sleep} => "SystemsClock.sleep/1"
  }

  # The clock itself, and the simulation scheduler that moves it and bounds
  # a run in real time.
  @exempt ["Elixir.SystemsClock", "Elixir.SystemsRuntime", "Elixir.SystemsSim"]

  @typedoc "A module and the clock calls it makes, as `\"Module.fun/arity\"` strings."
  @type report :: %{String.t() => [String.t()]}

  @doc "The direct clock calls of the modules compiled into `ebin_dirs`."
  @spec scan([Path.t()]) :: report()
  def scan(ebin_dirs) do
    for dir <- ebin_dirs,
        path <- Path.wildcard(Path.join(dir, "*.beam")),
        {module, calls} <- [module_calls(path)],
        calls != [],
        into: %{},
        do: {module, calls}
  end

  @doc "The function to call instead of `call`, a `\"Module.fun/arity\"` string."
  @spec replacement(String.t()) :: String.t()
  def replacement(call) do
    {module, fun} =
      Enum.find(Map.keys(@replacements), fn {module, fun} ->
        String.starts_with?(call, "#{format_module(module)}.#{fun}/")
      end)

    Map.fetch!(@replacements, {module, fun})
  end

  @doc """
  The calls in `report` that `baseline` does not list: calls added to a
  listed module, or modules it does not list.
  """
  @spec new_calls(report(), report()) :: report()
  def new_calls(report, baseline) do
    for {module, calls} <- report,
        added = calls -- Map.get(baseline, module, []),
        added != [],
        into: %{},
        do: {module, added}
  end

  defp module_calls(path) do
    path = String.to_charlist(path)

    with {:ok, {module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]),
         name = Atom.to_string(module),
         false <- exempt?(name),
         false <- test_source?(path) do
      calls =
        for {mod, fun, arity} <- imports ++ captures(path),
            Map.has_key?(@replacements, {mod, fun}),
            uniq: true,
            do: "#{format_module(mod)}.#{fun}/#{arity}"

      {String.replace_prefix(name, "Elixir.", ""), Enum.sort(calls)}
    else
      _ -> {nil, []}
    end
  end

  defp captures(path) do
    case :beam_lib.chunks(path, [:literals]) do
      {:ok, {_, [literals: literals]}} ->
        Enum.flat_map(literals, fn {_index, literal} -> external_funs(literal) end)

      _ ->
        []
    end
  end

  # A capture can sit inside a literal, as in `@defaults [sleep: &Process.sleep/1]`.
  defp external_funs(term) when is_function(term) do
    case Function.info(term, :type) do
      {:type, :external} -> [:erlang.fun_info_mfa(term)]
      _ -> []
    end
  end

  defp external_funs(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> external_funs()

  defp external_funs(term) when is_map(term),
    do: term |> Map.to_list() |> external_funs()

  defp external_funs([head | tail]), do: external_funs(head) ++ external_funs(tail)
  defp external_funs(_term), do: []

  defp exempt?(name),
    do: Enum.any?(@exempt, &(name == &1 or String.starts_with?(name, &1 <> ".")))

  defp test_source?(path) do
    case :beam_lib.chunks(path, [:compile_info]) do
      {:ok, {_, [compile_info: info]}} ->
        info |> Keyword.get(:source, ~c"") |> to_string() |> Path.split() |> Enum.member?("test")

      _ ->
        false
    end
  end

  defp format_module(module) when is_atom(module) do
    case Atom.to_string(module) do
      "Elixir." <> name -> name
      name -> ":" <> name
    end
  end
end
