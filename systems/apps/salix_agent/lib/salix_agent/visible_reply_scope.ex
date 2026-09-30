defmodule SalixAgent.VisibleReplyScope do
  @moduledoc """
  Pure, fail-closed authority derivation for a source-bound visible reply.

  This is deliberately narrower than generic IM egress. Only one activation
  consisting of trusted internal `user_chat` messages authored by a user can
  acquire a scope. The IM owner validates the candidate against canonical
  conversation state before any transient Participant draft is published.
  Canonical egress is a separate explicit `im_api.internal.send_message` call.

  Lean owns derivation, validation, and identity allocation decisions.
  This facade retains the external key codecs and consumer projections.

  The current transient lifecycle is modeled in
  `tla/salix/TransientDraftDelivery.tla`.
  """

  require SalixAgent.InternalSession
  alias SalixAgent.InternalSession

  @version 1

  @type scope :: %{required(String.t()) => term()}

  @doc """
  The scope this activation may claim, or `:none`.

  Kernel query `derive_visible_reply_scope`.
  """
  @spec derive(InternalSession.t() | map(), [String.t()]) :: {:ok, scope()} | :none
  def derive(session, source_message_ids) when is_list(source_message_ids),
    do: query(session, :derive_visible_reply_scope, source_message_ids)

  def derive(_session, _source_message_ids), do: :none

  @doc "Exact ordered source identities for the current unacknowledged user activation."
  @spec current_source_message_ids(InternalSession.t() | map()) :: [String.t()]
  def current_source_message_ids(session),
    do: query(session, :current_source_message_ids, nil)

  @spec idempotency_key(String.t(), scope()) :: String.t()
  def idempotency_key(agent_id, scope) when is_binary(agent_id) and is_map(scope) do
    # Rolling automatic-append records included the minted response identity
    # in their key; identity-less durable intents retain their pre-cutover key.
    # New rounds use this scope for transient Participant presentation only.
    SalixStore.SourceBoundVisibleReplyIdentity.idempotency_key(agent_id, scope)
  end

  @doc false
  def valid_response_identity?(identity),
    do: InternalSession.presentation_policy(:valid_response_identity?, identity)

  @doc false
  @spec egress_ownership_key(String.t(), String.t(), [String.t()]) :: String.t()
  def egress_ownership_key(agent_group_id, conversation_id, source_message_ids)
      when is_binary(agent_group_id) and is_binary(conversation_id) and
             is_list(source_message_ids) do
    digest =
      :sha256
      |> :crypto.hash(
        :erlang.term_to_binary(
          {@version, agent_group_id, conversation_id, source_message_ids},
          [:deterministic]
        )
      )
      |> Base.url_encode64(padding: false)

    "visible-reply-egress:" <> digest
  end

  @doc "Kernel helper `scopes_equivalent?`: two scopes minus their response identity."
  @spec equivalent?(scope(), scope()) :: boolean()
  def equivalent?(left, right), do: InternalSession.scopes_equivalent?(left, right)

  @doc false
  @spec valid_activation_scope?(term()) :: boolean()
  def valid_activation_scope?(scope), do: InternalSession.valid_activation_scope?(scope)

  defp query(session, name, args) when InternalSession.is_session(session),
    do: InternalSession.query(session, name, args)
end
