defmodule Comma.Stations.Revocations do
  @moduledoc """
  Member credentials Comma takes back before they expire (contract §3–§4).
  Salix keeps the revocations per Group (`SalixStore.Stations.Revocations`);
  this module names the Groups a Comma account's revocation reaches: the
  Groups of the Workspaces it is a member of.

  Comma and Salix have separate databases, so an Auth Session revocation
  writes its `sid` rows to Salix inside the session update's transaction,
  before that transaction commits: a failed Salix write rolls the session
  update back, and a committed session revocation always has its station
  revocation rows. A session update that then fails to commit leaves rows
  that only refuse credentials issued until then. Stations are told after
  commit.

  The schema is Comma's own table from before Salix kept revocations. It is
  only read, by the copy to Salix (`Comma.Stations.SalixCopy`).
  """

  use Ecto.Schema
  import Ecto.Query

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.Repo
  alias SalixStore.Stations.Events
  alias SalixStore.Stations.Revocations, as: Store

  @primary_key false
  schema "comma_station_revocations" do
    field(:workspace_id, :string, primary_key: true)
    field(:kind, :string, primary_key: true)
    field(:subject_id, :string, primary_key: true)
    field(:at, :integer)
  end

  @workspaces_per_user 100

  @doc """
  Auth Sessions revoked (rows of `{session_id, user_id}`): one `sid` row per
  member Group. Writes only; returns the revocations for `publish/1`, which
  the caller runs once its transaction has committed. `repo` reads the
  account's Workspaces.
  """
  def sessions_revoked(repo \\ Repo, rows)

  def sessions_revoked(_repo, []), do: []

  def sessions_revoked(repo, rows) do
    rows
    |> Enum.group_by(fn {_sid, user_id} -> user_id end, fn {sid, _} -> to_string(sid) end)
    |> Enum.flat_map(fn {user_id, sids} ->
      groups = member_groups(repo, user_id)
      Enum.flat_map(sids, &Store.revoke(groups, "sid", &1))
    end)
  end

  @doc "Every credential of an account, in every Group it belongs to (account disabled)."
  def user_revoked(repo \\ Repo, user_id) when is_binary(user_id),
    do: Store.revoke(member_groups(repo, user_id), "sub", user_id)

  @doc """
  Tells connected stations committed revocations (`revoke` frames); those
  connected to a server of the release before too, while one runs
  (`Comma.Stations.Window`).
  """
  def publish(revocations) do
    Events.publish(revocations)
    Comma.Stations.Window.tell_revoked(revocations)
  end

  @doc """
  Publishes an account's revocations written since `since` (unix seconds), for
  callers whose own transaction wrapped the writes and has now committed.
  """
  def publish_since(user_id, since) when is_binary(user_id) and is_integer(since) do
    groups = member_groups(Repo, user_id)
    after_dt = DateTime.from_unix!(since)

    sids =
      Repo.all(
        from(s in Comma.Accounts.AuthSession,
          where: s.user_id == ^user_id and s.revoked_at >= ^after_dt,
          select: type(s.id, :string)
        )
      )

    publish(
      Store.written_since(groups, "sub", [user_id], since) ++
        Store.written_since(groups, "sid", sids, since)
    )
  end

  defp member_groups(repo, user_id) do
    repo.all(
      from(m in WorkspaceMembership,
        join: w in Workspace,
        on: w.id == m.workspace_id,
        where: m.user_id == ^user_id,
        order_by: [asc: m.workspace_id],
        limit: @workspaces_per_user,
        select: {w.salix_tenant_id, w.salix_group_id}
      )
    )
  end
end
