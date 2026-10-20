defmodule BridgeForTeams.Migrations.SlackTaskBindings do
  @moduledoc """
  Binds each live Agent Swarm's Slack connections that deliver to a Worker to
  Tasks instead, once: each new Slack thread then becomes a Task of the
  swarm's Task agent that runs the Worker's model (none: the swarm's default
  Task model). Workers are retired; a thread already bound to the Worker stays
  with it, so its Task finishes there.

  `bind.(tenant_id, group_id)` changes one swarm's connections (in a release,
  `SalixAgent.Migrations.SlackTaskBindings.bind/2`); a connection already bound
  to Tasks or to the Router is left as it is, so a pass run again changes
  nothing. Projects are read through the repo the caller gives, 100 at a
  time.
  """

  @page 100

  @typedoc "`bind.(tenant_id, group_id)`: how many connections it bound to Tasks."
  @type bind :: (String.t(), String.t() -> {:ok, non_neg_integer()} | {:error, term()})

  @spec run(module(), bind()) :: {:ok, %{bound: non_neg_integer()}} | {:error, term()}
  def run(repo, bind), do: page(repo, bind, nil, 0)

  defp page(repo, bind, after_id, count) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT p.id::text, o.salix_tenant_id, p.salix_group_id
        FROM projects p JOIN organizations o ON o.id = p.org_id
        WHERE p.salix_group_id IS NOT NULL AND p.archived_at IS NULL
          AND o.salix_tenant_id IS NOT NULL
          AND ($1::uuid IS NULL OR p.id > $1::uuid)
        ORDER BY p.id LIMIT $2
        """,
        [after_id && Ecto.UUID.dump!(after_id), @page]
      )

    result =
      Enum.reduce_while(rows, {:ok, count}, fn [id, tenant_id, group_id], {:ok, count} ->
        case bind.(tenant_id, group_id) do
          {:ok, bound} -> {:cont, {:ok, count + bound}}
          {:error, reason} -> {:halt, {:error, {id, reason}}}
        end
      end)

    case {result, rows} do
      {{:ok, count}, rows} when length(rows) == @page ->
        [id | _] = List.last(rows)
        page(repo, bind, id, count)

      {{:ok, count}, _rows} ->
        {:ok, %{bound: count}}

      {error, _rows} ->
        error
    end
  end
end
