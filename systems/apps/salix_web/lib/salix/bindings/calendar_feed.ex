defmodule Salix.Bindings.CalendarFeed do
  @moduledoc """
  Serves a private iCal Feed for one bearer subscription.

  The bearer secret is the only credential; there is no tenant bearer token, so
  the route is a public carve-out. Authorization is the exact
  subscription-owned principal/calendar scope, revalidated per item during
  hydration. The Feed reads only a bounded horizon and performs no writes,
  provider calls, directory lookups or Schedule reads.
  """

  alias SalixCalendar.{ICalendar, Server}
  alias SalixStore.{CalendarFeedSubscriptions, Crypto}

  @past_ms 30 * 86_400_000
  @future_ms 365 * 86_400_000
  @max_secret_bytes 512

  @type result ::
          {:ok, %{body: String.t(), etag: String.t()}}
          | {:not_modified, String.t()}
          | {:error, term()}

  @spec serve(String.t(), String.t(), String.t()) :: result()
  def serve(feed_id, secret, if_none_match)
      when is_binary(feed_id) and is_binary(secret) and is_binary(if_none_match) do
    with :ok <- bounded_secret(secret),
         {:ok, scope} <- CalendarFeedSubscriptions.authenticate(feed_id, secret) do
      now = System.system_time(:millisecond)
      from = now - @past_ms
      to = now + @future_ms

      with {:ok, items} <-
             Server.list_owner_items(
               scope["group_id"],
               scope["calendar_id"],
               owner_ref(scope),
               from,
               to
             ) do
        etag = etag(feed_id, items)

        if secure_etag_match?(if_none_match, etag) do
          {:not_modified, etag}
        else
          case ICalendar.render(items, from, to) do
            {:ok, body} -> {:ok, %{body: body, etag: etag}}
            {:error, _} = error -> error
          end
        end
      end
    end
  end

  defp bounded_secret(secret) when byte_size(secret) <= @max_secret_bytes, do: :ok
  defp bounded_secret(_secret), do: {:error, :not_found}

  defp owner_ref(scope) do
    %{
      "namespace" => scope["subject_namespace"],
      "tenant_id" => scope["tenant_id"],
      "subject_id" => scope["subject_id"]
    }
  end

  # ETag derives from subscription identity plus the bounded projection revision
  # (item id + revision + update time), never the secret.
  defp etag(feed_id, items) do
    revision =
      items
      |> Enum.map(&{&1["calendar_item_id"], &1["revision"], &1["updated_at"]})
      |> Enum.sort()

    digest = Crypto.hex(:erlang.term_to_binary({feed_id, revision}, [:deterministic]))
    "\"" <> binary_part(digest, 0, 32) <> "\""
  end

  defp secure_etag_match?("", _etag), do: false
  defp secure_etag_match?(header, etag), do: header == etag
end
