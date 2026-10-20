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

  defp card(kind, data) do
    %{
      input()
      | "html" => "<section id=\"card\"></section>",
        "script" => "comma.card('card', '#{kind}', comma.data.card, 'compact');",
        "data" => %{"card" => data}
    }
  end
end
