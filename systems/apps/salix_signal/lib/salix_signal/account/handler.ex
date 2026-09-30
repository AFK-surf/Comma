defmodule SalixSignal.Account.Handler do
  @moduledoc """
  What an account's owner process (`SalixSignal.Account.Server`) hands to
  the product layer (the Signal provider, layer C12). The module is named
  by `config :salix_signal, :handler` or the server option `:handler`.

  ## Inbound messages

  `c:handle_inbound/3` receives each admitted envelope whose outcome is
  `:message` and whose content kind is `:data`, `:edit`, `:receipt` or
  `:typing`, after its envelope is committed and acknowledged. Items come
  from the durable inbound feed in `seq` order. The account keeps a durable
  delivery cursor: it moves past an item only when the callback returns
  `:ok`. Any other result, or a raise, stops delivery until the next
  envelope, the retry timer or a restart, so delivery is at least once and
  the callback must be idempotent (for example keyed by `seq` or
  `inbound.guid`).

  ## Calls

  `c:incoming_call/2` decides a 1:1 offer that has no collision, and
  `c:admit_call/3` binds a connected call to a voice call
  (`SalixSignal.Carrier.admit/2`); see `SalixSignal.CallSignaling`.

  ## Notifications

  `c:handle_event/2` (optional) receives notifications such as
  `{:identity_changed, aci}`, `{:profile_key_changed, aci}`,
  `{:expire_timer_changed, aci, timer}`, `{:decryption_failed, aci, :now |
  :unless_resent}`, `{:group_updated, group_id, revision}`,
  `{:group_call_ring, group_id, ring_id, :ring | :cancelled, sender_aci}`
  (CRS-14 section 11) and `{:account_stopped, reason}`. Its result is
  ignored; it must return quickly.
  """

  alias SalixSignal.Messaging.Inbound

  @callback handle_inbound(account_id :: String.t(), seq :: pos_integer(), Inbound.t()) ::
              :ok | {:error, term()}

  @callback incoming_call(account_id :: String.t(), info :: map()) ::
              :ring | :busy | :needs_permission | :ignore

  @callback admit_call(account_id :: String.t(), info :: map(), connection :: pid()) ::
              :ok | {:ok, term()} | {:error, term()}

  @callback handle_event(account_id :: String.t(), event :: tuple()) :: any()

  @optional_callbacks handle_event: 2
end

defmodule SalixSignal.Account.NullHandler do
  @moduledoc """
  The handler when none is configured: inbound items are consumed without
  effect, calls are refused as not permitted (CRS-12 hangup type 4) and
  never admitted.
  """

  @behaviour SalixSignal.Account.Handler

  @impl true
  def handle_inbound(_account_id, _seq, _inbound), do: :ok

  @impl true
  def incoming_call(_account_id, _info), do: :needs_permission

  @impl true
  def admit_call(_account_id, _info, _connection), do: {:error, :no_handler}
end
