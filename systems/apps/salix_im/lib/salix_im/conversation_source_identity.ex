defmodule SalixIM.ConversationSourceIdentity do
  @moduledoc """
  Encodes and decodes the internal source identity attached to messages that
  wake a group-conversation agent turn.

  The encoded identity is an internal delivery detail. Public conversation
  streams must expose only the canonical message id returned by `message_id/2`.
  """

  @spec encode(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_id}
  def encode(conversation_id, message_id, participant_id) do
    encode(conversation_id, message_id, participant_id, nil)
  end

  @spec encode(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :invalid_id}
  def encode(conversation_id, message_id, participant_id, suffix) do
    if SalixStore.Ids.valid_conversation_id?(conversation_id) and
         SalixStore.Ids.valid_message_id?(message_id) and
         SalixStore.Ids.valid_participant_id?(participant_id) and valid_suffix?(suffix) do
      encoded_suffix = if is_binary(suffix), do: ":" <> suffix, else: ""

      {:ok,
       "groupconv:" <>
         conversation_id <> ":" <> message_id <> ":" <> participant_id <> encoded_suffix}
    else
      {:error, :invalid_id}
    end
  end

  @spec decode(term(), String.t()) ::
          {:ok, %{message_id: String.t(), participant_id: String.t()}}
          | {:error, :invalid_source_identity}
  def decode(source_identity, conversation_id) when is_binary(conversation_id) do
    prefix = "groupconv:" <> conversation_id <> ":"

    with source_identity when is_binary(source_identity) <- source_identity,
         true <- String.starts_with?(source_identity, prefix),
         [message_id, participant_id | suffix_parts] <-
           source_identity |> String.replace_prefix(prefix, "") |> String.split(":"),
         suffix <- if(suffix_parts == [], do: nil, else: Enum.join(suffix_parts, ":")),
         true <- valid_suffix?(suffix),
         true <- SalixStore.Ids.valid_message_id?(message_id),
         true <- SalixStore.Ids.valid_participant_id?(participant_id) do
      {:ok, %{message_id: message_id, participant_id: participant_id}}
    else
      _ -> {:error, :invalid_source_identity}
    end
  end

  def decode(_source_identity, _conversation_id), do: {:error, :invalid_source_identity}

  @doc "The conversation a source identity was minted for, when it is well-formed."
  @spec conversation_id(term()) :: {:ok, String.t()} | {:error, :invalid_source_identity}
  def conversation_id("groupconv:" <> rest = source_identity) do
    with [conversation_id | _] <- String.split(rest, ":", parts: 2),
         true <- SalixStore.Ids.valid_conversation_id?(conversation_id),
         {:ok, _decoded} <- decode(source_identity, conversation_id) do
      {:ok, conversation_id}
    else
      _ -> {:error, :invalid_source_identity}
    end
  end

  def conversation_id(_source_identity), do: {:error, :invalid_source_identity}

  @spec message_id(term(), String.t()) :: {:ok, String.t()} | {:error, :invalid_source_identity}
  def message_id(source_identity, conversation_id) do
    with {:ok, %{message_id: message_id}} <- decode(source_identity, conversation_id) do
      {:ok, message_id}
    end
  end

  @spec message_ids(term(), String.t()) :: [String.t()]
  def message_ids(source_identities, conversation_id) when is_list(source_identities) do
    source_identities
    |> Enum.flat_map(fn source_identity ->
      case message_id(source_identity, conversation_id) do
        {:ok, message_id} -> [message_id]
        {:error, :invalid_source_identity} -> []
      end
    end)
    |> Enum.uniq()
  end

  def message_ids(_source_identities, _conversation_id), do: []

  defp valid_suffix?(nil), do: true

  defp valid_suffix?(suffix) when is_binary(suffix),
    do: Regex.match?(~r/\Aredelivery:[0-9a-f]{64}\z/, suffix)

  defp valid_suffix?(_suffix), do: false
end
