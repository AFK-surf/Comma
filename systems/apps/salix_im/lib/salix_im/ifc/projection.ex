defmodule SalixIM.IFC.Projection do
  @moduledoc """
  What a provider conversation is, and who is in it
  (`docs/verification.md` §3.2, §8).

  Postgres holds the answer; the provider is the source. A lookup reads the
  stored projection first and asks the provider only when the answer is
  missing or older than its bound — at most one `conversations.info` and one
  `conversations.members` per channel per quarter hour, and only for the
  channels a decision actually touches.

  Staleness is not a rounding error here. A member set that still lists
  someone who left would make that person a reader, and a channel converted
  from public to private would keep being labelled workspace-wide, so both
  facts share the same short bound: past it they read as *unknown* and the
  kernel denies rather than guesses. It is also why a membership page that
  hits the API limit is never marked complete.

  Nothing in this module compares labels or decides anything. It produces
  facts.
  """

  require Logger

  alias SalixIM.Provider.Feishu.API, as: FeishuAPI
  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixIM.ProviderConnects
  alias SalixIM.ProviderObservations
  alias SalixStore.IFC, as: Store

  @ttl_ms 15 * 60 * 1000
  @member_page_limit 1000

  @type scope :: %{tenant_id: String.t(), group_id: String.t(), connect_id: String.t()}

  @doc """
  Structure and operator classification of one conversation, without touching
  membership. This is the ingress path: it must be cheap and it must not
  depend on who is asking.

  Returns `{canonical_scope_id, facts}`; see `direct_scope_id/1` for why the
  id can differ from the one asked for.
  """
  @spec structure(scope(), String.t()) :: {String.t(), map()}
  def structure(scope, scope_id), do: lookup(scope, scope_id, false)

  @doc """
  Everything the kernel may need about one conversation, membership included.
  """
  @spec facts(scope(), String.t()) :: {String.t(), map()}
  def facts(scope, scope_id), do: lookup(scope, scope_id, true)

  @doc """
  The canonical scope id of a one-to-one conversation with a provider user.

  A DM is named by its counterpart rather than by the channel the provider
  opened, so that the message someone sends the bot and the message the bot
  sends back land on the same audience atom. Without this the two directions
  of one DM would be two incomparable atoms and nothing could flow between
  them.
  """
  @spec direct_scope_id(String.t()) :: String.t()
  def direct_scope_id(user_id), do: "@" <> to_string(user_id)

  @doc "True when a scope id already names a one-to-one conversation."
  @spec direct_scope_id?(String.t()) :: boolean()
  def direct_scope_id?(scope_id), do: String.starts_with?(to_string(scope_id), "@")

  @doc """
  The conversation one message belongs to, or `""` when it cannot be placed.

  A reply and an edit address a message, not a place, but the audience is the
  place: replying to a message in a private chat publishes into that chat.
  Resolving the message is therefore part of resolving the destination, and a
  message nobody can place leaves the scope empty — which the resolver turns
  into a public destination with unknown writers, so the effect is refused
  rather than guessed at.
  """
  @spec message_scope_id(scope(), String.t()) :: String.t()
  def message_scope_id(scope, message_id) do
    with true <- is_binary(message_id) and message_id != "",
         {:ok, connect} <- connect(scope),
         "feishu" <- to_string(connect["provider"]),
         chat_id when is_binary(chat_id) and chat_id != "" <-
           feishu_message_chat(connect, message_id) do
      chat_id
    else
      _unplaceable -> ""
    end
  rescue
    exception ->
      Logger.debug("ifc: message scope lookup failed: #{Exception.message(exception)}")
      ""
  catch
    _kind, _reason -> ""
  end

  defp feishu_message_chat(connect, message_id) do
    params = %{card_msg_content_type: "raw_card_content"}

    case FeishuAPI.get(connect, "/im/v1/messages/#{URI.encode(message_id)}", params) do
      {:ok, %{"items" => [%{"chat_id" => chat_id} | _rest]}} -> to_string(chat_id)
      {:ok, %{"chat_id" => chat_id}} -> to_string(chat_id)
      _other -> ""
    end
  end

  @doc """
  Records that a provider conversation id names a one-to-one conversation with
  one person, from an inbound that carried both.

  Some providers do not say who a one-to-one conversation is with when asked
  about it directly — a Feishu `p2p` chat payload names neither participant —
  but every inbound from it carries the sender's id next to the chat id. Saving
  the pair here is what lets a later read or write that names only the chat id
  resolve to the same audience atom as the message that arrived from it.

  Only ever narrows: writing the same pair again is a no-op, and a chat already
  known as something other than a one-to-one is left alone.
  """
  @spec observe_direct(scope(), String.t(), String.t()) :: :ok
  def observe_direct(scope, scope_id, counterpart)
      when is_binary(scope_id) and is_binary(counterpart) do
    canonical = direct_scope_id(counterpart)

    if scope_id != "" and counterpart != "" and scope_id != canonical do
      row = stored_row(scope, scope_id)

      if row.canonical_scope_id != canonical do
        Store.observe_scope(scope.tenant_id, scope.group_id, scope.connect_id, scope_id, %{
          kind: "direct",
          within: space_atom(scope.connect_id),
          display_name: "私聊",
          canonical_scope_id: canonical
        })
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  def observe_direct(_scope, _scope_id, _counterpart), do: :ok

  @doc """
  Records a member joining, from a provider event. A join never makes an
  unknown member set complete: knowing one member is not knowing all of them.

  Applied only to a conversation the projection already knows, so a workspace
  that never turned this on writes nothing at all. Nothing is lost by that:
  the member set is re-enumerated from the provider the first time a decision
  needs it, and these events keep it fresh in between.
  """
  @spec observe_join(scope(), String.t(), String.t()) :: :ok
  def observe_join(scope, scope_id, user_id) do
    if known?(scope, scope_id) do
      Store.add_scope_member(scope.tenant_id, scope.group_id, scope.connect_id, scope_id, user_id)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "Records a member leaving, from a provider event."
  @spec observe_leave(scope(), String.t(), String.t()) :: :ok
  def observe_leave(scope, scope_id, user_id) do
    if known?(scope, scope_id) do
      Store.remove_scope_member(
        scope.tenant_id,
        scope.group_id,
        scope.connect_id,
        scope_id,
        user_id
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp known?(scope, scope_id) do
    case Store.scopes(scope.tenant_id, scope.group_id, scope.connect_id, [scope_id]) do
      {:ok, scopes} -> Map.has_key?(scopes, scope_id)
      _other -> false
    end
  end

  @doc """
  The placement of one provider user in its connect's space: an operator
  override if there is one, otherwise what the provider's own flags say.

  A user nobody has placed is `:unknown`, which the kernel never reads as
  internal.
  """
  @spec placement(scope(), String.t(), map()) :: :internal | :external | :unknown
  def placement(scope, user_id, provider_user \\ %{}) do
    case Store.placement_overrides(scope.tenant_id, scope.group_id, scope.connect_id, [user_id]) do
      {:ok, %{^user_id => "internal"}} -> :internal
      {:ok, %{^user_id => "external"}} -> :external
      _other -> provider_placement(provider_user)
    end
  rescue
    _ -> :unknown
  end

  @doc """
  Placement derived from a Slack `users.info` payload. Guests, single-channel
  guests, and members of another workspace are external; anyone else the
  provider positively describes is internal.
  """
  @spec provider_placement(map()) :: :internal | :external | :unknown
  def provider_placement(user) when is_map(user) do
    cond do
      user["is_restricted"] == true -> :external
      user["is_ultra_restricted"] == true -> :external
      user["is_stranger"] == true -> :external
      is_binary(user["id"]) and user["id"] != "" -> :internal
      true -> :unknown
    end
  end

  def provider_placement(_user), do: :unknown

  @doc """
  True when a room's content is its whole space rather than an audience of its
  own (`docs/verification.md` §3.2, §10).

  A public room over-approximates to the space: any full member may join it,
  which is the same over-approximation the provider makes when someone invites
  a guest in. An operator who needs the exact member set switches the room to
  `members` audience mode.

  A **sealed** room never over-approximates, whatever its kind. Sealing is a
  restriction attached to that room, and the space atom is not a room — it
  resolves to no row, so `SalixIM.IFC.Facts.policy/2` would find no sealed
  restriction to give the kernel. Collapsing a sealed public channel into its
  space would therefore store and display the operator's choice while
  supplying nothing, and a receipt would still authorize public egress out of
  a channel marked never to leave.
  """
  @spec space_audience?(map()) :: boolean()
  def space_audience?(row) when is_map(row) do
    Map.get(row, :kind) == "public" and Map.get(row, :audience_mode) != "members" and
      Map.get(row, :sealed, false) != true
  end

  def space_audience?(_row), do: false

  @doc "The tags an operator classified a room with, and whether it is sealed."
  @spec classification(scope(), String.t()) :: %{tags: [String.t()], sealed: boolean()}
  def classification(scope, scope_id) do
    {_canonical, row} = structure(scope, scope_id)
    %{tags: Map.get(row, :tags, []), sealed: Map.get(row, :sealed, false)}
  end

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  # A DM named by its counterpart needs no provider round trip at all: its
  # audience is that one person, and that is already the answer.
  defp lookup(scope, scope_id, _want_members?) when is_binary(scope_id) do
    if direct_scope_id?(scope_id) do
      {scope_id, direct_row(scope, scope_id)}
    else
      resolve_stored(scope, scope_id, _want_members? = true)
    end
  end

  defp lookup(_scope, scope_id, _want_members?), do: {to_string(scope_id), empty_row()}

  defp direct_row(scope, scope_id) do
    counterpart = String.trim_leading(scope_id, "@")
    classification = stored_row(scope, scope_id)

    %{
      classification
      | kind: "direct",
        within: space_atom(scope.connect_id),
        members: [counterpart],
        display_name: "私聊",
        observed_at_ms: now_ms()
    }
  end

  defp resolve_stored(scope, scope_id, want_members?) do
    row =
      scope
      |> stored_row(scope_id)
      |> expire(now_ms())
      |> refresh_structure(scope, scope_id)

    case row.canonical_scope_id do
      canonical when is_binary(canonical) and canonical != "" and canonical != scope_id ->
        lookup(scope, canonical, want_members?)

      _own ->
        {scope_id, refresh_members(row, scope, scope_id, want_members?)}
    end
  end

  # Past the bound the projection has nothing to say, so it says nothing.
  defp expire(row, now) do
    case row do
      %{observed_at_ms: observed} when is_integer(observed) and now - observed < @ttl_ms ->
        row

      _stale ->
        %{row | kind: nil, members: :unknown}
    end
  end

  defp stored_row(scope, scope_id) do
    case Store.scopes(scope.tenant_id, scope.group_id, scope.connect_id, [scope_id]) do
      {:ok, scopes} -> Map.get(scopes, scope_id, empty_row())
      {:error, _reason} -> empty_row()
    end
  rescue
    _ -> empty_row()
  end

  defp empty_row do
    %{
      kind: nil,
      within: nil,
      canonical_scope_id: nil,
      display_name: nil,
      members: :unknown,
      observed_at_ms: nil,
      revision: 0,
      tags: [],
      audience_mode: "space",
      sealed: false
    }
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp refresh_structure(%{kind: kind} = row, _scope, _scope_id) when is_binary(kind), do: row

  defp refresh_structure(row, scope, scope_id) do
    case provider_structure(scope, scope_id) do
      {:ok, attrs} ->
        Store.observe_scope(scope.tenant_id, scope.group_id, scope.connect_id, scope_id, attrs)

        %{
          row
          | kind: attrs.kind,
            within: attrs.within,
            display_name: attrs.display_name,
            canonical_scope_id: attrs.canonical_scope_id
        }

      :error ->
        row
    end
  end

  defp refresh_members(row, _scope, _scope_id, false), do: row

  defp refresh_members(%{members: members} = row, _scope, _scope_id, true) when is_list(members),
    do: row

  defp refresh_members(row, scope, scope_id, true) do
    case provider_members(scope, scope_id, row.kind) do
      {:ok, members} ->
        Store.replace_scope_members(
          scope.tenant_id,
          scope.group_id,
          scope.connect_id,
          scope_id,
          members
        )

        %{row | members: Enum.sort(members)}

      :error ->
        row
    end
  end

  @doc "The freshness bound both projected facts share."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  defp provider_structure(scope, scope_id) do
    case connect(scope) do
      {:ok, connect} ->
        case to_string(connect["provider"]) do
          "slack" -> slack_structure(scope, connect, scope_id)
          "feishu" -> feishu_structure(scope, connect, scope_id)
          "telegram" -> telegram_structure(scope, connect, scope_id)
          "wechat" -> wechat_structure(scope, connect, scope_id)
          _unsupported -> :error
        end

      _other ->
        :error
    end
  end

  defp slack_structure(scope, connect, scope_id) do
    with %{} = channel <- slack_channel(connect, scope_id),
         kind when is_binary(kind) <- slack_kind(channel) do
      {:ok,
       %{
         kind: kind,
         within: space_atom(scope.connect_id),
         display_name: slack_display_name(kind, channel),
         canonical_scope_id: slack_canonical_id(kind, channel)
       }}
    else
      _other -> :error
    end
  end

  # A Feishu chat says what it is directly: `external` admits members from
  # another tenant, `chat_mode` separates a one-to-one from a group, and
  # `chat_type: "public"` is Feishu's own word for a room anyone in the tenant
  # may find and join — the same over-approximation a Slack public channel gets.
  #
  # A `p2p` chat does not name its counterpart in this payload, so the
  # canonical id comes from `observe_direct/3` at ingress, where the sender's
  # open id and the chat id arrive together. Until an inbound has been seen the
  # chat is its own scope with unknown membership, which flows nowhere.
  defp feishu_structure(scope, connect, chat_id) do
    case feishu_chat(connect, chat_id) do
      %{} = chat ->
        kind = feishu_kind(chat)

        {:ok,
         %{
           kind: kind,
           within: space_atom(scope.connect_id),
           display_name: feishu_display_name(kind, chat),
           canonical_scope_id: nil
         }}

      _other ->
        :error
    end
  end

  @doc false
  @spec feishu_kind(map()) :: String.t()
  def feishu_kind(chat) when is_map(chat) do
    cond do
      chat["external"] == true -> "shared"
      to_string(chat["chat_mode"]) == "p2p" -> "direct"
      to_string(chat["chat_type"]) == "public" -> "public"
      true -> "room"
    end
  end

  defp feishu_display_name("direct", _chat), do: "私聊"

  defp feishu_display_name(_kind, chat) do
    case String.trim(to_string(chat["name"] || "")) do
      "" -> nil
      name -> name
    end
  end

  defp feishu_chat(connect, chat_id) do
    case FeishuAPI.get(connect, "/im/v1/chats/#{URI.encode(to_string(chat_id))}") do
      {:ok, %{} = chat} -> chat
      _other -> nil
    end
  rescue
    exception ->
      Logger.debug("ifc: feishu chat lookup failed: #{Exception.message(exception)}")
      nil
  catch
    _kind, _reason -> nil
  end

  defp feishu_members(connect, chat_id) do
    params = %{member_id_type: "open_id", page_size: @member_page_limit}

    case FeishuAPI.get(connect, "/im/v1/chats/#{URI.encode(to_string(chat_id))}/members", params) do
      {:ok, %{"items" => items} = page} when is_list(items) ->
        # `has_more` says outright that this is not the whole set, and an
        # incomplete member set is not a member set.
        if page["has_more"] == true,
          do: nil,
          else: Enum.flat_map(items, &feishu_member_id/1)

      _other ->
        nil
    end
  rescue
    exception ->
      Logger.debug("ifc: feishu chat members failed: #{Exception.message(exception)}")
      nil
  catch
    _kind, _reason -> nil
  end

  defp feishu_member_id(%{"member_id" => id}) when is_binary(id) and id != "", do: [id]
  defp feishu_member_id(_item), do: []

  # Telegram's structure comes from the observation the connect already writes
  # on every inbound, so this costs no API call. A private chat is named by the
  # user it is with — a Telegram private chat id *is* that user's id — which is
  # also what `telegram.send_message` addresses, so both directions of one
  # conversation land on the same atom.
  defp telegram_structure(scope, connect, chat_id) do
    case ProviderObservations.get_telegram_chat(connect["connect_id"], chat_id) do
      {:ok, %{} = chat} ->
        kind = telegram_kind(chat)

        {:ok,
         %{
           kind: kind,
           within: space_atom(scope.connect_id),
           display_name: telegram_display_name(kind, chat),
           canonical_scope_id: if(kind == "direct", do: direct_scope_id(chat_id))
         }}

      _other ->
        :error
    end
  rescue
    _ -> :error
  end

  @doc false
  @spec telegram_kind(map()) :: String.t()
  def telegram_kind(chat) when is_map(chat) do
    cond do
      to_string(chat["chat_type"]) == "private" -> "direct"
      String.trim(to_string(chat["username"] || "")) != "" -> "public"
      true -> "room"
    end
  end

  defp telegram_display_name("direct", _chat), do: "私聊"

  defp telegram_display_name(_kind, chat) do
    case String.trim(to_string(chat["title"] || "")) do
      "" -> nil
      title -> title
    end
  end

  # A WeChat connect speaks to one person at a time: the scope id is already
  # the counterpart, so the conversation is a direct one and needs no lookup.
  defp wechat_structure(scope, _connect, scope_id) do
    {:ok,
     %{
       kind: "direct",
       within: space_atom(scope.connect_id),
       display_name: "私聊",
       canonical_scope_id: direct_scope_id(scope_id)
     }}
  end

  defp slack_canonical_id("direct", channel) do
    case to_string(channel["user"] || "") do
      "" -> nil
      user -> direct_scope_id(user)
    end
  end

  defp slack_canonical_id(_kind, _channel), do: nil

  # What a person calls this place. A DM has no name of its own, and naming
  # the counterpart would say more than the refusal needs to.
  defp slack_display_name("direct", _channel), do: "私聊"

  defp slack_display_name(_kind, channel) do
    case to_string(channel["name"] || "") do
      "" -> nil
      name -> "#" <> name
    end
  end

  defp provider_members(scope, scope_id, kind) do
    with {:ok, connect} <- connect(scope),
         members when is_list(members) <- members_from(connect, scope_id, kind) do
      # A full page means there may be more, and a partial member set is not
      # a member set: leave it unknown rather than claim completeness.
      if length(members) >= @member_page_limit, do: :error, else: {:ok, members}
    else
      _other -> :error
    end
  end

  defp members_from(connect, scope_id, kind) do
    case to_string(connect["provider"]) do
      "slack" ->
        slack_members(connect, scope_id)

      # Feishu's member list is a group endpoint. A `p2p` chat is named by its
      # counterpart once an inbound has been seen (`observe_direct/3`), and
      # asking for its members would be one failing call per decision until
      # then, so it is not asked.
      "feishu" when kind != "direct" ->
        feishu_members(connect, scope_id)

      # Telegram's Bot API can count a group's members and name its
      # administrators, but it cannot enumerate them, so a group's member set
      # stays unknown and only same-scope and in-place flows are available.
      # WeChat has no membership API at all here.
      _no_enumeration ->
        nil
    end
  end

  defp connect(%{group_id: group_id, connect_id: connect_id}),
    do: ProviderConnects.get_active_connect_by_id(group_id, connect_id)

  defp connect(_scope), do: {:error, :not_found}

  defp slack_channel(connect, channel_id) do
    connect
    |> SlackAPI.installation()
    |> SlackAPI.conversation_info(channel_id)
  rescue
    exception ->
      Logger.debug("ifc: slack conversations.info failed: #{Exception.message(exception)}")
      nil
  catch
    _kind, _reason -> nil
  end

  defp slack_members(connect, channel_id) do
    connect
    |> SlackAPI.installation()
    |> SlackAPI.conversation_members(channel_id, @member_page_limit)
  rescue
    exception ->
      Logger.debug("ifc: slack conversations.members failed: #{Exception.message(exception)}")
      nil
  catch
    _kind, _reason -> nil
  end

  # A Slack Connect channel admits members from outside the workspace, so it
  # is `shared` whatever else it is; a DM or group DM is `direct` or a room
  # of its space; a private channel is a room. A public channel gets no scope
  # of its own unless an operator asked for one — its audience is the space.
  @doc false
  def slack_kind(channel) when is_map(channel) do
    cond do
      channel["is_ext_shared"] == true -> "shared"
      channel["is_shared"] == true -> "shared"
      channel["is_im"] == true -> "direct"
      channel["is_mpim"] == true -> "room"
      channel["is_group"] == true -> "room"
      channel["is_private"] == true -> "room"
      true -> "public"
    end
  end

  def slack_kind(_channel), do: nil

  @doc """
  The Slack `channel_type` an event carries, mapped to the same vocabulary.
  Used at ingress, where a `conversations.info` round trip is not always
  warranted and the event already says what kind of conversation it is.
  """
  @spec event_kind(String.t() | nil) :: String.t() | nil
  def event_kind("im"), do: "direct"
  def event_kind("mpim"), do: "room"
  def event_kind("group"), do: "room"
  def event_kind("channel"), do: "public"
  def event_kind(_other), do: nil

  defp space_atom(connect_id), do: "space|" <> to_string(connect_id)
end
