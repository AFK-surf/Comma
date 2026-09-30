defmodule CommaWeb.TelegramCallbackPageTest do
  use ExUnit.Case, async: true

  alias CommaWeb.TelegramCallbackPage

  @client %{name: "Comma Staging", environment: "Staging", scheme: "comma-staging"}
  @return_url "comma-staging://telegram/return?workspace_id=wsp_test"

  test "standalone callback shows the Comma brand without remote resources" do
    html = TelegramCallbackPage.render(@client, @return_url, false, nil)

    assert html =~ ~s(role="img" aria-label="Comma")
    refute html =~ ~r/<(?:link|img)\b|<script[^>]+src=/
  end

  test "successful connection retains the return action" do
    html = TelegramCallbackPage.render(@client, @return_url, true, nil)

    assert html =~ ~s(data-status="connected")
    assert html =~ "Telegram connected"
    assert html =~ ~s(href="#{@return_url}")
    assert html =~ "Return to Comma Staging"
    assert html =~ "If this window stays open, return to Comma to continue."
  end

  for {reason, status, explanation} <- [
        {:invalid_telegram_oidc_attempt, "expired", "start a new Telegram connection"},
        {:telegram_provider_unavailable, "unavailable", "try again shortly"},
        {:invalid_telegram_credential, "failed", "try connecting again"}
      ] do
    test "#{status} preserves actionable guidance" do
      html = TelegramCallbackPage.render(@client, @return_url, false, unquote(reason))

      assert html =~ ~s(data-status="#{unquote(status)}")
      assert html =~ unquote(explanation)
      assert html =~ "Settings → Channels"
      assert html =~ ~s(href="#{@return_url}")
    end
  end

  test "return link and client name are escaped rather than interpreted as markup" do
    client = %{@client | name: ~s(Comma <test> "name"), environment: "<staging>"}
    html = TelegramCallbackPage.render(client, @return_url <> ~s(&value="<test>), false, nil)

    assert html =~ "Comma &lt;test&gt; &quot;name&quot;"
    assert html =~ "&amp;value=&quot;&lt;test&gt;"
    assert html =~ "&lt;staging&gt;"
    refute html =~ "<test>"
  end

  test "unexpected internal failures are not reflected into the page" do
    html = TelegramCallbackPage.render(@client, @return_url, false, {:error, "secret-value"})

    refute html =~ "secret-value"
    assert html =~ "Not connected"
    assert html =~ ~s(<main aria-labelledby="result-title")
    assert html =~ ~s(<h1 id="result-title")
    assert html =~ ~s(type="button")
  end
end
