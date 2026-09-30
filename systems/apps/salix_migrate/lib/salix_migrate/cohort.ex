defmodule SalixMigrate.Cohort do
  @moduledoc """
  Cohort rollout while Willow and Salix run side by side.

  Cutover is driven in batches rather than all at once: given the full agent
  population, `next/2` selects the next cohort of *not-yet-migrated* agents to
  cut over (bounded by `:size`, optionally filtered by a `:select`
  predicate/selector), and `mark/1` cuts that cohort over by flipping each
  agent's one-way `migrated` flag through `SalixMigrate.Cutover`. `progress/1`
  reports how far the rollout has advanced across the population.

  Selection reads the authoritative per-agent registry flag (never a cached
  product view), so a re-run after a partial rollout naturally skips agents that
  already cut over and is safe to retry. Order of `agent_ids` is preserved so a
  caller can roll out deterministically (e.g. canary-first by passing a sorted
  or hand-ordered list).
  """

  alias SalixMigrate.Cutover

  @default_size 50

  @doc """
  Select the next cohort to cut over from `agent_ids`.

  Returns the leading `:size` (default #{@default_size}) agents that are not yet
  migrated, in the order they appear in `agent_ids`. A `:select` option further
  narrows eligibility:

    * a 1-arity predicate `agent_id -> boolean()` — keep where it returns true
    * a list of agent ids — keep only those (intersection)

  Agents that are already migrated are always excluded.
  """
  @spec next([String.t()], keyword()) :: [String.t()]
  def next(agent_ids, opts \\ []) when is_list(agent_ids) do
    size = opts[:size] || @default_size

    agent_ids
    |> Enum.filter(&eligible?(&1, opts[:select]))
    |> Enum.filter(&(Cutover.migrated?(&1) == false))
    |> Enum.take(size)
  end

  @doc """
  Cut over every agent in `cohort` (one-way, idempotent). Returns a result map
  with the agents that were marked `:ok` and any `:errors` as
  `[{agent_id, reason}]`, so a partial failure is reported rather than swallowed.
  """
  @spec mark([String.t()]) :: %{ok: [String.t()], errors: [{String.t(), term()}]}
  def mark(cohort) when is_list(cohort) do
    Enum.reduce(cohort, %{ok: [], errors: []}, fn id, acc ->
      case Cutover.mark_migrated(id) do
        :ok -> %{acc | ok: [id | acc.ok]}
        {:error, reason} -> %{acc | errors: [{id, reason} | acc.errors]}
      end
    end)
    |> then(fn acc -> %{ok: Enum.reverse(acc.ok), errors: Enum.reverse(acc.errors)} end)
  end

  @doc """
  Report rollout progress across `agent_ids` as counts of how many have cut over.
  `remaining` excludes agents whose flag could not be read (counted under
  `errors`) so a transient read failure never looks like completion.
  """
  @spec progress([String.t()]) :: %{
          total: non_neg_integer(),
          migrated: non_neg_integer(),
          remaining: non_neg_integer(),
          errors: non_neg_integer()
        }
  def progress(agent_ids) when is_list(agent_ids) do
    counts =
      Enum.reduce(agent_ids, %{migrated: 0, remaining: 0, errors: 0}, fn id, acc ->
        case Cutover.migrated?(id) do
          true -> %{acc | migrated: acc.migrated + 1}
          false -> %{acc | remaining: acc.remaining + 1}
          {:error, _} -> %{acc | errors: acc.errors + 1}
        end
      end)

    Map.put(counts, :total, length(agent_ids))
  end

  defp eligible?(_id, nil), do: true
  defp eligible?(id, pred) when is_function(pred, 1), do: pred.(id) == true
  defp eligible?(id, allowed) when is_list(allowed), do: id in allowed
end
