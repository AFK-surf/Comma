defmodule BridgeForTeams.DailyBrief.ActorRef do
  @moduledoc """
  A person or bot in daily brief rows, qualified by its source:
  `"slack:U123"`, `"feishu:ou_123"`, `"lark:ou_123"`. Only a source adapter
  builds or reads the part after the source; the core compares refs as
  opaque strings. A Feishu or Lark open id is scoped to its app, so the two
  sources never share a ref.
  """

  alias BridgeForTeams.Schema.DailyBriefMember

  @type t :: String.t()

  @doc "The ref of a Slack user or bot id, or `nil`."
  @spec slack(String.t() | nil) :: t() | nil
  def slack(id) when is_binary(id) and id != "", do: "slack:" <> id
  def slack(_id), do: nil

  @doc "The Slack id of a Slack ref, or `nil` for another source."
  @spec slack_id(t() | nil) :: String.t() | nil
  def slack_id("slack:" <> id) when id != "", do: id
  def slack_id(_ref), do: nil

  @doc "The ref of a Feishu open id, or `nil`."
  @spec feishu(String.t() | nil) :: t() | nil
  def feishu(id) when is_binary(id) and id != "", do: "feishu:" <> id
  def feishu(_id), do: nil

  @doc "The open id of a Feishu ref, or `nil` for another source."
  @spec feishu_id(t() | nil) :: String.t() | nil
  def feishu_id("feishu:" <> id) when id != "", do: id
  def feishu_id(_ref), do: nil

  @doc "The ref of a Lark open id, or `nil`."
  @spec lark(String.t() | nil) :: t() | nil
  def lark(id) when is_binary(id) and id != "", do: "lark:" <> id
  def lark(_id), do: nil

  @doc "The open id of a Lark ref, or `nil` for another source."
  @spec lark_id(t() | nil) :: String.t() | nil
  def lark_id("lark:" <> id) when id != "", do: id
  def lark_id(_ref), do: nil

  @doc "The ref of `id` in `provider`'s source."
  @spec of(String.t() | nil, String.t() | nil) :: t() | nil
  def of("feishu", id), do: feishu(id)
  def of("lark", id), do: lark(id)
  def of(_slack, id), do: slack(id)

  @doc "The provider id of a ref of `provider`'s source, or `nil`."
  @spec id_of(String.t() | nil, t() | nil) :: String.t() | nil
  def id_of("feishu", ref), do: feishu_id(ref)
  def id_of("lark", ref), do: lark_id(ref)
  def id_of(_slack, ref), do: slack_id(ref)

  @doc "The provider user id a member reads for: a Slack user id or an open id."
  @spec member_actor_id(DailyBriefMember.t() | map()) :: String.t() | nil
  def member_actor_id(%{provider: provider, open_id: open_id})
      when provider in ["feishu", "lark"],
      do: open_id

  def member_actor_id(%{slack_user_id: id}), do: id
  def member_actor_id(_member), do: nil

  @doc """
  The member's id as one Feishu or Lark app knows them (`app_id`), or `nil`
  when they were never linked through that app: an open id is scoped to its
  app. A Slack member, or no app (`nil`), gives `member_actor_id/1`.
  """
  @spec member_actor_id(DailyBriefMember.t() | map(), String.t() | nil) :: String.t() | nil
  def member_actor_id(%{provider: provider} = member, app_id)
      when provider in ["feishu", "lark"] and is_binary(app_id) do
    Map.get(Map.get(member, :app_open_ids) || %{}, app_id) ||
      if(Map.get(member, :app_id) == app_id, do: Map.get(member, :open_id))
  end

  def member_actor_id(member, _app_id), do: member_actor_id(member)

  @doc "The member's own ref."
  @spec member_ref(DailyBriefMember.t() | map()) :: t() | nil
  def member_ref(member), do: of(Map.get(member, :provider), member_actor_id(member))

  @doc """
  The member's ref in one app (`app_id`), else their own ref: the ref a
  brief sent through that app's bot names them by.
  """
  @spec member_ref(DailyBriefMember.t() | map(), String.t() | nil) :: t() | nil
  def member_ref(member, app_id),
    do: of(Map.get(member, :provider), member_actor_id(member, app_id) || member_actor_id(member))

  @doc "Every ref of the member: their own, then their open id in each other app."
  @spec member_all_refs(DailyBriefMember.t() | map()) :: [t()]
  def member_all_refs(member) do
    provider = Map.get(member, :provider)

    others =
      if provider in ["feishu", "lark"],
        do: (Map.get(member, :app_open_ids) || %{}) |> Map.values() |> Enum.sort(),
        else: []

    [member_ref(member) | Enum.map(others, &of(provider, &1))]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
