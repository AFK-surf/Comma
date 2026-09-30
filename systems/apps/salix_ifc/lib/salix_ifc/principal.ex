defmodule SalixIFC.Principal do
  @moduledoc """
  Who can command an effect or read a resource. Pure identity; whether a
  provider user is an internal member or an external guest of a space is a
  fact in `SalixIFC.Facts.placements`, not part of the identity.

  The model is built on provider identity (Slack, Feishu, … user ids).
  Bridge For Teams login identity is deliberately not a principal: BFT
  accounts configure labels and clearances, they never read or write
  through the kernel.

      {:provider_user, connect, user_id}   a Slack, Feishu, Telegram, … user (including Slack bot users)
      {:comma_user, id}                      a Comma product user (internal Conversations)
      {:agent, agent_id}
      {:schedule, schedule_id, creator}    acts with its creator's authority
      {:api_key, key_id, creator}          an inbound API key, acting with its creator's authority
      :system

  `key/1` is the identity used for membership comparison: it unwraps a
  schedule or an API key to its creator.
  """

  @type t ::
          {:provider_user, binary, binary}
          | {:comma_user, binary}
          | {:agent, binary}
          | {:schedule, binary, t}
          | {:api_key, binary, t}
          | :system

  @type key ::
          {:provider_user, binary, binary}
          | {:comma_user, binary}
          | {:agent, binary}
          | :system

  def valid?(value), do: SalixIFC.Native.call(:principal_valid, {value})
  def authority(value), do: SalixIFC.Native.call(:principal_authority, {value})
  def key(value), do: SalixIFC.Native.call(:principal_authority, {value})
  def connect(value), do: SalixIFC.Native.call(:principal_connect, {value})
end
