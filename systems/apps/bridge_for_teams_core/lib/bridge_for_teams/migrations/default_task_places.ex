defmodule BridgeForTeams.Migrations.DefaultTaskPlaces do
  @moduledoc """
  Gives each live Agent Swarm whose live Workers all run their Tasks on the
  swarm's Cloud VM the Cloud VM as its default place to run Tasks
  (`SalixAgent.TaskPlace`), once, so its Tasks keep running there after
  Workers stop deciding where a Task runs. Only when they all agree: a swarm
  with no live Worker, or one that runs inside Salix or on a station, keeps
  none, and its Tasks run inside Salix.

  `derive.(tenant_id, group_id)` decides and writes one swarm's Group (in a
  release, `SalixAgent.Migrations.DefaultTaskPlaces.derive/2`); it keeps a
  default the Group already has, so a pass run again changes nothing.
  Projects are read through the repo the caller gives, 100 at a time.
  """

  @page 100

  @typedoc "`derive.(tenant_id, group_id)`."
  @type derive :: (String.t(), String.t() -> {:ok, :cloud_vm | :none} | {:error, term()})

  @spec run(module(), derive()) :: {:ok, %{cloud_vm: non_neg_integer()}} | {:error, term()}
  def run(repo, derive), do: page(repo, derive, nil, 0)

  defp page(repo, derive, after_id, count) do
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
        case derive.(tenant_id, group_id) do
          {:ok, :cloud_vm} -> {:cont, {:ok, count + 1}}
          {:ok, :none} -> {:cont, {:ok, count}}
          {:error, reason} -> {:halt, {:error, {id, reason}}}
        end
      end)

    case {result, rows} do
      {{:ok, count}, rows} when length(rows) == @page ->
        [id | _] = List.last(rows)
        page(repo, derive, id, count)

      {{:ok, count}, _rows} ->
        {:ok, %{cloud_vm: count}}

      {error, _rows} ->
        error
    end
  end
end
