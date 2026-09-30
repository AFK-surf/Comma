defmodule BridgeForTeams.Artifacts.BlocksTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.Artifacts.Blocks

  doctest BridgeForTeams.Artifacts.Blocks

  describe "types/0" do
    test "is the closed v1 vocabulary" do
      assert Blocks.types() == ~w(kpis table list links timeline entities)
    end
  end

  describe "normalize/1 — input shape" do
    test "non-map input is invalid" do
      for input <- [nil, "kpis", 42, [%{"type" => "kpis"}], true] do
        assert Blocks.normalize(input) == :invalid
      end
    end

    test "missing or non-string type degrades to a plain list when items are usable strings" do
      for input <- [
            %{"items" => ["x"]},
            %{"type" => 1, "items" => ["x"]},
            %{"type" => nil, "items" => ["x"]}
          ] do
        assert Blocks.normalize(input) ==
                 {:ok, %{"type" => "list", "style" => "plain", "items" => ["x"]}}
      end
    end

    test "missing or non-string type with unusable items is invalid" do
      assert Blocks.normalize(%{"items" => [%{"x" => 1}]}) == :invalid
      assert Blocks.normalize(%{"type" => 1, "items" => [%{"x" => 1}]}) == :invalid
      assert Blocks.normalize(%{"type" => nil}) == :invalid
    end

    test "unknown type degrades to a plain list when items are usable strings" do
      assert Blocks.normalize(%{"type" => "chart", "items" => ["x", 2]}) ==
               {:ok, %{"type" => "list", "style" => "plain", "items" => ["x", "2"]}}
    end

    test "unknown type with unusable items is invalid" do
      assert Blocks.normalize(%{"type" => "chart", "items" => [%{"x" => 1}]}) == :invalid
      assert Blocks.normalize(%{"type" => "chart", "series" => [[1, 2]]}) == :invalid
    end

    test "type is trimmed and downcased" do
      assert {:ok, %{"type" => "list"}} =
               Blocks.normalize(%{"type" => "  LIST ", "items" => ["x"]})
    end

    test "missing or empty items are invalid" do
      for type <- ~w(kpis list links timeline entities) do
        assert Blocks.normalize(%{"type" => type}) == :invalid
        assert Blocks.normalize(%{"type" => type, "items" => []}) == :invalid
        assert Blocks.normalize(%{"type" => type, "items" => nil}) == :invalid
      end
    end
  end

  describe "normalize/1 — key synonyms and captions" do
    # The observed near-misses (Portfolio Update Template artifact): "kind"
    # for "type" (primed by the frontmatter schema), "headers" for a table's
    # "columns", "label" for a links item's "title" (primed by the kpis
    # example) — all rendered as "Unrecognized content" before.
    test ~s("kind" is accepted for "type") do
      assert {:ok, %{"type" => "list", "items" => ["x"]}} =
               Blocks.normalize(%{"kind" => "list", "items" => ["x"]})
    end

    test ~s(the canonical "type" wins over "kind" when both exist) do
      assert {:ok, %{"type" => "list"}} =
               Blocks.normalize(%{"type" => "list", "kind" => "kpis", "items" => ["x"]})
    end

    test ~s("headers" is accepted for a table's "columns") do
      assert {:ok, %{"type" => "table", "columns" => ["Metric", "Value"], "rows" => [["a", "b"]]}} =
               Blocks.normalize(%{
                 "kind" => "table",
                 "headers" => ["Metric", "Value"],
                 "rows" => [["a", "b"]]
               })
    end

    test "label/title/name are interchangeable on kpis, links and entities items" do
      assert {:ok, %{"items" => [%{"label" => "ARR", "value" => "1"}]}} =
               Blocks.normalize(%{
                 "type" => "kpis",
                 "items" => [%{"title" => "ARR", "value" => 1}]
               })

      assert {:ok, %{"items" => [%{"title" => "Linear", "url" => "https://linear.app/x"}]}} =
               Blocks.normalize(%{
                 "type" => "links",
                 "items" => [%{"label" => "Linear", "url" => "https://linear.app/x"}]
               })

      assert {:ok, %{"items" => [%{"name" => "Ray"}]}} =
               Blocks.normalize(%{"type" => "entities", "items" => [%{"label" => "Ray"}]})
    end

    test "a block-level title is kept as a caption, coerced and sliced" do
      assert {:ok, %{"type" => "list", "title" => "Highlights"}} =
               Blocks.normalize(%{"type" => "list", "title" => "Highlights", "items" => ["x"]})

      assert {:ok, %{"title" => title}} =
               Blocks.normalize(%{
                 "type" => "list",
                 "title" => String.duplicate("t", 200),
                 "items" => ["x"]
               })

      assert String.length(title) == 120
    end

    test "an unusable or missing block title is simply absent" do
      assert {:ok, block} = Blocks.normalize(%{"type" => "list", "items" => ["x"]})
      refute Map.has_key?(block, "title")

      assert {:ok, block} =
               Blocks.normalize(%{"type" => "list", "title" => %{}, "items" => ["x"]})

      refute Map.has_key?(block, "title")
    end

    test "the caption survives the plain-list fallback" do
      assert {:ok, %{"type" => "list", "title" => "Risks", "items" => ["a"]}} =
               Blocks.normalize(%{"type" => "checklist", "title" => "Risks", "items" => ["a"]})
    end
  end

  describe "normalize/1 — kpis" do
    test "keeps label/value and the optional delta/note" do
      assert Blocks.normalize(%{
               "type" => "kpis",
               "items" => [
                 %{"label" => "ARR", "value" => "$1.2M", "delta" => "+4%", "note" => "QoQ"},
                 %{"label" => "NPS", "value" => "62"}
               ]
             }) ==
               {:ok,
                %{
                  "type" => "kpis",
                  "items" => [
                    %{"label" => "ARR", "value" => "$1.2M", "delta" => "+4%", "note" => "QoQ"},
                    %{"label" => "NPS", "value" => "62"}
                  ]
                }}
    end

    test "coerces numbers and booleans to strings" do
      assert {:ok, %{"items" => [item]}} =
               Blocks.normalize(%{
                 "type" => "kpis",
                 "items" => [%{"label" => 7, "value" => 3.5, "delta" => true}]
               })

      assert item == %{"label" => "7", "value" => "3.5", "delta" => "true"}
    end

    test "drops unknown keys" do
      assert {:ok, %{"items" => [item]}} =
               Blocks.normalize(%{
                 "type" => "kpis",
                 "extra" => "dropped",
                 "items" => [%{"label" => "A", "value" => "1", "sparkline" => [1, 2]}]
               })

      assert item == %{"label" => "A", "value" => "1"}
    end

    test "items missing label or value are dropped; all dropped is invalid" do
      assert {:ok, %{"items" => [%{"label" => "B", "value" => "2"}]}} =
               Blocks.normalize(%{
                 "type" => "kpis",
                 "items" => [
                   %{"value" => "1"},
                   %{"label" => "A"},
                   %{"label" => %{}, "value" => "1"},
                   %{"label" => "  ", "value" => "1"},
                   "not a map",
                   %{"label" => "B", "value" => "2"}
                 ]
               })

      assert Blocks.normalize(%{"type" => "kpis", "items" => [%{"label" => "A"}]}) == :invalid
    end

    test "a single item wraps into a list" do
      assert {:ok, %{"items" => [%{"label" => "A", "value" => "1"}]}} =
               Blocks.normalize(%{"type" => "kpis", "items" => %{"label" => "A", "value" => 1}})
    end

    test "caps at 24 items and slices field lengths" do
      items = for n <- 1..30, do: %{"label" => "kpi #{n}", "value" => "#{n}"}
      assert {:ok, %{"items" => kept}} = Blocks.normalize(%{"type" => "kpis", "items" => items})
      assert length(kept) == 24
      assert List.last(kept)["label"] == "kpi 24"

      long = String.duplicate("x", 600)

      assert {:ok, %{"items" => [item]}} =
               Blocks.normalize(%{
                 "type" => "kpis",
                 "items" => [%{"label" => long, "value" => long, "delta" => long, "note" => long}]
               })

      assert String.length(item["label"]) == 120
      assert String.length(item["value"]) == 40
      assert String.length(item["delta"]) == 500
      assert String.length(item["note"]) == 500
    end
  end

  describe "normalize/1 — table" do
    test "keeps columns and pads/truncates rows to the column count" do
      assert Blocks.normalize(%{
               "type" => "table",
               "columns" => ["Name", "Stage", "Owner"],
               "rows" => [
                 ["Acme", "Series A"],
                 ["Globex", "Seed", "Kim", "extra cell"]
               ]
             }) ==
               {:ok,
                %{
                  "type" => "table",
                  "columns" => ["Name", "Stage", "Owner"],
                  "rows" => [["Acme", "Series A", ""], ["Globex", "Seed", "Kim"]]
                }}
    end

    test "coerces cells; unusable cells become empty strings" do
      assert {:ok, %{"rows" => [["1", "true", ""]]}} =
               Blocks.normalize(%{
                 "type" => "table",
                 "columns" => ["a", "b", "c"],
                 "rows" => [[1, true, %{"nested" => "map"}]]
               })
    end

    test "a scalar row becomes a one-cell padded row; unusable rows are dropped" do
      assert {:ok, %{"rows" => [["only", ""]]}} =
               Blocks.normalize(%{
                 "type" => "table",
                 "columns" => ["a", "b"],
                 "rows" => ["only", %{"not" => "a row"}, nil]
               })
    end

    test "missing or empty columns or rows are invalid" do
      assert Blocks.normalize(%{"type" => "table", "rows" => [["x"]]}) == :invalid

      assert Blocks.normalize(%{"type" => "table", "columns" => [], "rows" => [["x"]]}) ==
               :invalid

      assert Blocks.normalize(%{"type" => "table", "columns" => ["a"]}) == :invalid
      assert Blocks.normalize(%{"type" => "table", "columns" => ["a"], "rows" => []}) == :invalid

      # Columns that all fail coercion leave nothing to align to.
      assert Blocks.normalize(%{"type" => "table", "columns" => [%{}], "rows" => [["x"]]}) ==
               :invalid
    end

    test "unusable columns with a scalar row are invalid, never a raise" do
      # Regression: a bare-scalar row used to be shaped BEFORE the empty-column
      # check, padding against width - 1 == -1 and raising FunctionClauseError
      # in List.duplicate/2 — a never-raises contract violation on
      # agent-written heroes / bft:block fences.
      assert Blocks.normalize(%{"type" => "table", "rows" => ["a"]}) == :invalid
      assert Blocks.normalize(%{"type" => "table", "columns" => [%{}], "rows" => "x"}) == :invalid
      assert Blocks.normalize(%{"type" => "table", "columns" => [], "rows" => "x"}) == :invalid

      assert Blocks.normalize(%{"type" => "table", "columns" => [nil, ""], "rows" => ["a", "b"]}) ==
               :invalid
    end

    test "caps columns and rows at 24" do
      columns = for n <- 1..30, do: "col #{n}"
      rows = for n <- 1..30, do: ["row #{n}"]

      assert {:ok, block} =
               Blocks.normalize(%{"type" => "table", "columns" => columns, "rows" => rows})

      assert length(block["columns"]) == 24
      assert length(block["rows"]) == 24
      assert Enum.all?(block["rows"], &(length(&1) == 24))
    end
  end

  describe "normalize/1 — list" do
    test "keeps string items and defaults style to plain" do
      assert Blocks.normalize(%{"type" => "list", "items" => ["one", "two"]}) ==
               {:ok, %{"type" => "list", "style" => "plain", "items" => ["one", "two"]}}
    end

    test "known styles pass through; unknown styles become plain" do
      for style <- ~w(plain risks actions watch) do
        assert {:ok, %{"style" => ^style}} =
                 Blocks.normalize(%{"type" => "list", "style" => style, "items" => ["x"]})
      end

      assert {:ok, %{"style" => "risks"}} =
               Blocks.normalize(%{"type" => "list", "style" => " RISKS ", "items" => ["x"]})

      for style <- ["bullets", 42, nil, %{}] do
        assert {:ok, %{"style" => "plain"}} =
                 Blocks.normalize(%{"type" => "list", "style" => style, "items" => ["x"]})
      end
    end

    test "coerces items, drops unusable ones, wraps a bare scalar" do
      assert {:ok, %{"items" => ["1", "true", "kept"]}} =
               Blocks.normalize(%{"type" => "list", "items" => [1, true, %{}, "kept", "  "]})

      assert {:ok, %{"items" => ["solo"]}} =
               Blocks.normalize(%{"type" => "list", "items" => "solo"})
    end

    test "caps at 24 items and slices to 500 characters" do
      assert {:ok, %{"items" => items}} =
               Blocks.normalize(%{
                 "type" => "list",
                 "items" => List.duplicate(String.duplicate("y", 600), 30)
               })

      assert length(items) == 24
      assert Enum.all?(items, &(String.length(&1) == 500))
    end
  end

  describe "normalize/1 — links" do
    test "keeps http and https urls" do
      assert Blocks.normalize(%{
               "type" => "links",
               "items" => [
                 %{"title" => "Docs", "url" => "https://example.com/docs"},
                 %{"title" => "Legacy", "url" => "http://example.com"}
               ]
             }) ==
               {:ok,
                %{
                  "type" => "links",
                  "items" => [
                    %{"title" => "Docs", "url" => "https://example.com/docs"},
                    %{"title" => "Legacy", "url" => "http://example.com"}
                  ]
                }}
    end

    test "drops items with non-http(s) schemes" do
      for url <- [
            "javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "ftp://example.com/file",
            "file:///etc/passwd",
            "vbscript:msgbox"
          ] do
        assert Blocks.normalize(%{
                 "type" => "links",
                 "items" => [%{"title" => "x", "url" => url}]
               }) == :invalid
      end
    end

    test "drops items whose url has no host or no scheme" do
      for url <- ["https://", "http:///path", "/relative/path", "example.com", "//example.com"] do
        assert Blocks.normalize(%{
                 "type" => "links",
                 "items" => [%{"title" => "x", "url" => url}]
               }) == :invalid
      end
    end

    test "drops items with a missing or non-string url" do
      assert Blocks.normalize(%{"type" => "links", "items" => [%{"title" => "x"}]}) == :invalid

      assert Blocks.normalize(%{"type" => "links", "items" => [%{"title" => "x", "url" => 42}]}) ==
               :invalid
    end

    test "scheme matching is case-insensitive" do
      assert {:ok, %{"items" => [%{"url" => "HTTPS://Example.com/A"}]}} =
               Blocks.normalize(%{
                 "type" => "links",
                 "items" => [%{"title" => "x", "url" => "HTTPS://Example.com/A"}]
               })
    end

    test "a missing title falls back to the url" do
      assert {:ok, %{"items" => [%{"title" => "https://example.com/x"}]}} =
               Blocks.normalize(%{
                 "type" => "links",
                 "items" => [%{"url" => "https://example.com/x"}]
               })
    end

    test "invalid items are dropped while valid ones are kept, in order" do
      assert {:ok, %{"items" => [%{"url" => "https://a.example"}]}} =
               Blocks.normalize(%{
                 "type" => "links",
                 "items" => [
                   %{"title" => "bad", "url" => "javascript:alert(1)"},
                   %{"title" => "good", "url" => "https://a.example"}
                 ]
               })
    end
  end

  describe "normalize/1 — timeline" do
    test "keeps date/event pairs and drops incomplete items" do
      assert Blocks.normalize(%{
               "type" => "timeline",
               "items" => [
                 %{"date" => "2026-07-01", "event" => "Kickoff"},
                 %{"date" => "2026-07-02"},
                 %{"event" => "orphan"}
               ]
             }) ==
               {:ok,
                %{
                  "type" => "timeline",
                  "items" => [%{"date" => "2026-07-01", "event" => "Kickoff"}]
                }}
    end
  end

  describe "normalize/1 — entities" do
    test "keeps name with optional detail" do
      assert Blocks.normalize(%{
               "type" => "entities",
               "items" => [
                 %{"name" => "Acme", "detail" => "Series A"},
                 %{"name" => "Globex"},
                 %{"detail" => "no name"}
               ]
             }) ==
               {:ok,
                %{
                  "type" => "entities",
                  "items" => [%{"name" => "Acme", "detail" => "Series A"}, %{"name" => "Globex"}]
                }}
    end

    test "name is sliced to 120 and detail to 500" do
      long = String.duplicate("z", 600)

      assert {:ok, %{"items" => [item]}} =
               Blocks.normalize(%{
                 "type" => "entities",
                 "items" => [%{"name" => long, "detail" => long}]
               })

      assert String.length(item["name"]) == 120
      assert String.length(item["detail"]) == 500
    end
  end
end
