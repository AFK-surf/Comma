defmodule SalixIM.Provider.QQ.Groups do
  @moduledoc """
  The QQ group reads: what a group is and who is in it.

  Every operation names its group as `group:<group_openid>`, and defaults to
  the group of the current QQ source. A member is named by the OpenID QQ gives
  that member for this bot.

  QQ opens the member list and one member only to bots it put on an allowlist;
  any other bot gets error 11253, and the result says who can lift it.

  What a group admin does (mutes, removal, the blacklist, requests to join) is
  not here.
  """

  import SalixIM.Provider.Util

  alias SalixIM.IFC.ReadLabels
  alias SalixIM.Provider.QQ.API
  alias SalixIM.ProviderObservations

  @ops ~w(qq.get_group_info qq.list_members qq.get_member)

  # QQ has not put this bot on the allowlist of the method.
  @not_allowlisted 11_253

  @doc "The QQ group operation names."
  def operations, do: @ops

  # A read of a group is labelled by that group.
  @spec call(String.t(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def call(api, connect, params, origin) when api in @ops and is_map(connect) do
    with {:ok, group} <- group(params["chat_id"], origin),
         {:ok, result} <- api |> operation(connect, group, params) |> error_text() do
      chat_id = "group:" <> group

      {:ok,
       result
       |> Map.put("chat_id", chat_id)
       |> put_ifc(ReadLabels.for_scope(connect, chat_id))}
    end
  end

  # The two halves answer separately, so a bot QQ lets read only one of them
  # still gets that one.
  defp operation("qq.get_group_info", connect, group, _params) do
    base = "/v2/groups/" <> group
    info = API.request(connect, :get, base <> "/info")
    state = API.request(connect, :get, base <> "/bot_state")

    case {info, state} do
      {{:error, _reason} = error, {:error, _other}} ->
        error

      _one_answered ->
        remember_name(connect, group, info)

        {:ok,
         %{}
         |> merge(info, %{
           "group_name" => "name",
           "group_finger_memo" => "description",
           "group_class_text" => "category",
           "group_tags" => "tags",
           "group_member_num" => "member_count"
         })
         |> merge(state, %{
           "member_openid" => "bot_member_id",
           "member_role" => "bot_role",
           "joined_at" => "bot_joined_at",
           "allow_proactive_msg" => "proactive",
           "recv_msg_setting" => "bot_reads"
         })}
    end
  end

  defp operation("qq.list_members", connect, group, params) do
    with {:ok, body} <-
           API.request(connect, :get, "/v2/groups/#{group}/members",
             params: [cursor: str(params["cursor"])]
           ) do
      {:ok,
       %{
         "members" =>
           body["members"] |> List.wrap() |> Enum.filter(&is_map/1) |> Enum.map(&member/1),
         "next_cursor" => str(body["next_cursor"])
       }}
    end
  end

  defp operation("qq.get_member", connect, group, params) do
    member_id = str(params["member_id"])

    with true <- openid?(member_id) || {:error, "member_id must be a member's OpenID"},
         {:ok, body} <- API.request(connect, :get, "/v2/groups/#{group}/members/#{member_id}") do
      {:ok, %{"member" => member(body)}}
    end
  end

  # `qq.list_chats` then shows the group by its name.
  defp remember_name(connect, group, {:ok, %{"group_name" => name}})
       when is_binary(name) and name != "" do
    _ = ProviderObservations.note_qq_chat(connect, "group:" <> group, "group", %{"name" => name})
    :ok
  end

  defp remember_name(_connect, _group, _info), do: :ok

  defp member(member) when is_map(member) do
    %{}
    |> maybe_put("member_id", str(member["member_openid"]))
    |> maybe_put("name", str(member["username"]))
    |> maybe_put("role", str(member["member_role"]))
    |> maybe_put("bot", if(member["bot"] == true, do: true))
    |> maybe_put("joined_at", str(member["joined_at"]))
    |> maybe_put("union_id", str(member["union_openid"]))
  end

  defp merge(result, {:ok, body}, names) do
    Enum.reduce(names, result, fn {from, to}, result ->
      case body[from] do
        value when value in [nil, "", []] -> result
        value -> Map.put(result, to, value)
      end
    end)
  end

  defp merge(result, {:error, _reason}, _names), do: result

  defp group(value, origin) do
    chat_id =
      case str(value) do
        "" -> str(origin["chat_id"])
        chat_id -> chat_id
      end

    case chat_id do
      "group:" <> openid ->
        if openid?(openid),
          do: {:ok, openid},
          else: {:error, "chat_id must be group:<group_openid>"}

      "" ->
        {:error, "chat_id is required outside a QQ group source"}

      _other ->
        {:error, "chat_id must be group:<group_openid>"}
    end
  end

  defp openid?(id), do: Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id)

  defp error_text({:error, {:qq_api, _status, @not_allowlisted, _message}}) do
    {:error,
     "QQ has not opened this method to this bot (error 11253). It is open only to bots on QQ's allowlist; " <>
       "the bot's owner can ask the QQ open platform to add it."}
  end

  defp error_text({:error, %{"error_class" => _class}} = unknown), do: unknown
  defp error_text({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp error_text({:error, reason}), do: {:error, API.error_text(reason)}
  defp error_text(result), do: result

  defp put_ifc(result, nil), do: result
  defp put_ifc(result, ifc), do: Map.put(result, "__ifc__", ifc)
end
