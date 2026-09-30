defmodule SalixIM.Ports.SignalAccount do
  @moduledoc """
  Outbound port from the Signal provider (`SalixIM.Provider.Signal`,
  `SalixIM.SignalInbound`) to the Signal account runtime in `salix_signal`.

  `salix_im` does not depend on `salix_signal` (that app depends on
  `salix_voice`, which depends on `salix_im`). The runtime names its adapter
  in `config :salix_im, :signal_account_mod`. Without one, every operation
  is `{:error, :signal_unavailable}`.

  A `peer` is the ACI string of a Signal account (private chat) or
  `group:<base64url group identifier>` (Signal group). Timestamps are the
  sender's message timestamps in milliseconds; with the author ACI they name
  a message.
  """

  @type peer :: String.t()
  @type send_result :: {:ok, %{required(String.t()) => term()}} | {:error, term()}

  @doc "Sends text, with optional `:quote` (`%{timestamp, author, text}`) and `:attachments`."
  @callback send_text(account_id :: String.t(), peer(), body :: String.t(), opts :: keyword()) ::
              send_result()

  @callback send_reaction(
              account_id :: String.t(),
              peer(),
              emoji :: String.t(),
              target_author :: String.t(),
              target_timestamp :: non_neg_integer(),
              remove? :: boolean()
            ) :: send_result()

  @callback send_edit(
              account_id :: String.t(),
              peer(),
              target_timestamp :: non_neg_integer(),
              body :: String.t()
            ) :: send_result()

  @callback send_delete(account_id :: String.t(), peer(), target_timestamp :: non_neg_integer()) ::
              send_result()

  @doc "Sends a typing indicator (`:started` or `:stopped`). It is presentation, not a message."
  @callback send_typing(account_id :: String.t(), peer(), :started | :stopped) :: send_result()

  @doc "Uploads an attachment for a later send. Returns an opaque attachment term."
  @callback upload_attachment(account_id :: String.t(), data :: binary(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc "`{:ok, %{\"status\" => \"joined\" | \"requested\", \"peer\" => group_peer}}`"
  @callback join_group(account_id :: String.t(), invite_url :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc "The groups the account belongs to: `peer`, `title`, `revision`, `member_count`, `admin`."
  @callback groups(account_id :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @callback change_members(
              account_id :: String.t(),
              peer(),
              :add | :remove,
              members :: [String.t()]
            ) :: {:ok, map()} | {:error, term()}

  @callback leave_group(account_id :: String.t(), peer()) :: {:ok, map()} | {:error, term()}

  def send_text(account_id, peer, body, opts \\ []),
    do: impl().send_text(account_id, peer, body, opts)

  def send_reaction(account_id, peer, emoji, author, timestamp, remove?),
    do: impl().send_reaction(account_id, peer, emoji, author, timestamp, remove?)

  def send_edit(account_id, peer, timestamp, body),
    do: impl().send_edit(account_id, peer, timestamp, body)

  def send_delete(account_id, peer, timestamp),
    do: impl().send_delete(account_id, peer, timestamp)

  def send_typing(account_id, peer, action), do: impl().send_typing(account_id, peer, action)

  def upload_attachment(account_id, data, opts),
    do: impl().upload_attachment(account_id, data, opts)

  def join_group(account_id, invite_url), do: impl().join_group(account_id, invite_url)
  def groups(account_id), do: impl().groups(account_id)

  def change_members(account_id, peer, action, members),
    do: impl().change_members(account_id, peer, action, members)

  def leave_group(account_id, peer), do: impl().leave_group(account_id, peer)

  defp impl, do: Application.get_env(:salix_im, :signal_account_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.SignalAccount

    @impl true
    def send_text(_account_id, _peer, _body, _opts), do: {:error, :signal_unavailable}
    @impl true
    def send_reaction(_account_id, _peer, _emoji, _author, _timestamp, _remove?),
      do: {:error, :signal_unavailable}

    @impl true
    def send_edit(_account_id, _peer, _timestamp, _body), do: {:error, :signal_unavailable}
    @impl true
    def send_delete(_account_id, _peer, _timestamp), do: {:error, :signal_unavailable}
    @impl true
    def send_typing(_account_id, _peer, _action), do: {:error, :signal_unavailable}
    @impl true
    def upload_attachment(_account_id, _data, _opts), do: {:error, :signal_unavailable}
    @impl true
    def join_group(_account_id, _invite_url), do: {:error, :signal_unavailable}
    @impl true
    def groups(_account_id), do: {:error, :signal_unavailable}
    @impl true
    def change_members(_account_id, _peer, _action, _members), do: {:error, :signal_unavailable}
    @impl true
    def leave_group(_account_id, _peer), do: {:error, :signal_unavailable}
  end
end
