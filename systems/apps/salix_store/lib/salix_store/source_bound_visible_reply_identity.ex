defmodule SalixStore.SourceBoundVisibleReplyIdentity do
  @moduledoc false

  @version 1

  @spec idempotency_key(String.t(), map()) :: String.t()
  def idempotency_key(agent_id, scope) when is_binary(agent_id) and is_map(scope) do
    base = {
      @version,
      agent_id,
      value(scope, "agent_group_id"),
      value(scope, "conversation_id"),
      value(scope, "participant_id"),
      value(scope, "source_message_ids")
    }

    material =
      case value(scope, "response_identity") do
        identity when is_binary(identity) and identity != "" -> {base, identity}
        _ -> base
      end

    digest =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(material, [:deterministic]))
      |> Base.url_encode64(padding: false)

    "source-bound-visible-reply:" <> digest
  end

  defp value(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key(key), default)
    end
  end

  defp atom_key("agent_group_id"), do: :agent_group_id
  defp atom_key("conversation_id"), do: :conversation_id
  defp atom_key("participant_id"), do: :participant_id
  defp atom_key("source_message_ids"), do: :source_message_ids
  defp atom_key("response_identity"), do: :response_identity
end
