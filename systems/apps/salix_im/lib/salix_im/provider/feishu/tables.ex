defmodule SalixIM.Provider.Feishu.Tables do
  @moduledoc """
  Feishu Base (多维表格) and spreadsheet reads through the connect's own
  tenant app, or as a signed-in person: `SalixIM.Provider.CloudTables` bound
  to the Feishu API and the Feishu document resolver, which labels each read
  by the table's audience.
  """

  alias SalixIM.Provider.CloudTables
  alias SalixIM.Provider.Feishu.{API, Docs}
  alias SalixIM.Provider.Lark.Docs, as: LarkDocs

  @binding %{
    api: API,
    docs: Docs,
    prefix: "feishu",
    product: "Feishu",
    host?: &LarkDocs.feishu_host?/1,
    other_product: "Lark international",
    other_host?: &LarkDocs.lark_host?/1
  }

  @doc "The operation names this module answers."
  @spec api_names() :: [String.t()]
  def api_names, do: CloudTables.api_names("feishu")

  @spec call(String.t(), map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def call(agent_id, connect, api, params),
    do: CloudTables.call(@binding, agent_id, connect, api, params)
end
