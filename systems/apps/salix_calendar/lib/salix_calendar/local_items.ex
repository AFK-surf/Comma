defmodule SalixCalendar.LocalItems do
  @moduledoc """
  Sole owner of Comma-local CalendarItem write persistence.

  Analogous to `SalixCalendar.SourceActor` for source items; `SalixCalendar.LocalStore`
  is the matching read-only helper.

  Idempotency is by construction, with no multi-write protocol: the item id is a
  stable, collision-resistant digest of the exact creation request, so a retried
  request always addresses the same item. `create_once` therefore makes a repeat
  a no-op, and the owner marker write is idempotent, so writes are order- and
  crash-independent. The item carries a content fingerprint, so the same request
  with different content is a conflict rather than a silent return of the first item.
  """

  alias SalixCalendar.LocalItem
  alias SalixStore.{CasRecord, Crypto, JSON, Keys}

  @proposal_keys ~w(title start time_zone duration attendees)
  @id_space 10_000_000_000_000_000_000

  @spec create(String.t(), String.t(), map(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def create(group_id, calendar_id, proposal, owner, creation_request_id)
      when is_binary(group_id) and is_binary(calendar_id) and is_map(proposal) and
             is_binary(creation_request_id) and creation_request_id != "" do
    with {:ok, owner} <- LocalItem.owner(owner),
         item_id <- item_id(creation_request_id),
         fingerprint <- fingerprint(owner, proposal),
         {:ok, %{envelope: envelope, start_ms: start_ms, owner: owner}} <-
           LocalItem.build(item_id, calendar_id, proposal, owner, creation_request_id) do
      envelope = Map.put(envelope, "creation_fingerprint", fingerprint)
      key = item_key(group_id, calendar_id, item_id)

      case create_once(key, envelope) do
        {:ok, item} ->
          finish(group_id, calendar_id, owner, start_ms, item_id, item)

        {:error, :exists} ->
          resume(group_id, calendar_id, owner, start_ms, item_id, key, fingerprint)

        {:error, _} = error ->
          error
      end
    end
  end

  def create(_group_id, _calendar_id, _proposal, _owner, _creation_request_id),
    do: {:error, :invalid_local_item_request}

  # The deterministic item already exists: an exact-content retry is idempotent;
  # the same request id with different content is a conflict, never a silent
  # return of the first item.
  defp resume(group_id, calendar_id, owner, start_ms, item_id, key, fingerprint) do
    case record(key) do
      {:ok, %{"creation_fingerprint" => ^fingerprint} = existing} ->
        finish(group_id, calendar_id, owner, start_ms, item_id, existing)

      {:ok, _mismatch} ->
        {:error, :calendar_local_item_conflict}

      {:error, _} = error ->
        error
    end
  end

  defp finish(group_id, calendar_id, owner, start_ms, item_id, item) do
    with :ok <- put_owner_marker(group_id, calendar_id, owner, start_ms, item_id),
         do: {:ok, item}
  end

  # A stable id derived from the exact creation request. Domain-separated SHA-256
  # reduced to the 19-digit body space; a retried request yields the same id.
  defp item_id(creation_request_id) do
    body =
      :crypto.hash(:sha256, "comma-local-item/v1\0" <> creation_request_id)
      |> :binary.decode_unsigned()
      |> rem(@id_space)
      |> Integer.to_string()
      |> String.pad_leading(19, "0")

    "cit1_" <> body
  end

  defp put_owner_marker(group_id, calendar_id, owner, start_ms, item_id) do
    key =
      Keys.ctl_calendar_query_owner_month(
        group_id,
        calendar_id,
        LocalItem.owner_digest(owner),
        LocalItem.month_bucket(start_ms),
        item_id
      )

    case CasRecord.ensure(key, fn -> %{} end, invalid: :invalid_calendar_record) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp create_once(key, value) do
    CasRecord.update(
      key,
      fn
        nil -> value
        _current -> {:error, :exists}
      end,
      invalid: :invalid_calendar_record
    )
  end

  defp record(key), do: CasRecord.get(key, :invalid_calendar_record)

  defp item_key(group_id, calendar_id, item_id),
    do: Keys.ctl_calendar_item(group_id, calendar_id, item_id)

  defp fingerprint(owner, proposal) do
    digest(%{
      "owner" => owner,
      "proposal" => proposal |> JSON.stringify() |> Map.take(@proposal_keys)
    })
  end

  defp digest(value),
    do: value |> JSON.stringify() |> :erlang.term_to_binary([:deterministic]) |> Crypto.hex()
end
