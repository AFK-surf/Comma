# Clean the shared MinIO test bucket before the suite. `System.unique_integer`
# resets per VM run, so agent ids repeat across runs; without this, stale objects
# from a previous run pollute prefix LISTs and break isolation.
if SalixStore.Config.backend() == SalixStore.S3.AWS do
  case SalixStore.S3.list_all("") do
    {:ok, objects} ->
      for %{key: key} <- objects, do: SalixStore.S3.delete(key)

      IO.puts(
        "[test_helper] cleaned #{length(objects)} stale objects from #{SalixStore.Config.get().bucket}"
      )

    {:error, reason} ->
      IO.puts("[test_helper] WARNING: could not clean test bucket: #{inspect(reason)}")
  end
end

ExUnit.start()

# Control-plane Postgres: create/migrate/clean the test database and reset the
# cutover-gate cache (docs/storage-search.md).
SalixStore.RepoTestSetup.ensure!()
