defmodule SalixWeb.OAuthCallbackPageTest do
  use SystemsClock.Case, async: true

  alias SalixWeb.OAuthCallbackPage

  test "MCP aliases retain their identity even when they match a provider key" do
    assert OAuthCallbackPage.render("google") =~ "Successfully connected to Google Workspace"
    html = OAuthCallbackPage.render_mcp("google")
    assert html =~ "Successfully connected to google"
    assert OAuthCallbackPage.render_mcp("  ") =~ "Successfully connected to remote MCP"
  end

  test "MCP servers on a branded host show the vendor logo, chosen by host not alias" do
    posthog = OAuthCallbackPage.render_mcp("posthog", nil, "https://mcp.posthog.com/mcp")
    assert posthog =~ "posthog-p6"
    refute posthog =~ ~s(aria-label="MCP")
    assert posthog =~ "Successfully connected to posthog"

    assert OAuthCallbackPage.render_mcp("analytics", nil, "https://MCP-EU.PostHog.com/sse") =~
             "posthog-p6"

    for url <- [
          nil,
          "https://mcp.example.com/mcp",
          "https://posthog.com.evil.io/mcp",
          "not a url"
        ] do
      html = OAuthCallbackPage.render_mcp("posthog", nil, url)
      refute html =~ "posthog-p6"
      assert html =~ ~s(aria-label="MCP")
    end
  end

  test "MCP success escapes the user-controlled alias" do
    html = OAuthCallbackPage.render_mcp(~s|<script>alert("alias")</script>|)
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
    assert html =~ "You can close this window now."
  end

  test "MCP failure escapes the error and does not claim success" do
    html = OAuthCallbackPage.render_mcp("docs", "Denied <script>alert(1)</script>")
    assert html =~ "Authorization failed"
    assert html =~ "Denied &lt;script&gt;"
    refute html =~ "Successfully connected"
    refute html =~ "You can close this window now."
    refute html =~ "<script>"
  end
end
