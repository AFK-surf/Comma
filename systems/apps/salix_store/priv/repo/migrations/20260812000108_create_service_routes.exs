defmodule SalixStore.Repo.Migrations.CreateServiceRoutes do
  use Ecto.Migration

  def change do
    create table(:service_exports, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:workload_id, references(:compute_workloads, type: :text), null: false)
      add(:workload_generation, :bigint, null: false)
      add(:logical_endpoint, :text, null: false)
      add(:port, :integer, null: false)
      add(:protocol, :text, null: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:revoked_at, :utc_datetime_usec)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create table(:service_imports, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:destination_workload_id, references(:compute_workloads, type: :text), null: false)
      add(:destination_workload_generation, :bigint, null: false)
      add(:virtual_service_name, :text, null: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:revoked_at, :utc_datetime_usec)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create table(:service_routes, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:export_id, references(:service_exports, type: :text), null: false)
      add(:import_id, references(:service_imports, type: :text), null: false)
      add(:capability_id, :text)
      add(:route_class, :text, null: false)
      add(:state, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(
        :service_imports,
        [:destination_workload_id, :virtual_service_name],
        where: "revoked_at IS NULL"
      )
    )

    create(index(:service_routes, [:tenant_id, :state, :expires_at]))

    create table(:service_route_audit, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:route_id, :text, null: false)
      add(:action, :text, null: false)
      add(:outcome, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:generation, :bigint, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:service_route_audit, [:route_id, :created_at]))
  end
end
