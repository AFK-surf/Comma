defmodule Salix.Control.RemoteMCPOAuthCallbackPageTest do
  @moduledoc """
  The remote MCP callback page picks its logo from the server URL stored in
  the authorization state, so a PostHog MCP shows the PostHog logo whatever
  alias the user gave it.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.OAuth.AuthState

  setup do
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      if prev_backend,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
    end)
  end

  test "a denied PostHog MCP authorization renders the PostHog logo" do
    assert {:page, 400, html} = denied_callback("posthog-state", "https://mcp.posthog.com/mcp")
    assert html =~ "posthog-p6"
    refute html =~ ~s(aria-label="MCP")
    assert html =~ "authorization denied: access_denied"
  end

  test "another MCP server keeps the generic MCP logo" do
    assert {:page, 400, html} = denied_callback("other-state", "https://mcp.example.com/mcp")
    assert html =~ ~s(aria-label="MCP")
    refute html =~ "posthog-p6"
  end

  defp denied_callback(state, resource_server_url) do
    :ok =
      AuthState.create(%{
        "state" => state,
        "tenant" => "tenant-1",
        "group_id" => "group-1",
        "provider" => "mcp",
        "provider_kind" => "remote_mcp",
        "alias" => "posthog",
        "scopes" => [],
        "code_verifier" => "v",
        "redirect_uri" => "http://localhost/v1/oauth/mcp/callback",
        "origin" => "mcp",
        "oauth_metadata" => %{"resource_server_url" => resource_server_url}
      })

    Salix.Control.RemoteMCPOAuth.handle_callback(%{"state" => state, "error" => "access_denied"})
  end
end
