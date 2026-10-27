defmodule Comma.Dictation do
  @moduledoc """
  Tickets for live dictation (`CommaWeb.DictationSocket`): a member's session
  asks for a one-minute, single-use ticket, and the Quick Chat helper, which
  holds no session, opens the dictation socket with it. A ticket carries only
  the member it was issued to.
  """

  alias Comma.Auth.OneTimeCredentials

  @purpose "dictation"
  @ttl_seconds 60

  @doc "A ticket for `user`: `%{\"ticket\", \"expires_at\"}`."
  def ticket(user) do
    with {:ok, grant} <-
           OneTimeCredentials.issue(
             @purpose,
             %{"user_id" => user["id"]},
             @ttl_seconds,
             user["id"]
           ) do
      {:ok, %{"ticket" => grant.id <> "." <> grant.secret, "expires_at" => grant.expires_at}}
    end
  end

  @doc "Redeems a ticket once: `{:ok, %{user_id:}}`, or `{:error, :invalid_ticket}`."
  def redeem(ticket) when is_binary(ticket) do
    with [id, secret] <- String.split(ticket, ".", parts: 2),
         {:ok, %{"user_id" => user_id}} when is_binary(user_id) <-
           OneTimeCredentials.consume(@purpose, id, secret) do
      {:ok, %{user_id: user_id}}
    else
      {:error, :auth_unavailable} -> {:error, :unavailable}
      _ -> {:error, :invalid_ticket}
    end
  end

  def redeem(_ticket), do: {:error, :invalid_ticket}
end
