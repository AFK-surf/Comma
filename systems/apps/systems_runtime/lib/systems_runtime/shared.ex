defmodule SystemsRuntime.Atomics do
  @moduledoc "`:atomics`: each function is the `:atomics` function of the same name."

  for {function, arity} <- [
        new: 2,
        get: 2,
        put: 3,
        add: 3,
        add_get: 3,
        sub: 3,
        sub_get: 3,
        exchange: 3,
        compare_exchange: 4,
        info: 1
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc "As `:atomics.#{function}/#{arity}`."
    def unquote(function)(unquote_splicing(args)),
      do: :atomics.unquote(function)(unquote_splicing(args))
  end
end

defmodule SystemsRuntime.Counters do
  @moduledoc "`:counters`: each function is the `:counters` function of the same name."

  for {function, arity} <- [new: 2, get: 2, add: 3, sub: 3, put: 3, info: 1] do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc "As `:counters.#{function}/#{arity}`."
    def unquote(function)(unquote_splicing(args)),
      do: :counters.unquote(function)(unquote_splicing(args))
  end
end

defmodule SystemsRuntime.PersistentTerm do
  @moduledoc "`:persistent_term`: each function is the `:persistent_term` function of the same name."

  @doc "As `:persistent_term.get/1`."
  def get(key), do: :persistent_term.get(key)

  @doc "As `:persistent_term.get/2`."
  def get(key, default), do: :persistent_term.get(key, default)

  @doc "As `:persistent_term.put/2`."
  def put(key, value), do: :persistent_term.put(key, value)

  @doc "As `:persistent_term.erase/1`."
  def erase(key), do: :persistent_term.erase(key)
end
