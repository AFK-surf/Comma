defmodule SalixIM.ProviderConversationInput do
  @moduledoc """
  Provider-neutral preparation for conversation ingress.

  This module shapes provider participants and stages inbound attachments. It
  owns no conversation state; aggregate mutations still enter through
  `SalixIM.ConversationServer`.
  """

  alias SalixIM.{ProviderAttachments, ProviderRecipientIdentity}
  alias SalixStore.Crypto

  @spec participant_attrs(map()) :: {:ok, map()} | {:error, term()}
  def participant_attrs(attrs) when is_map(attrs) do
    metadata = attrs |> string_keys() |> Map.get("metadata", %{}) |> string_keys()

    with {:ok, target} <- provider_target(metadata) do
      {:ok, provider_participant(target, %{"role_label" => "provider_inbound"})}
    end
  end

  def provider_participant(target, attrs \\ %{}) when is_map(target) and is_map(attrs) do
    payload = Map.merge(target, attrs["payload"] || %{})

    %{
      "actor_type" => "provider",
      "provider" => target["provider"],
      "target_key" => target_key(target),
      "state" => "active",
      "notification_filter" => %{"messages" => "none", "statuses" => "none"},
      "payload" => payload
    }
    |> Map.merge(Map.delete(attrs, "payload"))
  end

  @spec prepare_attachments(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def prepare_attachments(agent_id, attrs) when is_map(attrs) do
    attrs = string_keys(attrs)
    attachments = List.wrap(attrs["attachments"] || [])

    with {:ok, prepared_attachments, failed_attachments} <-
           ProviderAttachments.prepare(agent_id, attachments) do
      {:ok,
       attrs
       |> Map.delete("attachments")
       |> Map.put("prepared_attachments", prepared_attachments)
       |> Map.put("failed_attachments", failed_attachments)}
    end
  end

  @spec provider_message_attrs(map(), String.t(), String.t(), list(), list()) ::
          {:ok, map()} | {:error, term()}
  def provider_message_attrs(
        attrs,
        provider_participant_id,
        router_participant_id,
        staged_attachments,
        publish_failures
      )
      when is_map(attrs) and is_list(staged_attachments) and is_list(publish_failures) do
    metadata = attrs |> Map.get("metadata", %{}) |> string_keys()
    sender_id = provider_sender_id(metadata)

    message =
      %{
        "kind" => "message",
        "participant_id" => provider_participant_id,
        "actor_type" => if(is_nil(sender_id), do: "provider_system", else: "provider_user"),
        "provider" => metadata["provider"],
        "user_id" => sender_id,
        "user_name" => provider_sender_name(metadata),
        "content" =>
          content_with_attachments(
            staged_attachments,
            attrs["content"],
            List.wrap(attrs["failed_attachments"]) ++ publish_failures
          ),
        "metadata" => metadata,
        "source_message_id" => attrs["source_message_id"],
        "delivery_filter" => %{"participant_ids" => [router_participant_id]},
        "created_at" => attrs["created_at"]
      }
      |> strip_empty_values()
      |> ProviderRecipientIdentity.mark_trusted_provider_message()

    {:ok, message}
  end

  @spec stage_worker_attachments(String.t(), list()) :: {:ok, list(), list()}
  def stage_worker_attachments(agent_id, attachments) when is_list(attachments),
    do: ProviderAttachments.stage(agent_id, attachments)

  @spec publish_worker_attachments(String.t(), list()) :: {:ok, list(), list()}
  def publish_worker_attachments(agent_id, prepared_attachments)
      when is_list(prepared_attachments),
      do: ProviderAttachments.publish(agent_id, prepared_attachments)

  @spec content_with_attachments(list(), term(), list()) :: list()
  def content_with_attachments([], content, []), do: normalize_content_blocks(content)

  def content_with_attachments(attachments, content, failed_attachments) do
    normalize_content_blocks(content) ++
      Enum.map(attachments, &attachment_content_block/1) ++
      attachment_failure_blocks(failed_attachments)
  end

  def target_key(target) when is_map(target),
    do: Crypto.hex(:erlang.term_to_binary(target, [:deterministic]))

  defp provider_target(metadata) do
    provider = trim(metadata["provider"])
    connect_id = trim(metadata["connect_id"])

    with :ok <- require_nonblank(provider, "metadata.provider"),
         :ok <- require_nonblank(connect_id, "metadata.connect_id") do
      endpoint =
        metadata
        |> Map.take(
          ~w(workspace_id channel_id thread_ts chat_id chat_type message_thread_id root_message_id trigger_message_id wechat_id tenant_key)
        )
        |> Enum.reject(fn {_key, value} -> trim(value) == "" end)
        |> Map.new()
        |> maybe_put_mentions(metadata)

      {:ok,
       endpoint
       |> Map.put("provider", provider)
       |> Map.put("connect_id", connect_id)}
    end
  end

  defp maybe_put_mentions(endpoint, metadata) do
    case metadata["mentions"] do
      %{"mode" => mode, "users" => users} = mentions
      when mode in ["none", "users", "all"] and is_list(users) ->
        Map.put(endpoint, "mentions", mentions)

      _ ->
        endpoint
    end
  end

  defp provider_sender_id(metadata),
    do:
      Enum.find_value(~w(user_id from_user_id sender_open_id sender_user_id wechat_id), fn key ->
        case trim(metadata[key]) do
          "" -> nil
          value -> value
        end
      end)

  defp provider_sender_name(metadata),
    do:
      Enum.find_value(
        ~w(user_display_name user_real_name user_name from_username sender_name),
        fn key ->
          case trim(metadata[key]) do
            "" -> nil
            value -> value
          end
        end
      )

  defp normalize_content_blocks(content) when is_binary(content) do
    case trim(content) do
      "" -> []
      text -> [%{"type" => "text", "text" => text}]
    end
  end

  defp normalize_content_blocks(content) when is_list(content), do: content
  defp normalize_content_blocks(content) when is_map(content), do: [content]
  defp normalize_content_blocks(_content), do: []

  defp attachment_failure_blocks([]), do: []

  defp attachment_failure_blocks(failed_attachments) do
    failures =
      Enum.map(failed_attachments, fn attachment ->
        %{
          "provider" => nonblank(attachment["provider"], "provider"),
          "path" => attachment["path"],
          "file_name" => attachment["file_name"],
          "reason" => nonblank(attachment["stage_error"], "download_failed")
        }
        |> strip_empty_values()
      end)

    [
      %{
        "type" => "text",
        "text" =>
          "Provider attachment staging error: " <>
            Jason.encode!(%{
              "type" => "provider_attachment_error",
              "failures" => failures
            })
      }
    ]
  end

  defp attachment_content_block(att) do
    path = trim(att["path"])
    file_name = nonblank(att["file_name"], Path.basename(path))
    mime = trim(att["mime"])

    case SalixIM.AttachmentMedia.native_image_mime(mime, file_name || path) do
      {:ok, image_mime} ->
        %{
          "type" => "image",
          "file_ref" => %{"environment_id" => "vfs", "path" => path},
          "file_name" => file_name,
          "mime_type" => image_mime,
          "size" => att["size"]
        }
        |> strip_empty_values()

      :error ->
        %{
          "type" => "file",
          "path" => path,
          "file_name" => file_name,
          "title" => file_name,
          "mime_type" => mime,
          "size" => att["size"]
        }
        |> strip_empty_values()
    end
  end

  defp require_nonblank(value, field) do
    if trim(value) == "", do: {:error, {:bad_request, "#{field} is required"}}, else: :ok
  end

  defp nonblank(value, fallback) do
    case trim(value) do
      "" -> fallback
      present -> present
    end
  end

  defp strip_empty_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp string_keys(_value), do: %{}

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
