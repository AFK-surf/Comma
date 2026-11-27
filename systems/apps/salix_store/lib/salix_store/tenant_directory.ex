defmodule SalixStore.TenantDirectory do
  @moduledoc """
  Search projection of the S3 Tenant records (docs/architecture/DOMAIN_CONCEPTS.md,
  Tenant), for the dashboard's Tenant list.

  One row per Tenant: `tenant_id`, `name`, `product` (`"comma"`, `"cft"` or
  nil for a Tenant made in Salix itself) and `created_at`. The S3 record stays
  the authority; `Salix.Control.Tenants` writes the row after each record
  write, and the release backfill fills it for Tenants made before.

  Every read is bounded: a keyset page newest first (`created_at`, then
  `tenant_id`, both descending) of at most 100 rows, optionally filtered by
  product bucket and by a case-insensitive substring of the name or the Tenant
  id (trigram indexes), and one grouped count for the same search.
  Records in and out are string-keyed maps with `created_at` in epoch seconds.
  """

  import Ecto.Query

  alias SalixStore.Repo

  @products ~w(comma cft)
  @buckets ~w(comma cft other)
  @max_limit 100
  @max_query_bytes 200

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:tenant_id, :string, autogenerate: false}
    schema "tenant_directory" do
      field(:name, :string)
      field(:product, :string)
      field(:created_at, :utc_datetime_usec)
    end
  end

  @doc "The product values a Tenant can carry."
  def products, do: @products

  @doc "The product filter buckets; `other` is a Tenant without a product."
  def buckets, do: @buckets

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(tenant_id) when is_binary(tenant_id) do
    case Repo.get(Row, tenant_id) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  end

  @doc "Write the row of a Tenant record, replacing what the row held."
  @spec upsert(map()) :: {:ok, map()}
  def upsert(%{"tenant_id" => tenant_id} = record) when is_binary(tenant_id) do
    row = from_record(record)

    Repo.insert!(row,
      on_conflict: {:replace, [:name, :product, :created_at]},
      conflict_target: :tenant_id
    )

    {:ok, to_record(row)}
  end

  @doc """
  The backfill's write: insert the row of a record read earlier; when a row
  is already there, a live write made it from a newer record, so only a
  missing product is filled.
  """
  @spec import_record(map()) :: :ok
  def import_record(%{"tenant_id" => tenant_id} = record) when is_binary(tenant_id) do
    row = from_record(record)

    Repo.insert!(row,
      on_conflict:
        from(r in Row,
          update: [set: [product: fragment("COALESCE(?, EXCLUDED.product)", r.product)]]
        ),
      conflict_target: :tenant_id
    )

    :ok
  end

  @doc """
  One keyset page, newest first. `product`: nil (every Tenant), `"comma"`,
  `"cft"` or `"other"` (no product). `query`: nil or a substring of the name
  or the Tenant id, any case. `cursor`: nil or the opaque cursor of the page
  before. `limit`: 1..#{@max_limit}. Answers `{rows, next_cursor}`, with a nil
  cursor on the last page.
  """
  @spec page(map()) :: {[map()], String.t() | nil}
  def page(opts) when is_map(opts) do
    limit = Map.get(opts, :limit) || 25

    unless is_integer(limit) and limit in 1..@max_limit,
      do: raise(ArgumentError, "invalid tenant directory limit")

    rows =
      Row
      |> filter_product(Map.get(opts, :product))
      |> filter_query(Map.get(opts, :query))
      |> after_cursor(decode_cursor(Map.get(opts, :cursor)))
      |> order_by([r], desc: r.created_at, desc: r.tenant_id)
      |> limit(^(limit + 1))
      |> Repo.all()

    {page, rest} = Enum.split(rows, limit)
    next = if rest != [], do: encode_cursor(List.last(page))
    {Enum.map(page, &to_record/1), next}
  end

  @doc "Counts per bucket (`all`, `comma`, `cft`, `other`) for a search."
  @spec counts(String.t() | nil) :: %{String.t() => non_neg_integer()}
  def counts(query) do
    grouped =
      Row
      |> filter_query(query)
      |> group_by([r], r.product)
      |> select([r], {r.product, count()})
      |> Repo.all()
      |> Map.new(fn {product, count} -> {product || "other", count} end)

    @buckets
    |> Map.new(&{&1, Map.get(grouped, &1, 0)})
    |> Map.put("all", grouped |> Map.values() |> Enum.sum())
  end

  @doc "The row a Tenant record projects to, as `to_record/1` reads it back."
  @spec canonical(map()) :: map()
  def canonical(record), do: record |> from_record() |> to_record()

  defp filter_product(query, product) when product in @products,
    do: where(query, [r], r.product == ^product)

  defp filter_product(query, "other"), do: where(query, [r], is_nil(r.product))
  defp filter_product(query, nil), do: query
  defp filter_product(_query, _product), do: raise(ArgumentError, "invalid product filter")

  defp filter_query(query, text) do
    case normalize_query(text) do
      nil ->
        query

      text ->
        pattern = "%" <> escape_like(text) <> "%"
        where(query, [r], ilike(r.name, ^pattern) or ilike(r.tenant_id, ^pattern))
    end
  end

  @doc false
  def normalize_query(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> binary_part_utf8(text, @max_query_bytes)
    end
  end

  def normalize_query(_text), do: nil

  defp binary_part_utf8(text, max) when byte_size(text) <= max, do: text

  defp binary_part_utf8(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, size} ->
      if size + byte_size(g) > max,
        do: {:halt, {acc, size}},
        else: {:cont, {acc <> g, size + byte_size(g)}}
    end)
    |> elem(0)
  end

  defp escape_like(text), do: String.replace(text, ["\\", "%", "_"], &("\\" <> &1))

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {created_at, tenant_id}) do
    where(
      query,
      [r],
      fragment(
        "(?, ?) < (?, ?)",
        r.created_at,
        r.tenant_id,
        type(^created_at, :utc_datetime_usec),
        type(^tenant_id, :string)
      )
    )
  end

  defp encode_cursor(%Row{created_at: created_at, tenant_id: tenant_id}) do
    [DateTime.to_unix(created_at, :microsecond), tenant_id]
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil), do: nil

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [usec, tenant_id]} when is_integer(usec) and is_binary(tenant_id) <-
           Jason.decode(json),
         {:ok, created_at} <- DateTime.from_unix(usec, :microsecond) do
      {created_at, tenant_id}
    else
      _ -> raise ArgumentError, "invalid tenant directory cursor"
    end
  end

  defp decode_cursor(_cursor), do: raise(ArgumentError, "invalid tenant directory cursor")

  defp to_record(%Row{} = row) do
    %{
      "tenant_id" => row.tenant_id,
      "name" => row.name,
      "product" => row.product,
      "created_at" => DateTime.to_unix(row.created_at, :second)
    }
  end

  defp from_record(record) do
    %Row{
      tenant_id: record["tenant_id"],
      name: if(is_binary(record["name"]), do: record["name"], else: "Tenant"),
      product: if(record["product"] in @products, do: record["product"]),
      created_at: created_at(record["created_at"])
    }
  end

  defp created_at(seconds) when is_integer(seconds) and seconds >= 0,
    do: DateTime.from_unix!(seconds * 1_000_000, :microsecond)

  defp created_at(_seconds), do: DateTime.from_unix!(0, :microsecond)
end
