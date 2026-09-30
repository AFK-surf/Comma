defmodule SalixAgent.Tools.DynamicUITest do
  use ExUnit.Case, async: true
  alias SalixAgent.Tools.DynamicUI

  defp input do
    %{
      "html" => "<p id=\"temperature\">26 °C</p>",
      "script" => "comma.text('temperature', comma.data.temperature)",
      "data" => %{"temperature" => "27 °C"},
      "summary" => "Singapore: 27 °C"
    }
  end

  test "accepts data-backed local interaction without executing the script" do
    assert {:ok, %{"version" => 1, "data" => %{"temperature" => "27 °C"}}} =
             DynamicUI.validate(input())
  end

  test "a static widget with an empty script passes the shared parameter check" do
    # A static PR list on staging sent script: "" twice. The shared check
    # answered "missing required params: script", and the reply fell back to text.
    static = %{input() | "script" => ""}

    assert :ok = SalixAgent.Tools.validate_schema(static, DynamicUI.schema())
    assert {:ok, %{"script" => ""}} = DynamicUI.validate(static)
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
               Map.put(
                 input(),
                 "html",
                 ~s(<a href="https://example.test/train"><strong>18:01</strong><span>G1510</span></a>)
               )
             )

    for html <- [
          ~s|<a href="javascript:alert(1)">Train</a>|,
          ~s(<a href="https://user:secret@example.test">Train</a>),
          ~s(<a href="https://example.test"><button>Buy</button></a>)
        ] do
      assert {:error, "html", _, _} = DynamicUI.validate(Map.put(input(), "html", html))
    end
  end

  test "accepts HTTPS presentation resources but rejects active requests and unsafe markup" do
    html =
      ~s(<img class="external-photo" src="https://example.test/image.png" alt="Landscape"><link rel="stylesheet" href="https://example.test/theme.css"><script src="https://example.test/library.js"></script>)

    assert {:ok, _} = DynamicUI.validate(Map.put(input(), "html", html))

    for markup <- [
          "<img src='http://example.test/x' alt='x'>",
          "<script>alert(1)</script>",
          "<script src='https://example.test/a.js'>alert(1)</script>",
          "<link rel='preload' href='https://example.test/x'>",
          "<div src='https://example.test/x'></div>"
        ] do
      assert {:error, "html", _, _} = DynamicUI.validate(Map.put(input(), "html", markup))
    end

    assert {:error, "script", _, _} =
             DynamicUI.validate(Map.put(input(), "script", "fetch('https://example.test/x')"))
  end

  test "accepts line breaks and an omitted optional version reference in calendar cells" do
    args =
      Map.merge(input(), %{
        "html" => "<table><tbody><tr><td>25<br/><small>Holiday</small></td></tr></tbody></table>",
        "previous_ui_ref" => nil
      })

    assert {:ok, _} = DynamicUI.validate(args)

    assert {:error, "html", reason, _} =
             DynamicUI.validate(Map.put(args, "html", "<section><iframe></iframe></section>"))

    assert reason =~ "<iframe>"
    assert reason =~ "node 2"
  end

  test "returns correction errors before persisting unsupported components" do
    for html <- [
          "<a>link</a>",
          "<p data-unknown='x'>text</p>",
          "<p id='same'>a</p><p id='same'>b</p>"
        ] do
      assert {:error, "html", _, _} = DynamicUI.validate(Map.put(input(), "html", html))
    end
  end

  test "rejects structural text updates but accepts leaf updates in authored layouts" do
    args =
      input()
      |> Map.put("html", "<table><tbody id='rows'><tr><td id='day'>Mon</td></tr></tbody></table>")

    assert {:error, "script", _, _} =
             DynamicUI.validate(
               Map.put(args, "script", "comma.text('rows','<tr><td>Tue</td></tr>')")
             )

    assert {:ok, _} =
             DynamicUI.validate(Map.put(args, "script", "comma.text('day','Tue')"))
  end

  test "returns a correction for card calls with an unknown kind or a missing target" do
    args = %{
      input()
      | "html" => "<section id=\"card\"></section>",
        "data" => %{"forecast" => %{"title" => "Singapore", "current" => %{"temperature" => 27}}}
    }

    assert {:ok, _} =
             DynamicUI.validate(
               Map.put(args, "script", "comma.card('card', 'forecast', comma.data.forecast)")
             )

    assert {:error, "script", "comma.card has no weather template", suggestion} =
             DynamicUI.validate(
               Map.put(args, "script", "comma.card('card', 'weather', comma.data)")
             )

    assert suggestion =~ "forecast"

    assert {:error, "script", "comma.card target summary is not in html", _} =
             DynamicUI.validate(
               Map.put(args, "script", ~s|comma.card("summary", "metric", comma.data)|)
             )
  end

  defp card(kind, data) do
    %{
      input()
      | "html" => "<section id=\"card\"></section>",
        "script" => "comma.card('card', '#{kind}', comma.data.card, 'compact');",
        "data" => %{"card" => data}
    }
  end

  test "names card data the template cannot render before the reader sees the card" do
    # The staging forecast that showed "Couldn't display this widget":
    # temperatures as text with units, which the template reads as numbers.
    staging = %{
      "title" => "Shanghai tomorrow",
      "days" => [
        %{
          "label" => "Sun 27 Sep",
          "condition" => "rain",
          "conditionLabel" => "Scattered showers",
          "high" => "31°C",
          "low" => "25°C",
          "precipitation" => 90
        }
      ],
      "sourceBrand" => "Open-Meteo",
      "tone" => "warning"
    }

    assert {:error, "data", reason, suggestion} = DynamicUI.validate(card("forecast", staging))

    assert reason =~
             ~s|comma.card card (forecast) data: days[0].high must be a number, got "31°C"|

    assert reason =~ ~s(days[0].low must be a number, got "25°C")
    assert suggestion =~ "without units"

    fixed = update_in(staging, ["days", Access.at(0)], &%{&1 | "high" => 31, "low" => 25})
    assert {:ok, _} = DynamicUI.validate(card("forecast", fixed))
  end

  test "checks card data against the contract the templates render" do
    assert {:error, "data", reason, _} =
             DynamicUI.validate(%{card("forecast", %{}) | "data" => %{}})

    assert reason =~ "comma.data.card is missing"

    assert {:error, "data", reason, _} =
             DynamicUI.validate(card("forecast", %{"title" => "Rain"}))

    assert reason =~ "data needs days or current"

    day = %{"label" => "Mon", "conditionLabel" => "Showers", "high" => 20, "low" => 12}

    assert {:error, "data", reason, _} =
             DynamicUI.validate(
               card("forecast", %{
                 "title" => "Rain",
                 "days" => [Map.put(day, "condition", "showers")]
               })
             )

    assert reason =~ ~s(days[0].condition must be one of clear, clear-night)

    # Null and blank text mean unknown, as they do in the templates.
    assert {:ok, _} =
             DynamicUI.validate(
               card("forecast", %{
                 "title" => "Rain",
                 "location" => nil,
                 "days" => [Map.merge(day, %{"condition" => "rain", "precipitation" => nil})],
                 "highlight" => " "
               })
             )

    assert {:error, "data", reason, _} =
             DynamicUI.validate(
               card("comparison", %{
                 "title" => "Plans",
                 "subjects" => [%{"name" => "A"}, %{"name" => "B"}],
                 "rows" => [%{"label" => "Price", "values" => ["$5"]}]
               })
             )

    assert reason =~ "rows[0].values needs 2 entries, as many as subjects, not 1"

    # Data the script builds is checked when the card renders.
    assert {:ok, _} =
             DynamicUI.validate(%{
               card("forecast", %{})
               | "script" => "comma.card('card', 'forecast', {title: comma.data.title});"
             })
  end

  test "rejects an empty bar chart before the widget renders" do
    assert {:error, "data", reason, _} =
             DynamicUI.validate(
               card("trend", %{"title" => "Trend", "bars" => %{"labels" => [], "values" => []}})
             )

    assert reason =~ "needs at least 1 entries"

    assert {:ok, _} =
             DynamicUI.validate(
               card("trend", %{
                 "title" => "Trend",
                 "bars" => %{"labels" => ["Mon"], "values" => [1]}
               })
             )
  end

  test "checks only the list entries that the templates keep" do
    feed = %{
      "title" => "News",
      "items" => List.duplicate(%{"source" => "Comma", "title" => "Update"}, 6) ++ [%{}]
    }

    # Validation must not change the data stored for the script.
    assert {:ok, %{"data" => %{"card" => ^feed}}} = DynamicUI.validate(card("feed", feed))

    assert {:error, "data", reason, _} =
             DynamicUI.validate(card("feed", %{feed | "items" => [%{} | feed["items"]]}))

    assert reason =~ "items[0]."

    comparison = %{
      "title" => "Plans",
      "subjects" => Enum.map(~w(A B C D), &%{"name" => &1}),
      "rows" => [%{"label" => "Price", "values" => ["1", "2", "3", 4]}]
    }

    assert {:ok, _} = DynamicUI.validate(card("comparison", comparison))

    assert {:ok, _} =
             DynamicUI.validate(
               card(
                 "comparison",
                 put_in(comparison, ["rows"], [
                   %{"label" => "Price", "values" => ["1", "2", "3"]}
                 ])
               )
             )

    assert {:ok, _} =
             DynamicUI.validate(
               card("trend", %{
                 "title" => "Trend",
                 "bars" => %{
                   "labels" => List.duplicate("Day", 32),
                   "values" => List.duplicate(1, 31)
                 }
               })
             )
  end

  test "uses the retained subject count and the shared checklist item budget" do
    assert {:ok, _} =
             DynamicUI.validate(
               card("comparison", %{
                 "title" => "Plans",
                 "subjects" => [%{"name" => "A"}, %{"name" => "B"}],
                 "rows" => [%{"label" => "Price", "values" => ["1", "2", 3]}]
               })
             )

    items = List.duplicate(%{"label" => "Task"}, 6)

    checklist = %{
      "title" => "Tasks",
      "groups" => [
        %{"items" => items},
        %{"items" => items ++ [%{}]},
        %{"items" => [%{}]}
      ]
    }

    assert {:ok, %{"data" => %{"card" => ^checklist}}} =
             DynamicUI.validate(card("checklist", checklist))

    invalid = put_in(checklist, ["groups"], [%{"items" => [%{} | items]}])
    assert {:error, "data", _, _} = DynamicUI.validate(card("checklist", invalid))
  end

  test "a status list renders through the feed template" do
    items = [
      %{
        "source" => "Comma #2076",
        "title" => "Composer typing independent of conversation",
        "excerpt" => "26/26 checks · approved",
        "status" => %{"label" => "Clean", "tone" => "success"},
        "href" => "https://github.com/AFK-surf/Comma/pull/2076",
        "brand" => "github"
      }
    ]

    assert {:ok, _} = DynamicUI.validate(card("feed", %{"title" => "Open PRs", "items" => items}))

    assert {:error, "data", reason, _} =
             DynamicUI.validate(
               card("feed", %{
                 "title" => "Open PRs",
                 "items" => [put_in(hd(items), ["status", "tone"], "danger")]
               })
             )

    assert reason =~ "items[0].status.tone must be one of neutral, brand, success, warning, error"
    assert DynamicUI.manual() =~ "status lists such as pull requests"
  end

  test "requires fallback text and bounds the complete encoded payload" do
    assert {:error, "html", _, _} =
             DynamicUI.validate(
               Map.put(input(), "html", String.duplicate("<comma-chart></comma-chart>", 9))
             )

    assert {:error, "previous_ui_ref", _, _} =
             DynamicUI.validate(Map.put(input(), "previous_ui_ref", %{}))

    assert {:error, "summary", _, _} = DynamicUI.validate(Map.put(input(), "summary", ""))

    assert {:error, "payload", _, _} =
             DynamicUI.validate(
               Map.put(input(), "data", %{"value" => String.duplicate("x", 262_144)})
             )
  end

  test "escaped markup remains plain text" do
    html = "<p>&lt;img src=x onerror=alert(1)&gt;</p>"
    assert {:ok, payload} = DynamicUI.validate(Map.put(input(), "html", html))
    assert Floki.parse_fragment!(payload["html"]) |> Floki.find("img") == []

    assert Floki.parse_fragment!(payload["html"]) |> Floki.text() ==
             "<img src=x onerror=alert(1)>"
  end

  test "a message carries one ref-only UI with a truthful text fallback" do
    block = %{
      "type" => "dynamic_ui",
      "version" => 1,
      "ui_ref" => "example",
      "path" => "/ui.json",
      "summary" => "Weather",
      "text" => "Weather"
    }

    assert {:ok, [^block]} = SalixIM.ConversationMessage.validate_content("message", [block])
    assert {:error, _} = SalixIM.ConversationMessage.validate_content("message", [block, block])

    assert {:error, _} =
             SalixIM.ConversationMessage.validate_content("message", [
               Map.put(block, "script", "alert(1)")
             ])
  end
end
