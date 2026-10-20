defmodule SalixIM.Ports.LarkDirectDelivery do
  @moduledoc """
  A Lark message a product sends by itself, without a Conversation
  participant.

  The product gives a durable `operation_ref`. Lark gets a `uuid` made from
  it, so a request that is sent again after an unknown outcome makes no
  second message. Both calls go out through `lark.send_message`.

  `target` names the chat (`chat_id`, `chat_type`) and, to answer in a
  thread, the message to answer (`root_message_id`, or `trigger_message_id`).
  """

  @callback post_text(
              connect :: map(),
              target :: map(),
              text :: String.t(),
              mentions :: map(),
              operation_ref :: String.t()
            ) :: {:ok, map()} | {:error, term()}

  @callback post_file(
              agent_id :: String.t(),
              connect :: map(),
              target :: map(),
              path :: String.t(),
              blob_ref :: map() | nil,
              operation_ref :: String.t()
            ) :: {:ok, map()} | {:error, term()}

  def post_text(connect, target, text, mentions, operation_ref),
    do: impl().post_text(connect, target, text, mentions, operation_ref)

  def post_file(agent_id, connect, target, path, blob_ref, operation_ref),
    do: impl().post_file(agent_id, connect, target, path, blob_ref, operation_ref)

  defp impl do
    SystemsRuntime.get_env(
      :salix_im,
      :lark_direct_delivery_mod,
      __MODULE__.Production
    )
  end

  defmodule Production do
    @moduledoc false
    @behaviour SalixIM.Ports.LarkDirectDelivery

    alias SalixIM.Provider.Lark

    @impl true
    def post_text(connect, target, text, mentions, operation_ref)
        when is_map(connect) and is_map(target) and is_binary(text) do
      with :ok <- required(operation_ref, :operation_ref),
           :ok <- required(target["chat_id"], :chat_id),
           {:ok, mention_params} <- mention_params(mentions) do
        params = target |> target_params() |> Map.merge(mention_params) |> Map.put("text", text)
        Lark.call(nil, connect, "lark.send_message", params, tool_call_id: operation_ref)
      end
    end

    def post_text(_connect, _target, _text, _mentions, _operation_ref),
      do: {:error, :invalid_lark_direct_text_delivery}

    @impl true
    def post_file(agent_id, connect, target, path, blob_ref, operation_ref)
        when is_binary(agent_id) and is_map(connect) and is_map(target) and is_binary(path) do
      with :ok <- required(agent_id, :agent_id),
           :ok <- required(operation_ref, :operation_ref),
           :ok <- required(target["chat_id"], :chat_id),
           :ok <- required(path, :path) do
        params =
          target
          |> target_params()
          |> Map.put("path", path)
          |> maybe_put("blob_ref", blob_ref)

        Lark.call(agent_id, connect, "lark.send_message", params, tool_call_id: operation_ref)
      end
    end

    def post_file(_agent_id, _connect, _target, _path, _blob_ref, _operation_ref),
      do: {:error, :invalid_lark_direct_file_delivery}

    # With a message to answer, the send is a reply to it, and in a group it
    # goes into the thread. Without one it is a new message of the chat.
    defp target_params(target) do
      params = %{"chat_id" => trim(target["chat_id"])}

      case trim(target["root_message_id"] || target["trigger_message_id"]) do
        "" ->
          params

        message_id ->
          Map.merge(params, %{
            "reply_to" => message_id,
            "reply_in_thread" => chat_type(target) == "group"
          })
      end
    end

    defp mention_params(nil), do: {:ok, %{}}
    defp mention_params(%{"mode" => "none", "users" => []}), do: {:ok, %{}}
    defp mention_params(%{"mode" => "all"}), do: {:ok, %{"mention_all" => true}}

    defp mention_params(%{"mode" => "users", "users" => users}) when is_list(users) do
      if users != [] and Enum.all?(users, &(is_binary(&1) or is_map(&1))),
        do: {:ok, %{"mentions" => users}},
        else: {:error, :invalid_lark_delivery_mentions}
    end

    defp mention_params(_mentions), do: {:error, :invalid_lark_delivery_mentions}

    defp chat_type(%{"chat_type" => "p2p"}), do: "p2p"
    defp chat_type(_target), do: "group"

    defp required(value, field) do
      if trim(value) == "", do: {:error, {:missing, field}}, else: :ok
    end

    defp maybe_put(map, _key, value) when value in [nil, %{}], do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)
    defp trim(nil), do: ""
    defp trim(value) when is_binary(value), do: String.trim(value)
    defp trim(value), do: value |> to_string() |> String.trim()
  end
end
