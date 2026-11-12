defmodule SalixAgent.Tools.DynamicUITest do
  use SystemsClock.Case, async: true
  alias SalixAgent.Tools.DynamicUI

  defp input do
    %{
      "html" => "<p id=\"temperature\">26 °C</p>",
      "script" => "comma.text('temperature', comma.data.temperature)",
      "data" => %{"temperature" => "27 °C"},
      "summary" => "Singapore: 27 °C"
    }
  end

  # Markup alone: a script would have to name its elements.
  defp html_only(html), do: %{input() | "html" => html, "script" => ""}

  test "accepts data-backed local interaction without executing the script" do
    assert {:ok, %{"version" => 1, "data" => %{"temperature" => "27 °C"}}} =
             DynamicUI.validate(input())
  end

  test "accepts composed widget shells and local actions" do
    html = """
    <div class="widget-grid"><section class="card span-2">
      <div class="widget-head"><h2 class="widget-title">Weather</h2><small class="widget-meta">Observed today</small></div>
      <div class="widget-body"><div class="feature motion-enter"><comma-icon name="partly-cloudy" class="icon-hero tone-warm" aria-label="Partly cloudy"></comma-icon></div><p class="hero">26<span class="unit">°C</span></p><p class="sub">Cloudy</p></div>
      <div class="widget-footer"><button id="refresh" class="primary">Refresh</button></div>
    </section></div>
    """

    assert {:ok, _} =
             DynamicUI.validate(%{
               input()
               | "html" => html,
                 "script" => "comma.on('refresh','click',()=>comma.request('Refresh weather'))"
             })
  end

  test "accepts whole-item HTTPS links and rejects unsafe or nested actions" do
    assert {:ok, _} =
             DynamicUI.validate(
               html_only(
                 ~s(<a href="https://example.test/train"><strong>18:01</strong><span>G1510</span></a>)
               )
             )

    for html <- [
          ~s|<a href="javascript:alert(1)">Train</a>|,
          ~s(<a href="https://user:secret@example.test">Train</a>),
          ~s(<a href="https://example.test"><button>Buy</button></a>)
        ] do
      assert {:error, "html", _, _} = DynamicUI.validate(html_only(html))
    end
  end

  test "accepts HTTPS presentation resources but rejects active requests and unsafe markup" do
    html =
      ~s(<img class="external-photo" src="https://example.test/image.png" alt="Landscape"><link rel="stylesheet" href="https://example.test/theme.css"><script src="https://example.test/library.js"></script>)

    assert {:ok, _} = DynamicUI.validate(html_only(html))

    for markup <- [
          "<img src='http://example.test/x' alt='x'>",
          "<script>alert(1)</script>",
          "<script src='https://example.test/a.js'>alert(1)</script>",
          "<link rel='preload' href='https://example.test/x'>",
          "<div src='https://example.test/x'></div>"
        ] do
      assert {:error, "html", _, _} = DynamicUI.validate(html_only(markup))
    end

    assert {:error, "script", _, _} =
             DynamicUI.validate(Map.put(input(), "script", "fetch('https://example.test/x')"))
  end

  test "accepts line breaks and an omitted optional version reference in calendar cells" do
    args =
      Map.merge(input(), %{
        "html" => "<table><tbody><tr><td>25<br/><small>Holiday</small></td></tr></tbody></table>",
        "script" => "",
        "previous_ui_ref" => nil
      })

    assert {:ok, _} = DynamicUI.validate(args)

    assert {:error, "html", reason, _} =
             DynamicUI.validate(Map.put(args, "html", "<section><iframe></iframe></section>"))

    assert reason =~ "<iframe>"
    assert reason =~ "node 2"
  end

  test "the help example is a card call whose data passes the card contract" do
    example = DynamicUI.example_params()
    assert {:ok, _} = DynamicUI.validate(example)

    empty = put_in(example, ["data", "place", "places"], [])
    assert {:error, "data", reason, _} = DynamicUI.validate(empty)
    assert reason =~ "comma.card card (place)"
  end

  test "a card's data fits the one Worker message that carries it" do
    item = fn index, title ->
      %{
        "source" => "zanwei",
        "title" => "##{4000 + index} #{title}",
        "at" => "2026-10-22T09:25:00Z",
        "status" => %{"label" => "已合并", "tone" => "brand"},
        "href" => "https://github.com/AFK-surf/Cue/pull/#{4000 + index}",
        "filterKeys" => ["all", "merged"]
      }
    end

    feed = fn title ->
      card("feed", %{
        "title" => "今天的 PR",
        "items" => Enum.map(0..59, &item.(&1, title))
      })
    end

    # A day's pull requests with plain titles fit.
    assert {:ok, _} = DynamicUI.validate(feed.("fix(chat): keep attachments downloading"))

    # 60 items at the 160-character title limit do not: the client would stop the widget.
    assert {:error, "data", reason, _} = DynamicUI.validate(feed.(String.duplicate("修", 160)))
    assert reason =~ "comma.data.card is over 31 KiB"
  end

  test "each SDK update names an element of the kind the runtime updates" do
    chart = %{
      input()
      | "html" => ~s(<comma-chart id="conversion" aria-label="Conversions"></comma-chart>),
        "script" => "comma.chart('conversion',comma.data.conversion);",
        "data" => %{"conversion" => %{"labels" => ["a"], "values" => [1], "type" => "bar"}}
    }

    assert {:ok, _} = DynamicUI.validate(chart)

    # The runtime stops the whole widget when an update's target is missing or
    # of another kind, as a chart aimed at a section did in a daily report.
    assert {:error, "script", reason, suggestion} =
             DynamicUI.validate(%{chart | "html" => ~s(<section id="conversion"></section>)})

    assert reason =~ "comma.chart target conversion is not a comma-chart"
    assert suggestion =~ ~s(<comma-chart id="conversion">)

    for {html, script, expected} <- [
          {~s(<p id="a"></p>), "comma.text('b','x')", "comma.text target b is not in html"},
          {~s(<p id="a"></p>), "comma.value('a','1')", "comma.value target a is not a input"},
          {~s(<div id="a"></div>), "comma.table('a',comma.data.t)",
           "comma.table target a is not a table"},
          {~s(<table><tbody id="a"></tbody></table>), "comma.text('a','x')",
           "cannot update table structure at a"}
        ] do
      assert {:error, "script", reason, _} =
               DynamicUI.validate(%{input() | "html" => html, "script" => script})

      assert reason =~ expected
    end

    # Targets the script computes are the runtime's to check.
    assert {:ok, _} =
             DynamicUI.validate(%{
               input()
               | "html" => ~s(<p id="row-1"></p><progress id="done"></progress>),
                 "script" =>
                   "comma.text('row-'+1,'x');comma.value('done','1');comma.visible('row-1',true)"
             })
  end

  test "card data takes a status as text and a total as a number" do
    hosts =
      card("feed", %{
        "title" => "服务器",
        "items" => [%{"source" => "API", "title" => "salix-prod-1", "status" => "正常"}]
      })

    assert {:ok, _} = DynamicUI.validate(hosts)

    split =
      card("composition", %{
        "title" => "合并 PR 按领域",
        "total" => 47,
        "segments" => [%{"label" => "clients", "value" => 21}]
      })

    assert {:ok, _} = DynamicUI.validate(split)
  end

  test "bars take a number per category, a table one cell per column, a change its text" do
    bars = fn value ->
      card("bars", %{
        "title" => "流量来源",
        "items" => [%{"label" => "直接访问", "value" => value, "compare" => 96}]
      })
    end

    assert {:ok, _} = DynamicUI.validate(bars.(118))
    assert {:error, "data", reason, _} = DynamicUI.validate(bars.("118"))
    assert reason =~ "items[0].value must be a number"

    table = fn rows ->
      card("table", %{
        "title" => "热销商品",
        "columns" => ["商品", "销量", "较上周"],
        "rows" => rows
      })
    end

    assert {:ok, _} =
             DynamicUI.validate(
               table.([
                 ["机械键盘", 312, %{"text" => "↑2", "tone" => "success"}],
                 ["鼠标", 287, nil],
                 ["支架", "", "—"]
               ])
             )

    assert {:error, "data", reason, _} = DynamicUI.validate(table.([["机械键盘", 312]]))
    assert reason =~ "rows[0] needs 3 entries, as many as columns"

    # A change reads with its unit, so a bare number is not one.
    metric = fn change ->
      card("metric", %{
        "title" => "流量",
        "metrics" => [
          %{"label" => "访客", "value" => "181", "delta" => %{"value" => change}}
        ]
      })
    end

    assert {:ok, _} = DynamicUI.validate(metric.("37.6%"))
    assert {:error, "data", reason, _} = DynamicUI.validate(metric.(37.6))
    assert reason =~ "metrics[0].delta.value must be text"
  end

  test "a widget takes the lowest runtime level that shows it" do
    level = fn input ->
      {:ok, %{"version" => version}} = DynamicUI.validate(input)
      version
    end

    forecast = %{"title" => "新加坡", "current" => %{"temperature" => 27, "condition" => "clear"}}
    bars = %{"title" => "流量来源", "items" => [%{"label" => "直接访问", "value" => 128}]}

    chart = fn data ->
      %{
        input()
        | "html" => ~s(<comma-chart id="trend" aria-label="Trend"></comma-chart>),
          "script" => "comma.chart('trend', comma.data.trend);",
          "data" => %{"trend" => data}
      }
    end

    # Text, a kind and a one-series chart that every runtime shows.
    assert level.(input()) == 1
    assert level.(card("forecast", forecast)) == 1
    assert level.(chart.(%{"type" => "line", "labels" => ["a"], "values" => [1]})) == 1

    # A kind and a chart form that the first runtime does not show.
    assert level.(card("bars", bars)) == 2

    assert level.(
             chart.(%{
               "type" => "line",
               "labels" => ["a"],
               "series" => [%{"name" => "访客", "values" => [1]}]
             })
           ) == 2

    # A kind the script computes cannot be read, so the widget takes the current level.
    computed = card("forecast", forecast)

    assert level.(%{
             computed
             | "script" => "comma.card('card', comma.data.kind, comma.data.card);",
               "data" => Map.put(computed["data"], "kind", "forecast")
           }) == 2

    # A card reached through an alias cannot be read either.
    for script <- [
          "const { card } = comma; card('card', 'forecast', comma.data.card);",
          "comma['card']('card', 'forecast', comma.data.card);",
          "comma.card.call(null, 'card', 'forecast', comma.data.card);"
        ] do
      assert level.(%{computed | "script" => script}) == 2
    end
  end

  defp card(kind, data) do
    %{
      input()
      | "html" => "<section id=\"card\"></section>",
        "script" => "comma.card('card', '#{kind}', comma.data.card, 'compact');",
        "data" => %{"card" => data}
    }
  end
end
