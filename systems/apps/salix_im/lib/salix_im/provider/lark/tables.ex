defmodule SalixIM.Provider.Lark.Tables do
  @moduledoc """
  Lark Base and spreadsheet reads through the connect's own app, or as a
  signed-in person: `SalixIM.Provider.CloudTables` bound to the Lark API and
  the Lark document resolver, which labels each read by the table's audience.
  """

  alias SalixIM.Provider.CloudTables
  alias SalixIM.Provider.Lark.{API, Docs}

  @binding %{
    api: API,
    docs: Docs,
    prefix: "lark",
    product: "Lark",
    host?: &Docs.lark_host?/1,
    other_product: "Feishu",
    other_host?: &Docs.feishu_host?/1
  }

  @doc "The operation names this module answers."
  @spec api_names() :: [String.t()]
  def api_names, do: CloudTables.api_names("lark")

  @spec call(String.t(), map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def call(agent_id, connect, api, params),
    do: CloudTables.call(@binding, agent_id, connect, api, params)
end
