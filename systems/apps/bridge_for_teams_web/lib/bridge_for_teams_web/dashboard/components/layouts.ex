defmodule BridgeForTeamsWeb.Dashboard.Layouts do
  @moduledoc """
  Dashboard layout for the server-rendered pages: the `root/1` HTML document
  (links the built assets). Every dashboard page is the React app, which
  renders its own shell.
  """
  use BridgeForTeamsWeb.Dashboard, :html

  embed_templates("layouts/*")
end
