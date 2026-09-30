defmodule SalixIM.Ports.FeishuDirectDelivery do
  @moduledoc """
  Narrow provider boundary for product-owned Feishu delivery.

  These effects do not belong to a Conversation participant. Their product
  owner supplies a durable `operation_ref`, and Feishu receives a deterministic
  UUID derived from that reference so retrying an ambiguous write does not
  create a second visible message.
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
    Application.get_env(
      :salix_im,
      :feishu_direct_delivery_mod,
      __MODULE__.Production
    )
  end

  defmodule Production do
    @moduledoc false
    @behaviour SalixIM.Ports.FeishuDirectDelivery

    alias SalixIM.Provider.Feishu

    @impl true
    def post_text(connect, target, text, mentions, operation_ref)
        when is_map(connect) and is_map(target) and is_binary(text) do
      with :ok <- required(operation_ref, :operation_ref),
           :ok <- required(target["chat_id"], :chat_id),
           {:ok, mention_params} <- mention_params(mentions) do
        {api, params} = text_target(target, %{"text" => text})

        Feishu.call(nil, connect, api, Map.merge(params, mention_params),
          tool_call_id: operation_ref
        )
      end
    end

    def post_text(_connect, _target, _text, _mentions, _operation_ref),
      do: {:error, :invalid_feishu_direct_text_delivery}

    @impl true
    def post_file(agent_id, connect, target, path, blob_ref, operation_ref)
        when is_binary(agent_id) and is_map(connect) and is_map(target) and is_binary(path) do
      with :ok <- required(agent_id, :agent_id),
           :ok <- required(operation_ref, :operation_ref),
           :ok <- required(target["chat_id"], :chat_id),
           :ok <- required(path, :path) do
        {api, params} =
          file_target(
            target,
            %{"path" => path}
            |> maybe_put("blob_ref", blob_ref)
          )

        Feishu.call(agent_id, connect, api, params, tool_call_id: operation_ref)
      end
    end

    def post_file(_agent_id, _connect, _target, _path, _blob_ref, _operation_ref),
      do: {:error, :invalid_feishu_direct_file_delivery}

    defp text_target(target, params) do
      case reply_message_id(target) do
        "" ->
          {"feishu.send_text",
           Map.merge(params, %{
             "receive_id" => trim(target["chat_id"]),
             "receive_id_type" => "chat_id"
           })}

        message_id ->
          chat_type = chat_type(target)

          reply = %{
            "message_id" => message_id,
            "chat_id" => trim(target["chat_id"]),
            "chat_type" => chat_type,
            "reply_in_thread" => chat_type == "group"
          }

          reply =
            if chat_type == "group",
              do: Map.put(reply, "thread_id", trim(target["message_thread_id"])),
              else: reply

          {"feishu.reply_text", Map.merge(params, reply)}
      end
    end

    defp file_target(target, params) do
      case reply_message_id(target) do
        "" ->
          {"feishu.send_file",
           Map.merge(params, %{
             "receive_id" => trim(target["chat_id"]),
             "receive_id_type" => "chat_id"
           })}

        message_id ->
          chat_type = chat_type(target)

          {"feishu.reply_file",
           Map.merge(params, %{
             "message_id" => message_id,
             "chat_type" => chat_type,
             "reply_in_thread" => chat_type == "group"
           })}
      end
    end

    defp mention_params(nil), do: {:ok, %{}}
    defp mention_params(%{"mode" => "none", "users" => []}), do: {:ok, %{}}
    defp mention_params(%{"mode" => "all"}), do: {:ok, %{"mention_all" => true}}

    defp mention_params(%{"mode" => "users", "users" => users}) when is_list(users) do
      if users != [] and Enum.all?(users, &(is_binary(&1) or is_map(&1))),
        do: {:ok, %{"mentions" => users}},
        else: {:error, :invalid_feishu_delivery_mentions}
    end

    defp mention_params(_mentions), do: {:error, :invalid_feishu_delivery_mentions}

    defp chat_type(%{"chat_type" => "p2p"}), do: "p2p"
    defp chat_type(_target), do: "group"

    defp reply_message_id(target),
      do: trim(target["root_message_id"] || target["trigger_message_id"])

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
