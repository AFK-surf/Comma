defmodule SalixStore.ReadScope do
  @moduledoc """
  Process-scoped memo for read-only control records during one unit of work.

  One inbound provider callback, one delivery staging chain, and one session
  activation each resolve the same canonical Agent, Group and connect records
  at several seams. Every seam used to read its record again from the object
  store, so one Slack message paid dozens of identical round trips before the
  model request started. Inside one scope the first read answers the rest.

  The memo lives in the process dictionary of the calling process and only
  while `run/1` is active. Outside a scope every lookup goes straight to the
  store, so background workers, control-plane writers and tests keep their
  read-through behavior. Only `{:ok, value}` results are memoized: a miss or a
  storage fault is retried by the next caller exactly as before. A writer that
  updates a memoized record inside its own scope calls `invalidate/1`.

  A scope is a consistency window, not a cache: records do not change inside
  one callback because these paths never write them, and a concurrent
  control-plane write that lands between two reads of the same request was
  already a race the second read could observe or miss.
  """

  @key :salix_store_read_scope
  @join_timeout_ms 30_000

  @doc "Runs `fun` with a fresh memo, or inside the caller's existing scope."
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    case Process.get(@key) do
      nil ->
        Process.put(@key, %{})

        try do
          fun.()
        after
          stop_pending(Process.delete(@key))
        end

      _memo ->
        fun.()
    end
  end

  @doc """
  The caller's memo, for seeding a child task with `run/2`. `nil` outside a
  scope, in which case `run/2` runs the child without a scope too. Reads
  from `prefetch/2` that are back are included; reads still in flight are
  not, so a seed is plain and never waits.
  """
  @spec capture() :: map() | nil
  def capture do
    case Process.get(@key) do
      nil ->
        nil

      memo ->
        # A prefetch that is back is adopted; one still in flight stays
        # pending here (this scope's own `fetch/2` joins it) and is not
        # handed on, so a seeded unit of work never waits on a read it did
        # not start. It reads the key itself if it needs it.
        {ready, pending} =
          Enum.reduce(memo, {%{}, %{}}, fn
            {key, {:pending, task}}, {ready, pending} ->
              case Task.yield(task, 0) do
                {:ok, {:ok, _value} = result} -> {Map.put(ready, key, result), pending}
                {:ok, _other} -> {ready, pending}
                {:exit, _reason} -> {ready, pending}
                nil -> {ready, Map.put(pending, key, {:pending, task})}
              end

            {key, value}, {ready, pending} ->
              {Map.put(ready, key, value), pending}
          end)

        Process.put(@key, Map.merge(ready, pending))
        ready
    end
  end

  @doc """
  Starts `read` in a task inside the active scope so its round trip overlaps
  the caller's next steps; `fetch/2` of the same key joins it. Outside a
  scope, or for a key already known, nothing starts.
  """
  @spec prefetch(term(), (-> term())) :: :ok
  def prefetch(key, read) when is_function(read, 0) do
    case Process.get(@key) do
      nil ->
        :ok

      memo ->
        if Map.has_key?(memo, key) do
          :ok
        else
          Process.put(@key, Map.put(memo, key, {:pending, Task.async(read)}))
          :ok
        end
    end
  end

  # A read that is not back by the deadline is dropped: the next `fetch/2`
  # of its key reads again, inside whatever budget that caller has.
  defp join_pending(%Task{} = task) do
    case Task.yield(task, @join_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, _value} = result} -> result
      _other -> :none
    end
  end

  # Reads still in flight when a scope ends are stopped, so no reply lands
  # in the owner's mailbox after the unit of work that started it.
  defp stop_pending(memo) when is_map(memo) do
    Enum.each(memo, fn
      {_key, {:pending, %Task{} = task}} -> Task.shutdown(task, :brutal_kill)
      _entry -> :ok
    end)
  end

  defp stop_pending(_memo), do: :ok

  @doc """
  Runs `fun` in a scope seeded with an earlier `capture/0` of the same unit
  of work. Records already read there are answered without a store round
  trip; reads added here stay here (the seed is a snapshot). Inside an
  active scope the seed joins it, and the scope's own reads win.
  """
  @spec run(map() | nil, (-> result)) :: result when result: term()
  def run(nil, fun) when is_function(fun, 0), do: fun.()

  def run(memo, fun) when is_map(memo) and is_function(fun, 0) do
    case Process.get(@key) do
      nil ->
        Process.put(@key, memo)

        try do
          fun.()
        after
          stop_pending(Process.delete(@key))
        end

      own ->
        Process.put(@key, Map.merge(memo, own))
        fun.()
    end
  end

  @doc """
  Returns the memoized `{:ok, value}` for `key`, or runs `read` and memoizes
  its `{:ok, value}` result. Errors are never memoized.
  """
  @spec fetch(term(), (-> result)) :: result when result: term()
  def fetch(key, read) when is_function(read, 0) do
    case Process.get(@key) do
      nil ->
        read.()

      memo ->
        case Map.fetch(memo, key) do
          {:ok, {:pending, task}} ->
            case join_pending(task) do
              :none ->
                Process.put(@key, Map.delete(memo, key))
                fetch(key, read)

              result ->
                Process.put(@key, Map.put(memo, key, result))
                result
            end

          {:ok, result} ->
            result

          :error ->
            result = read.()

            case result do
              {:ok, _value} -> Process.put(@key, Map.put(memo, key, result))
              _other -> :ok
            end

            result
        end
    end
  end

  @doc """
  Adds the entries of a child's `capture/0` that the active scope does not
  hold yet. A parent that ran branches in tasks learns what they read.
  """
  @spec merge(map() | nil) :: :ok
  def merge(nil), do: :ok

  def merge(memo) when is_map(memo) do
    case Process.get(@key) do
      nil -> :ok
      own -> Process.put(@key, Map.merge(memo, own))
    end

    :ok
  end

  @doc "Forgets `key` in the active scope, if any."
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    case Process.get(@key) do
      nil -> :ok
      memo -> Process.put(@key, Map.delete(memo, key))
    end

    :ok
  end

  @doc "Whether the calling process is inside a read scope."
  @spec active?() :: boolean()
  def active?, do: not is_nil(Process.get(@key))
end
