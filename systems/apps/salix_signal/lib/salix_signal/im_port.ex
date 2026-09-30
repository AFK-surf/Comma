defmodule SalixSignal.IMPort do
  @moduledoc """
  The `SalixIM.Ports.SignalAccount` adapter: Router operations of the Signal
  provider reach `SalixSignal.Account` here (docs/messaging-voice.md).

  A peer is an ACI string (private chat) or `group:<base64url group id>`.
  Author ACIs are checked here, before the owner process sees them. Text
  over the 2,048-byte body limit is sent by the account runtime as a
  long-text attachment (CRS-05), so a text is one message.
  """

  @behaviour SalixIM.Ports.SignalAccount

  alias SalixSignal.Account
  alias SalixSignalProto.ServiceId

  @impl true
  def send_text(account_id, peer, body, opts) do
    with {:ok, send_opts} <- text_opts(opts) do
      case parse_peer(peer) do
        {:user, aci} -> Account.send_text(account_id, aci, body, send_opts)
        {:group, group_id} -> Account.send_group_text(account_id, group_id, body, send_opts)
        :error -> {:error, :invalid_peer}
      end
      |> result()
    end
  end

  @impl true
  def send_reaction(account_id, peer, emoji, author, timestamp, remove?) do
    with {:ok, _bytes} <- aci(author) do
      case parse_peer(peer) do
        {:user, aci} ->
          Account.send_reaction(account_id, aci, emoji, author, timestamp, remove: remove?)

        {:group, group_id} ->
          Account.send_group_reaction(account_id, group_id, emoji, author, timestamp,
            remove: remove?
          )

        :error ->
          {:error, :invalid_peer}
      end
      |> result()
    end
  end

  @impl true
  def send_edit(account_id, peer, timestamp, body) do
    case parse_peer(peer) do
      {:user, aci} -> Account.send_edit(account_id, aci, timestamp, body)
      {:group, group_id} -> Account.send_group_edit(account_id, group_id, timestamp, body)
      :error -> {:error, :invalid_peer}
    end
    |> result()
  end

  @impl true
  def send_delete(account_id, peer, timestamp) do
    case parse_peer(peer) do
      {:user, aci} ->
        Account.send_remote_delete(account_id, aci, timestamp)

      {:group, group_id} ->
        Account.send_group_remote_delete(account_id, group_id, timestamp)

      :error ->
        {:error, :invalid_peer}
    end
    |> result()
  end

  @impl true
  def send_typing(account_id, peer, action) when action in [:started, :stopped] do
    case parse_peer(peer) do
      {:user, aci} -> Account.send_typing(account_id, aci, action)
      {:group, group_id} -> Account.send_group_typing(account_id, group_id, action)
      :error -> {:error, :invalid_peer}
    end
    |> result()
  end

  @impl true
  def upload_attachment(account_id, data, opts),
    do: Account.upload_attachment(account_id, data, opts)

  @impl true
  def join_group(account_id, invite_url) do
    case Account.join_group(account_id, invite_url) do
      {:ok, {status, <<_::binary-size(32)>> = group_id}} when status in [:joined, :requested] ->
        {:ok, %{"status" => Atom.to_string(status), "peer" => group_peer(group_id)}}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :join_failed}
    end
  end

  @impl true
  def groups(account_id) do
    case Account.groups(account_id) do
      groups when is_list(groups) ->
        {:ok,
         Enum.map(groups, fn group ->
           %{
             "peer" => group_peer(group.group_id),
             "title" => group[:title],
             "revision" => group[:revision],
             "member_count" => length(List.wrap(group[:members])),
             "admin" => group[:admin?] == true
           }
         end)}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def change_members(account_id, peer, action, members) when action in [:add, :remove] do
    with {:group, group_id} <- parse_peer(peer) do
      case action do
        :add -> Account.add_group_members(account_id, group_id, members)
        :remove -> Account.remove_group_members(account_id, group_id, members)
      end
      |> revision()
    else
      _ -> {:error, :invalid_peer}
    end
  end

  @impl true
  def leave_group(account_id, peer) do
    with {:group, group_id} <- parse_peer(peer) do
      account_id |> Account.leave_group(group_id) |> revision()
    else
      _ -> {:error, :invalid_peer}
    end
  end

  @doc "The peer string of a 32-byte Groups v2 group identifier."
  def group_peer(<<_::binary-size(32)>> = group_id),
    do: "group:" <> Base.url_encode64(group_id, padding: false)

  @doc "Parses a peer string: `{:user, aci}`, `{:group, group_id}` or `:error`."
  def parse_peer("group:" <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, <<_::binary-size(32)>> = group_id} -> {:group, group_id}
      _ -> :error
    end
  end

  def parse_peer(peer) when is_binary(peer) do
    case aci(peer) do
      {:ok, _bytes} -> {:user, String.downcase(peer)}
      _ -> :error
    end
  end

  def parse_peer(_peer), do: :error

  # ---- helpers ----

  defp text_opts(opts) do
    base = Keyword.take(opts, [:attachments])

    case Keyword.get(opts, :quote) do
      nil ->
        {:ok, base}

      %{timestamp: timestamp, author: author} = given ->
        with {:ok, bytes} <- aci(author) do
          {:ok,
           Keyword.put(base, :quote, %{
             timestamp: timestamp,
             author_aci: bytes,
             text: Map.get(given, :text, "")
           })}
        end
    end
  end

  defp aci(value) when is_binary(value) do
    case ServiceId.aci_from_string(value) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_author}
    end
  end

  defp aci(_value), do: {:error, :invalid_author}

  defp revision({:ok, revision}) when is_integer(revision), do: {:ok, %{"revision" => revision}}
  defp revision(other), do: other

  defp result({:ok, %{} = sent}), do: {:ok, %{"timestamp" => sent[:timestamp]}}
  defp result(other), do: other
end
