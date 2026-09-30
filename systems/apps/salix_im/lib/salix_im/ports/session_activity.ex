defmodule SalixIM.Ports.SessionActivity do
  @moduledoc """
  Runtime-independent session activity snapshots and subscriptions.

  Callers subscribe before reading the current snapshot. Notifications are
  invalidation hints; callers re-read through `get/2` and never infer activity
  from the event itself.

  The production adapter may attach a reserved `_participant_realtime`
  envelope containing process-local presentation candidates. It is not Session
  Activity. Only the exact Conversation Participant owner interprets that
  envelope, after validating its full Group/Conversation/Participant scope;
  lifecycle consumers ignore it.
  """

  @callback get(agent_id :: String.t(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback subscribe(agent_id :: String.t(), session_id :: String.t()) ::
              :ok | {:error, term()}
  @callback unsubscribe(agent_id :: String.t(), session_id :: String.t()) ::
              :ok | {:error, term()}

  def get(agent_id, session_id), do: impl().get(agent_id, session_id)
  def subscribe(agent_id, session_id), do: impl().subscribe(agent_id, session_id)
  def unsubscribe(agent_id, session_id), do: impl().unsubscribe(agent_id, session_id)

  defp impl,
    do: Application.get_env(:salix_im, :session_activity_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.SessionActivity

    @impl true
    def get(_agent_id, _session_id), do: {:error, :session_activity_not_configured}

    @impl true
    def subscribe(_agent_id, _session_id), do: {:error, :session_activity_not_configured}

    @impl true
    def unsubscribe(_agent_id, _session_id), do: :ok
  end
end
