defmodule SalixIM.LarkSuiteTriage.Admin do
  @moduledoc """
  The admin reads and writes of Feishu and Lark group triage that BFT calls
  over its Salix seam (`BridgeForTeams.Salix.Client.lark_suite_triage/2`).
  Every request names `tenant_id` and `group_id`; the Group must belong to the
  tenant, and its Router is the Agent a source answers as.

  Message text leaves only through `reveal/1`, which BFT calls after it has
  recorded the access audit.
  """

  alias SalixIM.{GroupDirectory, ProviderConnects}
  alias SalixIM.Provider.{Feishu, Lark}
  alias SalixStore.LarkSuiteTriage, as: Store

  @providers ~w(feishu lark)
  @chat_page_size 100
  @max_chat_pages 3
  @max_new_chats 20
  @chat_id ~r/\Aoc_[A-Za-z0-9_-]{1,125}\z/

  @doc "Calls one admin function by name; an unknown name is refused."
  @spec call(atom(), map()) :: {:ok, term()} | {:error, term()}
  def call(function, request)
      when function in [:overview, :chats, :set_source, :add_chats, :set_chat, :activity, :reveal] and
             is_map(request),
      do: apply(__MODULE__, function, [request])

  def call(_function, _request), do: {:error, :invalid_request}

  @doc "The Group's Feishu and Lark connects with their triage switch and chats."
  def overview(request) do
    with {:ok, group} <- group(request),
         {:ok, connects} <- ProviderConnects.list_group_im_connects(group["group_id"]),
         {:ok, sources} <- Store.list_group_sources(group["tenant_id"], group["group_id"]) do
      by_connect = Map.new(sources, &{{&1.provider, &1.connect_id}, &1})

      {:ok,
       %{
         router_agent_id: group["router_agent_id"],
         connects:
           for connect <- connects,
               connect["provider"] in @providers,
               is_nil(connect["disabled_at"]),
               connect["owner_only"] != true do
             source = by_connect[{connect["provider"], connect["connect_id"]}]

             %{
               connect_id: connect["connect_id"],
               provider: connect["provider"],
               app_name: present(connect["app_name"]) || present(connect["bot_display_name"]),
               enabled:
                 source != nil and source.enabled and
                   source.router_agent_id == group["router_agent_id"],
               chats:
                 for(
                   chat <- (source && source.chats) || [],
                   do: %{chat_id: chat.chat_id, chat_name: chat.chat_name, enabled: chat.enabled}
                 )
             }
           end
       }}
    end
  end

  @doc """
  The group chats the connect's bot is in (at most #{@max_chat_pages * @chat_page_size}),
  or the one chat `chat_id` names, resolved to its name.
  """
  def chats(request) do
    with {:ok, group} <- group(request),
         {:ok, connect} <- connect(group, request) do
      case present(request[:chat_id]) do
        nil -> list_chats(connect)
        chat_id -> one_chat(connect, chat_id)
      end
    end
  end

  @doc "Turns a connect's triage on or off (`enabled`, `updated_by`)."
  def set_source(request) do
    with {:ok, group} <- group(request),
         {:ok, connect} <- connect(group, request),
         true <- is_boolean(request[:enabled]) || {:error, :invalid_request},
         true <- connect["owner_only"] != true || {:error, :owner_only_connect},
         true <-
           (not request[:enabled] or present(connect["bot_open_id"]) != nil) ||
             {:error, :bot_identity_missing},
         {:ok, source} <-
           Store.upsert_source(%{
             tenant_id: group["tenant_id"],
             provider: connect["provider"],
             connect_id: connect["connect_id"],
             group_id: group["group_id"],
             router_agent_id: group["router_agent_id"],
             enabled: request[:enabled],
             updated_by: request[:updated_by]
           }) do
      {:ok, %{enabled: source.enabled}}
    end
  end

  @doc """
  Adds up to #{@max_new_chats} chats (`chats`: `chat_id`, optional
  `chat_name`) to a connect's triage. A chat without a name is read from the
  provider. Answers the chats added and those another Group already watches.
  """
  def add_chats(request) do
    with {:ok, group} <- group(request),
         {:ok, connect} <- connect(group, request),
         {:ok, chats} <- new_chats(request[:chats]),
         {:ok, _source} <- ensure_source(group, connect, request[:updated_by]) do
      results =
        Enum.map(chats, fn chat ->
          name = present(chat[:chat_name]) || chat_name(connect, chat.chat_id)

          Store.add_or_enable_chat(%{
            tenant_id: group["tenant_id"],
            provider: connect["provider"],
            connect_id: connect["connect_id"],
            group_id: group["group_id"],
            chat_id: chat.chat_id,
            chat_name: name || ""
          })
          |> then(&{chat.chat_id, name, &1})
        end)

      {:ok,
       %{
         added: for({id, _name, {:ok, _chat}} <- results, do: id),
         conflicts:
           for(
             {id, name, {:error, {:chat_already_claimed, owner}}} <- results,
             do: %{
               chat_id: id,
               chat_name: name,
               group_id: owner.group_id,
               connect_id: owner.connect_id
             }
           ),
         failed: for({id, _name, {:error, reason}} <- results, not claimed?(reason), do: id)
       }}
    end
  end

  @doc "Pauses or resumes one chat of a connect (`chat_id`, `enabled`)."
  def set_chat(request) do
    with {:ok, group} <- group(request),
         {:ok, connect} <- connect(group, request),
         chat_id when is_binary(chat_id) <-
           present(request[:chat_id]) || {:error, :invalid_request},
         true <- is_boolean(request[:enabled]) || {:error, :invalid_request} do
      case Store.set_chat_enabled(
             group["tenant_id"],
             connect["provider"],
             connect["connect_id"],
             chat_id,
             request[:enabled]
           ) do
        {:ok, chat} ->
          if chat.group_id == group["group_id"],
            do: {:ok, %{chat_id: chat.chat_id, enabled: chat.enabled}},
            else: {:error, :not_found}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "One page of the Router's triage activity, without message text."
  def activity(request) do
    with {:ok, group} <- group(request) do
      Store.list_activity(group["tenant_id"], group["router_agent_id"],
        kind: request[:kind],
        chat_id: request[:chat_id],
        before: request[:before],
        limit: request[:limit] || 20
      )
    end
  end

  @doc "One batch of the Router with its redacted message text (`batch_id`)."
  def reveal(request) do
    with {:ok, group} <- group(request),
         batch_id when is_binary(batch_id) <-
           present(request[:batch_id]) || {:error, :invalid_request},
         {:ok, batch} <-
           Store.get_batch_for_reveal(group["tenant_id"], group["router_agent_id"], batch_id) do
      {:ok,
       %{
         batch_id: batch.id,
         connect_id: batch.connect_id,
         reply_text: batch.reply_text,
         messages:
           Enum.map(batch.messages_json, fn message ->
             %{
               message_id: message["message_id"],
               sender_name: message["sender_name"],
               sent_at_ms: message["sent_at_ms"],
               text: message["text"]
             }
           end)
       }}
    end
  end

  ## Helpers

  defp group(%{tenant_id: tenant_id, group_id: group_id})
       when is_binary(tenant_id) and is_binary(group_id) do
    case GroupDirectory.get_group(group_id) do
      {:ok, %{"tenant_id" => ^tenant_id, "router_agent_id" => router} = group}
      when is_binary(router) and router != "" ->
        {:ok, Map.put(group, "group_id", group_id)}

      {:ok, _other} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp group(_request), do: {:error, :invalid_request}

  defp connect(group, request) do
    with connect_id when is_binary(connect_id) <-
           present(request[:connect_id]) || {:error, :invalid_request},
         {:ok, %{"provider" => provider, "tenant_id" => tenant_id} = connect}
         when provider in @providers <-
           ProviderConnects.get_active_connect_by_id(group["group_id"], connect_id),
         true <- tenant_id == group["tenant_id"] || {:error, :not_found} do
      {:ok, connect}
    else
      {:ok, _other_provider} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_source(group, connect, updated_by) do
    case Store.list_group_sources(group["tenant_id"], group["group_id"]) do
      {:ok, sources} ->
        case Enum.find(
               sources,
               &(&1.provider == connect["provider"] and &1.connect_id == connect["connect_id"])
             ) do
          nil ->
            Store.upsert_source(%{
              tenant_id: group["tenant_id"],
              provider: connect["provider"],
              connect_id: connect["connect_id"],
              group_id: group["group_id"],
              router_agent_id: group["router_agent_id"],
              enabled: false,
              updated_by: updated_by
            })

          source ->
            {:ok, source}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp new_chats(chats) when is_list(chats) do
    chats =
      chats
      |> Enum.flat_map(fn
        %{chat_id: id} = chat when is_binary(id) ->
          if Regex.match?(@chat_id, String.trim(id)),
            do: [%{chat_id: String.trim(id), chat_name: chat[:chat_name]}],
            else: []

        _invalid ->
          []
      end)
      |> Enum.uniq_by(& &1.chat_id)

    if chats != [] and length(chats) <= @max_new_chats,
      do: {:ok, chats},
      else: {:error, :invalid_request}
  end

  defp new_chats(_chats), do: {:error, :invalid_request}

  defp claimed?({:chat_already_claimed, _owner}), do: true
  defp claimed?(_reason), do: false

  defp list_chats(connect) do
    Enum.reduce_while(1..@max_chat_pages, {[], nil}, fn page, {acc, token} ->
      params = if token, do: %{"page_token" => token}, else: %{}

      case provider_call(connect, "list_chats", Map.put(params, "page_size", @chat_page_size)) do
        {:ok, %{"chats" => chats} = data} when is_list(chats) ->
          acc = acc ++ Enum.flat_map(chats, &listed_chat/1)
          next = present(data["next_page_token"])

          cond do
            data["has_more"] != true or is_nil(next) ->
              {:halt, {:ok, %{chats: acc, complete: true}}}

            page == @max_chat_pages ->
              {:halt, {:ok, %{chats: acc, complete: false}}}

            true ->
              {:cont, {acc, next}}
          end

        _error ->
          {:halt, {:error, :provider_unavailable}}
      end
    end)
  end

  # `im/v1/chats` lists group chats only; a dissolved one is left out.
  defp listed_chat(%{"chat_id" => "oc_" <> _ = id} = chat) do
    if chat["chat_status"] in [nil, "normal"],
      do: [%{chat_id: id, chat_name: present(chat["name"]) || ""}],
      else: []
  end

  defp listed_chat(_chat), do: []

  defp one_chat(connect, chat_id) do
    with true <- Regex.match?(@chat_id, chat_id) || {:error, :invalid_request},
         {:ok, %{} = chat} <- provider_call(connect, "get_chat", %{"chat_id" => chat_id}),
         true <- chat["chat_mode"] in [nil, "group", "topic"] || {:error, :not_found} do
      {:ok,
       %{chats: [%{chat_id: chat_id, chat_name: present(chat["name"]) || ""}], complete: true}}
    else
      {:error, _reason} = error -> error
      _unreadable -> {:error, :not_found}
    end
  end

  defp chat_name(connect, chat_id) do
    case provider_call(connect, "get_chat", %{"chat_id" => chat_id}) do
      {:ok, %{"name" => name}} -> present(name)
      _unreadable -> nil
    end
  end

  defp provider_call(%{"provider" => "feishu"} = connect, operation, params),
    do: Feishu.call(nil, connect, "feishu." <> operation, params)

  defp provider_call(%{"provider" => "lark"} = connect, operation, params),
    do: Lark.call(nil, connect, "lark." <> operation, params)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil
end
