defmodule SalixAnalytics.ClickHouseReadDecodeTest do
  use SystemsClock.Case, async: true

  alias SalixAnalytics.ClickHouseRead

  test "JSONEachRow decodes one map per line" do
    body = ~s({"a":1,"b":"x"}\n{"a":2,"b":null}\n)

    assert {:ok, [%{"a" => 1, "b" => "x"}, %{"a" => 2, "b" => nil}]} =
             ClickHouseRead.decode_rows(body, :json_each_row)

    assert {:error, {:bad_row, "nope"}} = ClickHouseRead.decode_rows("nope\n", :json_each_row)
  end

  test "JSONCompactEachRowWithNames decodes to the same maps as JSONEachRow" do
    body = ~s(["a","b"]\n[1,"x"]\n[2,null]\n)
    assert {:ok, rows} = ClickHouseRead.decode_rows(body, :compact_with_names)
    assert rows == [%{"a" => 1, "b" => "x"}, %{"a" => 2, "b" => nil}]

    assert {:ok, []} = ClickHouseRead.decode_rows("", :compact_with_names)
    assert {:ok, []} = ClickHouseRead.decode_rows(~s(["a","b"]\n), :compact_with_names)
  end

  test "a compact row with the wrong width or a bad header is an error, not a shifted map" do
    assert {:error, {:bad_row, "[1]"}} =
             ClickHouseRead.decode_rows(~s(["a","b"]\n[1]\n), :compact_with_names)

    assert {:error, {:bad_row, ~s({"a":1})}} =
             ClickHouseRead.decode_rows(~s({"a":1}\n[1]\n), :compact_with_names)
  end

  describe "a query that fails after its 200 response started" do
    defp stream(:json_each_row, error),
      do: ~s({"a":1}\n{"a":2}\n) <> Jason.encode!(%{"exception" => error}) <> "\n"

    defp stream(:compact_with_names, error),
      do: ~s(["a","b"]\n[1,2]\n) <> Jason.encode!([error]) <> "\n"

    @formats [:json_each_row, :compact_with_names]

    test "every budget code is the over-budget error, with no rows" do
      for format <- @formats, code <- [158, 159, 160, 241, 307] do
        body = stream(format, "Code: #{code}. DB::Exception: limit. (LIMIT)")

        assert {:error, {:read_over_budget, %{code: ^code, message: "Code: " <> _}}} =
                 ClickHouseRead.decode_rows(body, format)
      end
    end

    test "a stream holding only the exception is the same error" do
      body = ~s({"exception":"Code: 241. DB::Exception: limit."}\n)

      assert {:error, {:read_over_budget, %{code: 241}}} =
               ClickHouseRead.decode_rows(body, :json_each_row)
    end

    test "any other server exception is an http error, with no rows" do
      for format <- @formats do
        body = stream(format, "Code: 395. DB::Exception: boom. (THROW)")
        assert {:error, {:http, "Code: 395." <> _}} = ClickHouseRead.decode_rows(body, format)
      end
    end

    test "the error text is bounded and holds nothing from the rows before it" do
      error = "Code: 395. DB::Exception: " <> String.duplicate("x", 1_000)
      body = ~s({"a":"secret"}\n) <> Jason.encode!(%{"exception" => error}) <> "\n"

      assert {:error, {:http, text}} = ClickHouseRead.decode_rows(body, :json_each_row)
      assert String.starts_with?(text, "Code: 395.")
      assert String.length(text) <= 300
      refute text =~ "secret"
    end
  end

  test "legitimate rows that mention exceptions stay rows" do
    error = "Code: 241. DB::Exception: stored"

    for {body, format, rows} <- [
          # A column named exception with ordinary text.
          {~s({"exception":"boom"}\n), :json_each_row, [%{"exception" => "boom"}]},
          # The error text beside another column.
          {Jason.encode!(%{"exception" => error, "at" => 1}) <> "\n", :json_each_row,
           [%{"exception" => error, "at" => 1}]},
          # The error text before the last row: a failure ends the stream.
          {Jason.encode!(%{"exception" => error}) <> ~s(\n{"exception":"boom"}\n), :json_each_row,
           [%{"exception" => error}, %{"exception" => "boom"}]},
          # A one-column compact row with ordinary text.
          {~s(["exception"]\n["boom"]\n), :compact_with_names, [%{"exception" => "boom"}]},
          # The error text inside a wider compact row.
          {Jason.encode!(["a", "b"]) <> "\n" <> Jason.encode!([error, 1]) <> "\n",
           :compact_with_names, [%{"a" => error, "b" => 1}]}
        ] do
      assert {:ok, rows} == ClickHouseRead.decode_rows(body, format)
    end
  end
end
