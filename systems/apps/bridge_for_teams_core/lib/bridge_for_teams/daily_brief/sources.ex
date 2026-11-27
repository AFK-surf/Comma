defmodule BridgeForTeams.DailyBrief.Sources do
  @moduledoc """
  Picks the daily brief's source and sink adapters by the settings'
  provider, and names a member in the provider's requests. Slack keeps its
  own request keys (`member_slack_ids`, `slack_user_id`, `slack_user_ids`);
  Feishu and Lark name people by open id. Each adapter knows only its own
  provider.
  """

  alias BridgeForTeams.DailyBrief.{ActorRef, Members, Sinks}
  alias BridgeForTeams.DailyBrief.Sources.{Feishu, Lark, Slack}
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting}

  @doc "The source adapter of the settings' (or source's) provider."
  @spec adapter(DailyBriefSetting.t() | map() | String.t() | nil) :: module()
  def adapter(%DailyBriefSetting{} = settings), do: adapter(Members.provider(settings))
  def adapter(%{provider: provider}), do: adapter(provider)
  def adapter("feishu"), do: Feishu
  def adapter("lark"), do: Lark
  def adapter(_slack), do: Slack

  @doc "The sink adapter of the settings' provider."
  @spec sink(DailyBriefSetting.t()) :: module()
  def sink(%DailyBriefSetting{} = settings) do
    case Members.provider(settings) do
      "feishu" -> Sinks.Feishu
      "lark" -> Sinks.Lark
      _slack -> Sinks.Slack
    end
  end

  @doc "Whether the settings read Slack."
  @spec slack?(DailyBriefSetting.t() | map()) :: boolean()
  def slack?(%DailyBriefSetting{} = settings), do: Members.provider(settings) == "slack"
  def slack?(%{provider: provider}), do: provider not in ["feishu", "lark"]
  def slack?(_source), do: true

  @doc "The channel-list request: the bot's readable channels and no member's gap."
  @spec channels_request(map()) :: map()
  def channels_request(source) do
    if slack?(source),
      do: Map.put(source, :member_slack_ids, []),
      else: Map.put(source, :member_open_ids, [])
  end

  @doc """
  The thread-participation request of one member. `app_id` is the Feishu or
  Lark app the source reads through: the member is named by their open id
  there.
  """
  @spec threads_request(map(), DailyBriefMember.t(), [map()], String.t() | nil) :: map()
  def threads_request(source, member, threads, app_id \\ nil) do
    key = if slack?(source), do: :slack_user_id, else: :open_id
    Map.merge(source, %{key => ActorRef.member_actor_id(member, app_id), threads: threads})
  end

  @doc """
  The channel-activity request of `members`, named as the source's app
  (`app_id`) knows them; a member that app does not know is left out.
  """
  @spec active_request(
          map(),
          [DailyBriefMember.t()],
          [String.t()],
          non_neg_integer(),
          String.t() | nil
        ) :: map()
  def active_request(source, members, channel_ids, after_us, app_id \\ nil) do
    key = if slack?(source), do: :slack_user_ids, else: :open_ids

    Map.merge(source, %{
      key =>
        members
        |> Enum.map(&ActorRef.member_actor_id(&1, app_id))
        |> Enum.reject(&is_nil/1),
      channel_ids: channel_ids,
      after_us: after_us
    })
  end

  @doc """
  The request that posts one member's brief: Slack's text and blocks to the
  Slack user, or the card to the member's open id.
  """
  @spec personal_post(map(), DailyBriefMember.t(), map(), String.t() | nil) :: map()
  def personal_post(source, %DailyBriefMember{} = member, content, app_id \\ nil) do
    if slack?(source) do
      Map.merge(source, %{
        slack_user_id: member.slack_user_id,
        text: content.text,
        blocks: content.blocks
      })
    else
      target_app = app_id || source[:app_id]
      open_id = ActorRef.member_actor_id(member, target_app) || member.open_id
      Map.merge(source, %{open_id: open_id, card: content.card})
    end
  end

  @doc "The request that posts the team brief to the team's channel or group."
  @spec team_post(map(), String.t(), map()) :: map()
  def team_post(source, channel_id, content) do
    if slack?(source),
      do:
        Map.merge(source, %{channel_id: channel_id, text: content.text, blocks: content.blocks}),
      else: Map.merge(source, %{channel_id: channel_id, card: content.card})
  end
end
