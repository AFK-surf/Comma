defmodule Comma.Accounts.SessionIssuer do
  @moduledoc "Issues ordinary login sessions with one stable public response shape."

  alias Comma.Accounts
  alias Comma.Accounts.User

  @public_user_fields ["id", "email", "name", "status", "kind"]

  @spec issue(User.t() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(%User{} = user, opts), do: issue(Accounts.public_user(user), opts)

  def issue(%{"id" => user_id} = user, opts) when is_binary(user_id) and is_list(opts) do
    with {:ok, session} <- Accounts.create_session(user_id, opts) do
      {:ok,
       %{
         "token" => session["token"],
         "session_id" => session["id"],
         "expires_at" => session["expires_at"],
         "user" => Map.take(user, @public_user_fields)
       }}
    end
  end

  def issue(_user, _opts), do: {:error, :not_found}
end
