defmodule SalixIM.FeishuDailyBriefSource do
  @moduledoc """
  Read-only Feishu source for the BFT daily brief, the Feishu counterpart of
  `SalixIM.DailyBriefSource` with the same functions. Only internal public
  groups the connect's bot is in are readable; message text comes from the
  Feishu message mirror. The implementation is `SalixIM.LarkSuiteDailyBrief`.
  """

  alias SalixIM.LarkSuiteDailyBrief, as: Brief

  @doc "The provider this module reads."
  @spec provider() :: Brief.provider()
  def provider do
    %{
      provider: "feishu",
      api: SalixIM.Provider.Feishu.API,
      reader: fn ->
        if SalixIM.FeishuMessageMirror.enabled?(),
          do: SystemsRuntime.get_env(:salix_im, :feishu_mirror_reader_mod)
      end,
      ledger: SalixStore.FeishuMirrorBackfillLedger,
      applink: "https://applink.feishu.cn",
      default_timezone: "Asia/Shanghai"
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
