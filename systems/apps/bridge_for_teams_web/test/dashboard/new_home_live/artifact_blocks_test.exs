defmodule BridgeForTeamsWeb.Dashboard.NewHomeLive.ArtifactBlocksTest do
  @moduledoc """
  The typed artifact-block renderers: every vocabulary type in both variants,
  strict output escaping (agent-written strings never land unescaped), links
  restricted to the URLs `Blocks.normalize/1` validated, and the quiet
  "Unrecognized content" card for anything unrenderable — raw JSON never
  reaches the page.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BridgeForTeamsWeb.Dashboard.NewHomeLive.ArtifactBlocks

  defp render_block(block, variant \\ :full) do
    render_component(&ArtifactBlocks.block/1, block: block, variant: variant)
  end

  describe "kpis" do
    @kpis %{
      "type" => "kpis",
      "items" => [
        %{"label" => "ARR", "value" => "$1.2M", "delta" => "+8%", "note" => "vs last month"},
        %{"label" => "Churn", "value" => "2.1%"}
      ]
    }

    test "full variant renders the stat grid with delta and note" do
      html = render_block(@kpis)

      assert html =~ "grid-cols-2"
      assert html =~ "ARR"
      assert html =~ "$1.2M"
      assert html =~ "+8%"
      assert html =~ "vs last month"
      assert html =~ "Churn"
      assert html =~ "tabular-nums"
    end

    test "compact variant renders the first item as the oversized hero" do
      html = render_block(@kpis, :compact)

      assert html =~ "text-2xl"
      assert html =~ "$1.2M"
      # The rest stay quiet rows, not hero numbers.
      assert html =~ "2.1%"
      assert length(String.split(html, "text-2xl")) == 2
    end

    test "compact variant with a single item renders no rest rows" do
      html =
        render_block(
          %{"type" => "kpis", "items" => [%{"label" => "MRR", "value" => "$99k"}]},
          :compact
        )

      assert html =~ "$99k"
      refute html =~ "divide-y"
    end
  end

  describe "table" do
    @table %{
      "type" => "table",
      "columns" => ["Repo", "PRs"],
      "rows" => [["systems", "12"], ["site", "3"]]
    }

    test "renders header cells and body rows" do
      html = render_block(@table)

      assert html =~ "<table"
      assert html =~ "Repo"
      assert html =~ "PRs"
      assert html =~ "systems"
      assert html =~ "12"
      assert html =~ "tabular-nums"
    end

    test "compact variant tightens the text" do
      assert render_block(@table, :compact) =~ "text-xs"
    end
  end

  describe "list" do
    test "renders items with the plain dot by default" do
      html = render_block(%{"type" => "list", "style" => "plain", "items" => ["Ship the fix"]})

      assert html =~ "Ship the fix"
      assert html =~ "bg-neutral-300"
    end

    test "styles tint the leading dot" do
      risks = %{"type" => "list", "style" => "risks", "items" => ["Vendor delay"]}
      actions = %{"type" => "list", "style" => "actions", "items" => ["Email legal"]}
      watch = %{"type" => "list", "style" => "watch", "items" => ["Churn creep"]}

      assert render_block(risks) =~ "bg-red-500"
      assert render_block(actions) =~ "bg-brand-500"
      assert render_block(watch) =~ "bg-amber-500"
    end
  end

  describe "links" do
    @links %{
      "type" => "links",
      "items" => [%{"title" => "Board deck", "url" => "https://example.com/deck?q=1&r=2"}]
    }

    test "renders anchors with noreferrer + blank target and the validated URL" do
      html = render_block(@links)

      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noreferrer")
      assert html =~ ~s(href="https://example.com/deck?q=1&amp;r=2")
      assert html =~ "Board deck"
    end
  end

  describe "timeline" do
    test "renders date and event per item" do
      html =
        render_block(%{
          "type" => "timeline",
          "items" => [%{"date" => "2026-07-01", "event" => "Kickoff call"}]
        })

      assert html =~ "2026-07-01"
      assert html =~ "Kickoff call"
      assert html =~ "tabular-nums"
    end
  end

  describe "entities" do
    test "renders name with optional detail" do
      html =
        render_block(%{
          "type" => "entities",
          "items" => [%{"name" => "Acme", "detail" => "Series B"}, %{"name" => "Globex"}]
        })

      assert html =~ "Acme"
      assert html =~ "Series B"
      assert html =~ "Globex"
    end
  end

  describe "escaping" do
    test "item strings render escaped, never as markup" do
      html =
        render_block(%{
          "type" => "list",
          "items" => ["<script>alert(1)</script>", "<img src=x onerror=y>"]
        })

      refute html =~ "<script>"
      refute html =~ "<img"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ "&lt;img src=x onerror=y&gt;"
    end

    test "kpi labels and values render escaped in both variants" do
      block = %{
        "type" => "kpis",
        "items" => [%{"label" => "<b>ARR</b>", "value" => "\"1\" & '2'"}]
      }

      for variant <- [:full, :compact] do
        html = render_block(block, variant)
        refute html =~ "<b>"
        assert html =~ "&lt;b&gt;ARR&lt;/b&gt;"
      end
    end

    test "link titles render escaped" do
      html =
        render_block(%{
          "type" => "links",
          "items" => [%{"title" => "<svg onload=x>", "url" => "https://example.com/"}]
        })

      refute html =~ "<svg onload"
      assert html =~ "&lt;svg onload=x&gt;"
    end
  end

  describe "invalid input" do
    test "the :invalid_block document segment renders the quiet card, not the raw text" do
      raw = ~s|{"type": "chart", "payload": "<script>alert(1)</script>"}|

      html = render_block({:invalid_block, raw})

      assert html =~ "Unrecognized content"
      refute html =~ "chart"
      refute html =~ "alert(1)"
    end

    test "the bare :invalid_block atom renders the quiet card" do
      assert render_block(:invalid_block) =~ "Unrecognized content"
    end

    test "unknown block types render the quiet card" do
      html = render_block(%{"type" => "chart", "items" => [%{"x" => 1}]})

      assert html =~ "Unrecognized content"
      refute html =~ "chart"
    end

    test "recognized types missing their normalized shape render the quiet card" do
      assert render_block(%{"type" => "kpis"}) =~ "Unrecognized content"
      assert render_block(%{"type" => "kpis", "items" => []}) =~ "Unrecognized content"
      assert render_block(%{"type" => "table", "columns" => ["A"]}) =~ "Unrecognized content"
      assert render_block(%{"type" => "list", "items" => []}) =~ "Unrecognized content"
      assert render_block("just a string") =~ "Unrecognized content"
      assert render_block(nil) =~ "Unrecognized content"
    end
  end

  describe "document segment tuples" do
    test "a {:block, block} segment unwraps to its typed renderer" do
      html =
        render_block(
          {:block, %{"type" => "list", "style" => "plain", "items" => ["Wrapped fine"]}},
          :compact
        )

      assert html =~ "Wrapped fine"
      refute html =~ "Unrecognized content"
    end
  end

  describe "block-level title caption" do
    @captioned %{"type" => "list", "title" => "Highlights", "items" => ["shipped it"]}

    test "renders above the block in both variants, escaped" do
      for variant <- [:full, :compact] do
        html = render_block(@captioned, variant)
        assert html =~ "Highlights"
        assert html =~ "shipped it"
      end

      html = render_block(%{@captioned | "title" => "<b>bold</b>"})
      refute html =~ "<b>bold</b>"
      assert html =~ "&lt;b&gt;bold&lt;/b&gt;"
    end

    test "absent title renders no caption element" do
      html = render_block(%{"type" => "list", "items" => ["shipped it"]})
      refute html =~ "font-semibold text-neutral-500"
    end
  end
end
