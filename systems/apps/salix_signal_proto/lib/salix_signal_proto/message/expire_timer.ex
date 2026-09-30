defmodule SalixSignalProto.Message.ExpireTimer do
  @moduledoc """
  The disappearing-message timer of a 1:1 conversation (CRS-05 §5.2).

  The stored state is `%{seconds: n, version: v}` (0 seconds = off). Every
  outgoing 1:1 data message carries the timer (field 5, omitted when off)
  and its version (field 23), so a receiver can resynchronize. In a group the
  timer is part of the group state (CRS-09), and receivers ignore the timer
  of group data messages.

  Message expiry is local behavior; nothing is sent when a message expires.
  """

  alias SalixSignalProto.Message.Content
  alias SalixSignalProto.Message.Wire

  @type t :: %{seconds: non_neg_integer(), version: non_neg_integer()}

  @doc "The state of a conversation that has never set a timer."
  @spec initial() :: t()
  def initial, do: %{seconds: 0, version: 0}

  @doc """
  Applies a received 1:1 data message to the stored timer state (CRS-05
  §5.2 receive rules). Returns `{:changed, new_state}` or `:unchanged`.

  A message is a timer change when it has flags bit 2, when its timer differs
  from the stored timer, or when its version is higher than the stored
  version. The change is ignored when the timer equals the stored timer, or
  when field 23 is present and lower than the stored version. A message
  without field 23 (older senders) changes the timer and keeps the stored
  version.
  """
  @spec apply_received(t(), Wire.DataMessage.t()) :: {:changed, t()} | :unchanged
  def apply_received(
        %{seconds: stored, version: stored_version},
        %Wire.DataMessage{group_v2: nil} = data
      ) do
    seconds = data.expire_timer || 0
    version = data.expire_timer_version

    change? =
      Content.flag?(data, :expire_timer_update) or seconds != stored or
        (is_integer(version) and version > stored_version)

    cond do
      not change? -> :unchanged
      seconds == stored -> :unchanged
      is_integer(version) and version < stored_version -> :unchanged
      is_integer(version) -> {:changed, %{seconds: seconds, version: version}}
      true -> {:changed, %{seconds: seconds, version: stored_version}}
    end
  end

  def apply_received(_state, %Wire.DataMessage{}), do: :unchanged

  @doc """
  The state after this account changes the timer to `seconds`: the version
  goes up by one from the stored version (CRS-05 §5.2, open question 8).
  """
  @spec change(t(), non_neg_integer()) :: t()
  def change(%{version: version}, seconds) when is_integer(seconds) and seconds >= 0,
    do: %{seconds: seconds, version: version + 1}
end
