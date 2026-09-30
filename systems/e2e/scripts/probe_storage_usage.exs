billing_account_id = System.fetch_env!("COMMA_E2E_BILLING_ACCOUNT_ID")
workspace_id = System.fetch_env!("COMMA_E2E_WORKSPACE_ID")
run_id = System.fetch_env!("COMMA_E2E_RUN_ID")

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:finch)

unless Process.whereis(SalixStore.Finch) do
  {:ok, _} = Finch.start_link(name: SalixStore.Finch, pools: %{default: [size: 50, count: 1]})
end

unless Process.whereis(BillingCore.Repo) do
  {:ok, _} = BillingCore.Repo.start_link()
end

key = "comma/e2e/#{run_id}/storage-probe.txt"
body = String.duplicate("comma billing storage probe #{run_id}\n", 128)

{:ok, _put} = SalixStore.S3.put(key, body)
{:ok, %{body: ^body}} = SalixStore.S3.get(key)

{:ok, fact} =
  SalixStore.StorageSnapshot.sample_prefix(%{
    prefix: "comma/e2e/#{run_id}/",
    source_key: "storage:e2e:#{run_id}",
    billing_account_id: billing_account_id,
    surface: "comma",
    product_owner_type: "workspace",
    product_owner_id: workspace_id,
    tenant_id: "comma-tenant-#{workspace_id}",
    group_id: "comma-group-#{workspace_id}",
    provider: "s3",
    storage_tier: "standard",
    sample_window_seconds: 50_000_000_000,
    bucket: Application.get_env(:salix_store, :s3_bucket),
    actor_type: "system"
  })

IO.puts(
  Jason.encode!(%{
    ok: true,
    key: key,
    bytes: fact.bytes,
    byte_seconds: fact.byte_seconds,
    object_count: fact.object_count
  })
)
