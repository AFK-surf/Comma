defmodule SalixStore.MeetingCalendarSettings do
  @moduledoc "Durable calendar enrollment settings owned by one Group."
  import Ecto.Query
  alias SalixStore.Repo

  defmodule Row do
    use Ecto.Schema
    @primary_key {:group_id, :string, autogenerate: false}
    schema "meeting_calendar_settings" do
      field(:tenant_id, :string)
      field(:connect_id, :string)
      field(:enabled, :boolean)
      field(:configuration, :map)
      field(:revision, :integer, default: 1)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  def get(group_id) do
    case Repo.get(Row, group_id) do
      nil -> {:error, :not_found}
      row -> {:ok, record(row)}
    end
  end

  # Only enabled enrollments and explicit overrides of the bounded deployment
  # defaults are loaded. Disabled historical settings do not grow a worker pass.
  def list(default_group_ids, limit) when limit in 1..100 do
    rows =
      Repo.all(
        from(r in Row,
          where: r.enabled == true or r.group_id in ^default_group_ids,
          order_by: r.group_id,
          limit: ^(limit + length(default_group_ids) + 1)
        )
      )

    if Enum.count(rows, & &1.enabled) <= limit,
      do: {:ok, Enum.map(rows, &record/1)},
      else: {:error, :meeting_calendar_capacity_exceeded}
  end

  # Serialize admission against the existing worker's total work budget.
  # The caller validates the combined saved settings and deployment defaults
  # inside this transaction. No provider requests belong in this callback.
  def put(group_id, tenant_id, configuration, validate) do
    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(726191, 1)", [])

      row = %Row{
        group_id: group_id,
        tenant_id: tenant_id,
        connect_id: configuration["connect_id"],
        enabled: configuration["enabled"],
        configuration: configuration,
        updated_at: DateTime.utc_now()
      }

      case Repo.insert(
             Ecto.Changeset.change(row)
             |> Ecto.Changeset.unique_constraint(:connect_id),
             on_conflict: [
               set: [
                 connect_id: row.connect_id,
                 enabled: row.enabled,
                 configuration: row.configuration,
                 updated_at: row.updated_at
               ],
               inc: [revision: 1]
             ],
             conflict_target: :group_id,
             returning: true
           ) do
        {:ok, saved} ->
          case validate.() do
            :ok -> record(saved)
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, _} ->
          Repo.rollback(:meeting_calendar_conflict)
      end
    end)
  end

  defp record(row),
    do:
      Map.merge(row.configuration, %{
        "group_id" => row.group_id,
        "tenant_id" => row.tenant_id,
        "settings_revision" => row.revision,
        "updated_at" => DateTime.to_unix(row.updated_at, :millisecond)
      })
end
