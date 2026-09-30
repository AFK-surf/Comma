defmodule BridgeForTeamsWeb.Dashboard.ErrorHTML do
  @moduledoc """
  Renders dashboard HTTP error pages. Falls back to the status phrase
  ("Not Found", "Internal Server Error") for any template name.
  """
  use BridgeForTeamsWeb.Dashboard, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
