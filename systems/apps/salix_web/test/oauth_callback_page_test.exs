defmodule SalixWeb.OAuthCallbackPageTest do
  use ExUnit.Case, async: true

  alias SalixWeb.OAuthCallbackPage

  test "MCP aliases retain their identity even when they match a provider key" do
    assert OAuthCallbackPage.render("google") =~ "Successfully connected to Google Workspace"
    html = OAuthCallbackPage.render_mcp("google")
    assert html =~ "Successfully connected to google"
    assert OAuthCallbackPage.render_mcp("  ") =~ "Successfully connected to remote MCP"
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
