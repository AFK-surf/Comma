defmodule SalixStore.Repo.Migrations.IndexGroupArchiveGc do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX compute_workloads_archive_gc_idx ON compute_workloads (id)
    WHERE jsonb_array_length(COALESCE(spec #> '{archive,archive_gc_operations}', '[]'::jsonb)) > 0
    """)
  end

  def down do
    execute("DROP INDEX compute_workloads_archive_gc_idx")
  end
end
