defmodule SalixStore.Stations.Revocations do
  @moduledoc """
  Member credentials taken back before they expire. A credential lasts 30
  days and stations check it offline, so a revocation is
  a per-Group row `{kind, id, at}` told to that Group's stations: every
  credential of the account (`sub`) or Auth Session (`sid`) issued at or
  before `at` is refused. Rows are told for 31 days and then pruned.

  Which Groups an account's revocation reaches is the product's decision;
  the caller names them. Telling connected stations belongs to the caller
  (`SalixStore.Stations.Events.publish/1`), from the revocations `revoke/4`
  returns, once its own transaction committed.
  """

  use Ecto.Schema
  import Ecto.Query

  alias SalixStore.Repo

  @primary_key false
  schema "salix_station_revocations" do
    field(:tenant_id, :string)
    field(:group_id, :string, primary_key: true)
    field(:kind, :string, primary_key: true)
    field(:subject_id, :string, primary_key: true)
    field(:at, :integer)
  end

  @window_seconds 31 * 24 * 60 * 60
  @told_limit 2_000

  @doc "Revocations a Group's stations are told: the last 31 days, newest bounded."
  def list(tenant_id, group_id) do
    cutoff = SystemsClock.system_time(:second) - @window_seconds

    from(r in __MODULE__,
      where: r.tenant_id == ^tenant_id and r.group_id == ^group_id and r.at >= ^cutoff,
      order_by: [desc: r.at, asc: r.kind, asc: r.subject_id],
      limit: @told_limit,
      select: %{"kind" => r.kind, "id" => r.subject_id, "at" => r.at}
    )
    |> Repo.all()
  end

  @doc """
  Revokes every credential of `kind` (`"sub"` or `"sid"`) and `id` issued
  until now in each `{tenant_id, group_id}`, and prunes rows past the window
  in those Groups. Answers `[{{tenant_id, group_id}, revocation}]`.
  """
  def revoke(repo \\ Repo, groups, kind, id)

  def revoke(_repo, [], _kind, _id), do: []

  def revoke(repo, groups, kind, id) when kind in ~w(sub sid) and is_binary(id) do
    at = SystemsClock.system_time(:second)
    groups = Enum.uniq(groups)

    rows =
      Enum.map(groups, fn {tenant, group} ->
        %{tenant_id: tenant, group_id: group, kind: kind, subject_id: id, at: at}
      end)

    repo.insert_all(__MODULE__, rows,
      on_conflict: {:replace, [:at]},
      conflict_target: [:group_id, :kind, :subject_id]
    )

    group_ids = Enum.map(groups, &elem(&1, 1))
    cutoff = at - @window_seconds

    repo.delete_all(from(r in __MODULE__, where: r.group_id in ^group_ids and r.at < ^cutoff))

    Enum.map(groups, &{&1, %{"kind" => kind, "id" => id, "at" => at}})
  end

  @doc """
  The revocations of `kind` and `ids` written in the Groups at or after
  `since` (unix seconds), as `revoke/4` answers them: for a caller that tells
  stations only once its own transaction has committed.
  """
  def written_since(groups, kind, ids, since)
      when is_list(groups) and is_list(ids) and is_integer(since) do
    group_ids = groups |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    from(r in __MODULE__,
      where:
        r.group_id in ^group_ids and r.kind == ^kind and r.subject_id in ^ids and r.at >= ^since
    )
    |> Repo.all()
    |> Enum.map(
      &{{&1.tenant_id, &1.group_id}, %{"kind" => &1.kind, "id" => &1.subject_id, "at" => &1.at}}
    )
  end
end
