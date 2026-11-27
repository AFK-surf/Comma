defmodule SalixStore.TenantDirectoryTest do
  # The directory table is shared by every suite in this VM: each test reads
  # only rows whose names carry its own token.
  use SystemsClock.Case, async: false

  alias SalixStore.{Ids, TenantDirectory}

  setup do
    token = "dir#{SystemsRuntime.Proc.unique_integer([:positive])}z"
    %{token: token}
  end

  defp put!(token, name, product, created_at) do
    record = %{
      "tenant_id" => Ids.new_tenant_id(),
      "name" => "#{name} #{token}",
      "product" => product,
      "created_at" => created_at
    }

    {:ok, _} = TenantDirectory.upsert(record)
    TenantDirectory.canonical(record)
  end

  defp walk(opts, cursor \\ nil, acc \\ []) do
    {rows, next} = TenantDirectory.page(Map.put(opts, :cursor, cursor))
    acc = acc ++ rows
    if next, do: walk(opts, next, acc), else: acc
  end

  test "keyset pages run newest first with ties in Tenant id order and no row twice", %{
    token: token
  } do
    rows =
      for index <- 1..7 do
        # Three rows share one second: the Tenant id orders them.
        put!(token, "Acme #{index}", nil, 1_800_000_000 + div(index, 3))
      end

    expected = Enum.sort_by(rows, &{&1["created_at"], &1["tenant_id"]}, :desc)

    {first, cursor} = TenantDirectory.page(%{query: token, limit: 3})
    assert first == Enum.take(expected, 3)
    assert is_binary(cursor)
    assert walk(%{query: token, limit: 3}) == expected

    # The last page has no cursor.
    assert {[_ | _], nil} = TenantDirectory.page(%{query: token, limit: 7})
  end

  test "product filter, name and Tenant id search, and counts per bucket", %{token: token} do
    comma = put!(token, "Comma Space", "comma", 1_800_000_010)
    cft = put!(token, "Team Org", "cft", 1_800_000_020)
    other = put!(token, "Direct", nil, 1_800_000_030)

    assert walk(%{query: token, product: "comma"}) == [comma]
    assert walk(%{query: token, product: "cft"}) == [cft]
    assert walk(%{query: token, product: "other"}) == [other]
    assert walk(%{query: token}) == [other, cft, comma]

    # Case-insensitive substring of the name.
    assert walk(%{query: "team org " <> String.upcase(token)}) == [cft]

    # A Tenant id, or a part of one, finds its Tenant.
    assert walk(%{query: other["tenant_id"]}) == [other]
    id_part = binary_part(comma["tenant_id"], 10, 14)
    assert comma in walk(%{query: id_part})

    # LIKE wildcards in the text match only themselves.
    assert walk(%{query: token <> "%"}) == []

    assert TenantDirectory.counts(token) == %{"all" => 3, "comma" => 1, "cft" => 1, "other" => 1}
    assert TenantDirectory.counts("Comma Space " <> token)["all"] == 1
  end

  test "an upsert follows the record; the backfill import fills only a missing product", %{
    token: token
  } do
    row = put!(token, "Before", nil, 1_800_000_040)
    id = row["tenant_id"]

    {:ok, _} = TenantDirectory.upsert(%{row | "name" => "After #{token}"})
    assert {:ok, %{"name" => "After " <> _}} = TenantDirectory.get(id)

    # A record read before the rename keeps the row's name; it fills the product.
    :ok = TenantDirectory.import_record(%{row | "product" => "cft"})
    assert {:ok, %{"name" => "After " <> _, "product" => "cft"}} = TenantDirectory.get(id)

    # A product already in the row stays.
    :ok = TenantDirectory.import_record(%{row | "product" => "comma"})
    assert {:ok, %{"product" => "cft"}} = TenantDirectory.get(id)

    # A Tenant with no row gets one.
    fresh = %{row | "tenant_id" => Ids.new_tenant_id(), "product" => "comma"}
    :ok = TenantDirectory.import_record(fresh)
    assert {:ok, %{"product" => "comma"}} = TenantDirectory.get(fresh["tenant_id"])
  end
end
