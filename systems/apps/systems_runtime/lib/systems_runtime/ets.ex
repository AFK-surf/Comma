defmodule SystemsRuntime.ETS do
  @moduledoc "ETS: each function is the `:ets` function of the same name."

  for {function, arity} <- [
        new: 2,
        insert: 2,
        insert_new: 2,
        lookup: 2,
        lookup_element: 3,
        lookup_element: 4,
        member: 2,
        update_counter: 3,
        update_counter: 4,
        update_element: 3,
        take: 2,
        delete: 1,
        delete: 2,
        delete_object: 2,
        delete_all_objects: 1,
        info: 1,
        info: 2,
        first: 1,
        next: 2,
        last: 1,
        prev: 2,
        give_away: 3,
        match_delete: 2,
        select_replace: 2,
        select: 2,
        select_count: 2,
        select_delete: 2,
        match: 2,
        match_object: 2,
        tab2list: 1,
        foldl: 3
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc "As `:ets.#{function}/#{arity}`."
    def unquote(function)(unquote_splicing(args)),
      do: :ets.unquote(function)(unquote_splicing(args))
  end

  @doc "As `:ets.whereis/1`."
  def whereis(name) when is_atom(name), do: :ets.whereis(name)
end
