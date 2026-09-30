defmodule SalixIM.Ports.SlackTriageReplyDelivery do
  @moduledoc """
  Final provider port for one direct Triage Slack reply.

  The Triage product obligation owns durability, freshness, retry, and
  provider-confirmed completion. This port performs only the final Slack write
  and the bounded operation-reference lookup used after an ambiguous result.
  It never reads or mutates Conversation state.
  """

  @callback post_message(String.t(), map(), map()) ::
              {:ok, term()} | {:error, term()}
  @callback find_message(String.t(), map(), String.t(), String.t(), String.t()) ::
              {:ok, term()} | {:error, term()}

  def post_message(tenant, connect, params),
    do: impl().post_message(tenant, connect, params)

  def find_message(tenant, connect, channel_id, thread_ts, operation_ref),
    do: impl().find_message(tenant, connect, channel_id, thread_ts, operation_ref)

  defp impl do
    Application.get_env(
      :salix_im,
      :slack_triage_reply_delivery_mod,
      __MODULE__.Production
    )
  end

  defmodule Production do
    @moduledoc false
    @behaviour SalixIM.Ports.SlackTriageReplyDelivery

    alias SalixIM.Provider.Slack

    @impl true
    def post_message(tenant, connect, params),
      do: Slack.post_triage_reply(tenant, connect, params)

    @impl true
    def find_message(tenant, connect, channel_id, thread_ts, operation_ref),
      do:
        Slack.find_triage_reply_message(
          tenant,
          connect,
          channel_id,
          thread_ts,
          operation_ref
        )
  end
end
