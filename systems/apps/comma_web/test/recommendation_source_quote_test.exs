defmodule CommaWeb.RecommendationSourceQuoteTest do
  use ExUnit.Case, async: true

  alias CommaWeb.RecommendationSourceQuote, as: Quote

  test "markdown keeps its words, lines, list items and links" do
    quote =
      Quote.new(
        title: "Flaky <upload> test",
        body:
          {:markdown,
           "## Steps\n\n1. Run `mix test`\n2. Upload fails **one in five** runs\nsee logs :pray:\n\n" <>
             "<!-- template note -->\n- [x] See [run 812](https://github.com/o/r/runs/812)\n" <>
             "> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |"}
      )

    assert quote == %{
             "title" => "Flaky &lt;upload&gt; test",
             "lines" => [
               "Steps",
               "• Run mix test",
               "• Upload fails one in five runs",
               "see logs 🙏",
               "• See <https://github.com/o/r/runs/812|run 812>",
               "quoted",
               "a · b",
               "1 · 2"
             ]
           }
  end

  test "html keeps blocks as lines and links with their labels" do
    assert Quote.new(
             body:
               {:html,
                "<!-- cue:prep --><h3>Prep</h3><p>Agenda:</p><ul><li>Wrap up (<a href=\"https://a.example/x?t=1&amp;c=2\">notes</a>)</li>" <>
                  "<li><b>Sync</b> &amp; <a href=\"mailto:a@example.com\">mail</a></li></ul>Line<br>break<script>x</script>"}
           ) == %{
             "lines" => [
               "Prep",
               "Agenda:",
               "• Wrap up (<https://a.example/x?t=1&c=2|notes>)",
               "• Sync &amp; mail",
               "Line",
               "break"
             ]
           }
  end

  test "slack keeps mentions and links but not emphasis marks" do
    assert Quote.new(
             author: "mira",
             body:
               {:slack,
                "<!here> <@U1|alex> please check the *deploy* in <#C1|ops> before 5pm :pray:\n" <>
                  "_not_now_ keeps `snake_case` and 2*3*4 &lt;tag&gt;"}
           )["lines"] == [
             "@here <@U1|alex> please check the deploy in <#C1|ops> before 5pm 🙏",
             "_not_now_ keeps snake_case and 2*3*4 &lt;tag&gt;"
           ]
  end

  test "mail ends before the history it quotes, and facts keep known values" do
    quote =
      Quote.new(
        title: "Renewal",
        author: "Alex Chen",
        facts: [checks: :failing, review: :unknown, status: "  ", draft: true],
        body:
          {:mail,
           "Hi,\r\n\r\nPlease sign by Friday <legal@acme.com>.\r\n\r\n" <>
             "On Mon, Oct 13, 2026 at 9:02 AM Zanwei wrote:\r\n> Draft attached."}
      )

    assert quote == %{
             "title" => "Renewal",
             "author" => "Alex Chen",
             "facts" => [%{"kind" => "checks", "value" => "failing"}, %{"kind" => "draft"}],
             "lines" => ["Hi,", "Please sign by Friday &lt;legal@acme.com&gt;."]
           }
  end

  test "mail text drops the addresses Outlook writes for its images" do
    assert Quote.new(
             body:
               {:mail,
                "[https://statici.icloud.com/fmipmobile/deviceImages-4.0/online_2x.png]\r\n" <>
                  "Find My has been disabled on pengx17. [cid:image001.png@01DA2B]\r\n" <>
                  "[image: Apple] stays."}
           )["lines"] == ["Find My has been disabled on pengx17.", "[image: Apple] stays."]
  end

  test "mail ends before a wrapped attribution or a reply header" do
    assert Quote.new(
             body:
               {:mail,
                "Ship it today.\n\nOn Mon, Oct 13, 2026 at 9:02 AM Zanwei Guo <zanwei@example.com>\n" <>
                  "wrote:\n> Ready?"}
           )["lines"] == ["Ship it today."]

    assert Quote.new(
             body:
               {:mail,
                "Approved.\r\n\r\n________________________________\r\nFrom: Alex\r\nSent: Monday"}
           )["lines"] == ["Approved."]

    assert Quote.new(
             body: {:mail, "Approved.\n\nFrom: Alex Chen <alex@example.com>\nSent: Monday\nBody"}
           )["lines"] == ["Approved."]

    # A line that only starts like a header stays.
    assert Quote.new(body: {:mail, "From: the team\nThanks"})["lines"] ==
             ["From: the team", "Thanks"]
  end

  test "html mail keeps its lines and drops the messages it quotes" do
    assert Quote.new(
             body:
               {:mail_html,
                "<html><head><style>p{}</style></head><body><div dir=\"ltr\">Hi,<div><br></div>" <>
                  "<div>Please review <a href=\"https://docs.example/x\">the draft</a>.</div></div>" <>
                  "<div class=\"gmail_quote\"><div class=\"gmail_attr\">On Mon, Alex wrote:</div>" <>
                  "<blockquote>Earlier</blockquote></div></body></html>"}
           )["lines"] == ["Hi,", "Please review <https://docs.example/x|the draft>."]

    assert Quote.new(
             body:
               {:mail_html,
                "<div>Done.</div><hr><div id=\"divRplyFwdMsg\"><b>From:</b> Alex</div><div>Old text</div>"}
           )["lines"] == ["Done."]
  end
end
