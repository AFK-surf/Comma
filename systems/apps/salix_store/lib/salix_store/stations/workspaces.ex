defmodule SalixStore.Stations.Workspaces do
  @moduledoc """
  The workspace id a Group's stations are told: the `workspace` of the enroll
  answer and the presence `state` frame, and the `ws` of a member credential.
  Salix decides it per Group and keeps it here; no caller computes it.

  A Group with no row is told its Group id. A row says another id
  (`workspace_id`) and the ids the Group was told before (`previous_ids`,
  oldest first). The Groups whose stations were enrolled with a Comma
  Workspace id have a row with that id, written once when Comma's roster was
  copied (`Comma.Stations.SalixCopy`), so those stations and the member
  credentials their clients hold see no change.

  `rename/3` changes the id a Group is told and adds the one before to
  `previous_ids`, which is only ever added to. A station is told both (`workspace` and `workspace_was`): a
  new `workspace` whose `workspace_was` names the id the station holds is the
  same workspace under a new id, and anything else is another workspace. A
  station keys what it keeps (remote jobs, their directories) by the first id
  of the list, so that id never leaves it, and a station that was away for
  the change still learns that it was a rename.
  """

  use Ecto.Schema
  import Ecto.Query

  alias SalixStore.Repo

  @primary_key false
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  schema "salix_station_workspaces" do
    field(:tenant_id, :string)
    field(:group_id, :string, primary_key: true)
    field(:workspace_id, :string)
    field(:previous_ids, {:array, :string}, default: [])

    timestamps()
  end

  @type told :: %{id: String.t(), was: [String.t()]}

  @doc "The id the Group's stations are told now, and the ids they were told before."
  @spec told(String.t(), String.t()) :: told()
  def told(tenant_id, group_id) when is_binary(tenant_id) and is_binary(group_id) do
    case Repo.one(
           from(w in __MODULE__,
             where: w.tenant_id == ^tenant_id and w.group_id == ^group_id,
             select: {w.workspace_id, w.previous_ids}
           )
         ) do
      {id, was} -> %{id: id, was: was}
      nil -> %{id: group_id, was: []}
    end
  end

  @doc """
  Tells the Group's stations `workspace_id` from now on, and the id told
  until now as a previous one. Answers what is told; the same id again
  changes nothing. The caller tells the connected stations
  (`SalixStore.Stations.Events.roster_changed/1`).
  """
  @spec rename(String.t(), String.t(), String.t()) :: {:ok, told()} | {:error, term()}
  def rename(tenant_id, group_id, workspace_id)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(workspace_id) and
             workspace_id != "" do
    Repo.transaction(fn ->
      row =
        Repo.one(
          from(w in __MODULE__,
            where: w.tenant_id == ^tenant_id and w.group_id == ^group_id,
            lock: "FOR UPDATE"
          )
        )

      before = if row, do: %{id: row.workspace_id, was: row.previous_ids}, else: nil
      before = before || %{id: group_id, was: []}

      cond do
        before.id == workspace_id ->
          before

        taken?(group_id, workspace_id) ->
          Repo.rollback(:workspace_id_taken)

        true ->
          # Only ever added to: its first entry is the first id the Group
          # had, which stations key what they keep by.
          was = before.was ++ [before.id]

          Repo.insert!(
            %__MODULE__{
              tenant_id: tenant_id,
              group_id: group_id,
              workspace_id: workspace_id,
              previous_ids: was
            },
            on_conflict: {:replace, [:workspace_id, :previous_ids, :updated_at]},
            conflict_target: [:group_id]
          )

          %{id: workspace_id, was: was}
      end
    end)
  end

  # Another Group is told the id.
  defp taken?(group_id, workspace_id) do
    Repo.exists?(
      from(w in __MODULE__, where: w.workspace_id == ^workspace_id and w.group_id != ^group_id)
    )
  end
end
