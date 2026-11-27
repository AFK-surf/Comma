defmodule SalixIM.LarkDailyBriefSource do
  @moduledoc """
  Read-only Lark source for the BFT daily brief, the Lark counterpart of
  `SalixIM.DailyBriefSource` with the same functions. Only internal public
  groups the connect's bot is in are readable; message text comes from the
  Lark message mirror. The implementation is `SalixIM.LarkSuiteDailyBrief`.
  """

  alias SalixIM.LarkSuiteDailyBrief, as: Brief

  @doc "The provider this module reads."
  @spec provider() :: Brief.provider()
  def provider do
    %{
      provider: "lark",
      api: SalixIM.Provider.Lark.API,
      reader: &SalixIM.LarkMessageRecord.reader/0,
      ledger: SalixStore.LarkMirrorBackfillLedger,
      applink: "https://applink.larksuite.com",
      default_timezone: "Etc/UTC"
    }
  end

  def channels(request), do: Brief.channels(provider(), request)
  def read_window(request), do: Brief.read_window(provider(), request)
  def messages(request), do: Brief.messages(provider(), request)
  def member_threads(request), do: Brief.member_threads(provider(), request)
  def active_channels(request), do: Brief.active_channels(provider(), request)
  def lookup_members(request), do: Brief.lookup_members(provider(), request)
  def user_names(request), do: Brief.user_names(provider(), request)
  def permalinks(request), do: Brief.permalinks(provider(), request)
end
