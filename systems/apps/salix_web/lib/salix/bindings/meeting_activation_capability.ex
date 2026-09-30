defmodule Salix.Bindings.MeetingActivationCapability do
  @moduledoc false

  alias SalixIM.Provider.Feishu.{API, MeetingActivationAuthorization, MeetingActivationRef}

  @ttl_seconds 2 * 60 * 60

  def issue(state, owners) when is_map(state) and is_map(owners) do
    group_id = trim(state["group_id"])
    connect_id = trim(state["connect_id"])
    ref = state["feishu_ref"] || %{}

    with published_at when is_integer(published_at) and published_at > 0 <-
           get_in(state, ["delivery", "published_at"]),
         expires_at = published_at + @ttl_seconds,
         true <- expires_at >= System.system_time(:second),
         {:ok, connect} <-
           SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "feishu"),
         {:ok, signing_key} <- API.resource_ref_signing_key(connect) do
      grant = %{
        "meeting_id" => trim(state["meeting_id"]),
        "expires_at" => expires_at,
        "target" => %{
          "message_id" => reply_message_id(ref),
          "chat_id" => trim(ref["chat_id"]),
          "chat_type" => trim(ref["chat_type"]),
          "thread_id" => trim(ref["thread_id"]),
          "reply_in_thread" => trim(ref["chat_type"]) == "group"
        },
        "allowed_mentions" =>
          owners
          |> Enum.sort_by(fn {index, _owner} -> index end)
          |> Enum.map(fn {_index, owner} ->
            %{"user_id" => trim(owner["user_id"]), "name" => trim(owner["display_name"])}
          end)
          |> Enum.reject(&(&1["user_id"] == "" or &1["name"] == ""))
          |> Enum.uniq_by(& &1["user_id"])
      }

      MeetingActivationRef.encode(
        MeetingActivationAuthorization.ref_scope(group_id, connect_id),
        signing_key,
        grant
      )
    else
      false -> {:error, :meeting_activation_capability_expired}
      nil -> {:error, :meeting_publication_checkpoint_missing}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_meeting_publication_checkpoint}
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp reply_message_id(ref) do
    case trim(ref["root_message_id"]) do
      "" -> trim(ref["trigger_message_id"])
      root_message_id -> root_message_id
    end
  end
end
