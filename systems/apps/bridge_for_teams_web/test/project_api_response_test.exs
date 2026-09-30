defmodule BridgeForTeamsWeb.ProjectAPIResponseTest do
  use ExUnit.Case, async: true

  alias BridgeForTeamsWeb.ProjectAPIResponse

  test "Slack install status requires an OAuth URL before pending OAuth" do
    assert %{"install_status" => "unknown"} =
             ProjectAPIResponse.public_connect(%{
               "connect_id" => "conn_credentials_only",
               "provider" => "slack",
               "client_id" => "123.abc"
             })

    assert %{"install_status" => "pending_oauth"} =
             ProjectAPIResponse.public_connect(%{
               "connect_id" => "conn_oauth",
               "provider" => "slack",
               "oauth_url" => "https://slack.example.test/oauth"
             })
  end
end
