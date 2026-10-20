defmodule CommaWeb.SlackWebAPI do
  @moduledoc false

  # The Slack Web API base for managed-token reads. The local OAuth mock
  # overrides it under `:oauth_endpoint_overrides` ("slack" / "api_url"), like
  # the adapter's authorize and token endpoints.
  @default "https://slack.com/api"

  def base_url, do: SalixStore.OAuth.Adapter.endpoint("slack", "api_url", @default)

  def url(method, params \\ [])

  def url(method, []) when is_binary(method), do: base_url() <> "/" <> method

  def url(method, params) when is_binary(method),
    do: base_url() <> "/" <> method <> "?" <> URI.encode_query(params)
end
