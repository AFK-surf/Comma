defmodule SalixMCP.ChinaServices do
  @moduledoc """
  Compatibility entry point for the hosted MCP catalog.

  The catalog started with mainland China services. Its declarations now live
  in `SalixMCP.HostedServices`, which also supports optional global services.
  Keep these registration functions for the existing built-in and plugin owners.
  """

  defdelegate mcp_definitions(), to: SalixMCP.HostedServices
  defdelegate plugin_definitions(), to: SalixMCP.HostedServices
end
