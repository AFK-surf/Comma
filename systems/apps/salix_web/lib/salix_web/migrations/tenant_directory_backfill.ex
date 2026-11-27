defmodule SalixWeb.Migrations.TenantDirectoryBackfill do
  @moduledoc """
  Fills the Tenant directory (`SalixStore.TenantDirectory`) from the S3 Tenant
  records once, and records each Tenant's product where its record has none.

  It runs after the core rollout, from the release's post-rollout job
  (`Comma.Release.transfer_agent_configuration_page/1`), when no Pod of the
  release before is left to make a Tenant without a directory row. Each page
  reads at most 100 Tenant records in storage-key order
  (`Salix.Control.Tenants.page/2`), asks the caller's `products` function which
  product made each of them (one bounded query per product store for the
  page's ids), writes the product into records that have none, and inserts
  their rows. A row a live write already made keeps its name.

  The marker `tenant_directory_v1` in `salix_cutover_markers` records the
  storage cursor of the next page (`SalixStore.CutoverMarkers.page/2`): a run
  cut off resumes there, and once the last page is done, running it again does
  nothing. A page that cannot read or write a record fails as a whole and
  leaves the marker, so the release runs the same page again; every write is
  idempotent.
  """

  alias Salix.Control.Tenants
  alias SalixStore.CutoverMarkers

  @marker "tenant_directory_v1"
  @page 100
  @write_concurrency 8

  @doc """
  One page after the rollout. `products` takes a list of at most 100 Tenant ids
  and answers `{:ok, %{tenant_id => "comma" | "cft" | nil}}` or an error.
  Answers `{:ok, %{processed: n, done: boolean}}`.
  """
  def after_rollout_page(products) when is_function(products, 1),
    do: CutoverMarkers.page(@marker, &page(&1, products))

  @doc """
  One page at the storage `cursor` (nil: the first): `{:ok, %{processed: n,
  next: cursor}}`, where a nil cursor means the backfill is done. `page:` takes
  fewer records.
  """
  def page(cursor, products, opts \\ []) do
    limit = Keyword.get(opts, :page, @page)

    with {:ok, %{tenants: tenants, next: next}} <- Tenants.page(cursor, limit),
         {:ok, resolved} <- products.(Enum.map(tenants, & &1["tenant_id"])),
         :ok <- write(tenants, resolved) do
      {:ok, %{processed: length(tenants), next: next}}
    end
  end

  defp write(tenants, resolved) do
    tenants
    |> SystemsClock.async_stream(
      &Tenants.backfill_directory(&1, Map.get(resolved, &1["tenant_id"])),
      max_concurrency: @write_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, :ok -> {:cont, :ok}
      {:ok, {:error, reason}}, :ok -> {:halt, {:error, {:tenant_directory, reason}}}
      {:exit, reason}, :ok -> {:halt, {:error, {:tenant_directory, reason}}}
    end)
  end
end
