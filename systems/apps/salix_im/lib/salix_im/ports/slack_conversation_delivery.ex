defmodule SalixIM.Ports.SlackConversationDelivery do
  @moduledoc """
  Final outbound port for ordinary Slack Conversation deliveries.

  Conversation ownership, durable delivery claims, retry, and verification
  remain in SalixIM. The production implementation delegates to the Slack
  provider. A local rehearsal may replace only this port, after all durable
  Conversation transitions have already run, to prove the production path
  without writing to Slack.
  """

  alias SalixIM.MessageRenderer.Surface

  @callback post_message(String.t(), map(), map(), Surface.t() | nil) ::
              {:ok, term()} | {:error, term()}
  @callback upload_files(term(), String.t(), map(), [map()], map(), String.t()) ::
              {:ok, term()} | {:error, term()}
  @callback find_message(String.t(), map(), String.t(), String.t(), String.t()) ::
              {:ok, term()} | {:error, term()}

  def post_message(tenant, connect, params, surface),
    do: impl().post_message(tenant, connect, params, surface)

  def upload_files(agent_id, tenant, connect, files, params, operation_ref),
    do: impl().upload_files(agent_id, tenant, connect, files, params, operation_ref)

  def find_message(tenant, connect, channel_id, thread_ts, operation_ref),
    do: impl().find_message(tenant, connect, channel_id, thread_ts, operation_ref)

  defp impl do
    Application.get_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.Production
    )
  end

  defmodule Production do
    @moduledoc false
    @behaviour SalixIM.Ports.SlackConversationDelivery

    alias SalixIM.MessageRenderer.Surface
    alias SalixIM.Provider.Slack

    @impl true
    def post_message(tenant, connect, params, %Surface{} = surface),
      do: Slack.post_product_surface(tenant, connect, params, surface)

    def post_message(tenant, connect, params, nil),
      do: Slack.call(nil, tenant, connect, "slack.post_message", params)

    @impl true
    def upload_files(agent_id, tenant, connect, files, params, _operation_ref),
      do: Slack.upload_files(agent_id, tenant, connect, files, params)

    @impl true
    def find_message(tenant, connect, channel_id, thread_ts, operation_ref),
      do:
        Slack.find_conversation_delivery_message(
          tenant,
          connect,
          channel_id,
          thread_ts,
          operation_ref
        )
  end
end
