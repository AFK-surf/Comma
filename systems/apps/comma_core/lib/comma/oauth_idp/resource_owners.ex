defmodule Comma.OauthIdp.ResourceOwners do
  @moduledoc """
  `Boruta.Oauth.ResourceOwners` backed by `comma_users`.

  The OIDC subject (`sub`) is the stable public `comma_users.id` (`usr_*`),
  per decision D6 of docs/identity-security.md. Only `active` users
  resolve; a disabled account fails closed on every lookup.

  Comma is passwordless, so `check_password/2` always fails: the resource
  owner password grant stays disabled on every client, and the authorize
  flow receives an already-authenticated resource owner resolved from
  the existing Comma session.
  """

  @behaviour Boruta.Oauth.ResourceOwners

  alias Boruta.Oauth.ResourceOwner
  alias Comma.Accounts

  @impl Boruta.Oauth.ResourceOwners
  def get_by(sub: sub) do
    case Accounts.get_user(sub) do
      {:ok, %{"status" => "active"} = user} -> {:ok, to_resource_owner(user)}
      _ -> {:error, "User not found."}
    end
  end

  def get_by(username: email) do
    case Accounts.get_user_by_email(email) do
      {:ok, %{"status" => "active"} = user} -> {:ok, to_resource_owner(user)}
      _ -> {:error, "User not found."}
    end
  end

  @impl Boruta.Oauth.ResourceOwners
  def check_password(_resource_owner, _password) do
    {:error, "Comma is passwordless; the password grant is not supported."}
  end

  @impl Boruta.Oauth.ResourceOwners
  def authorized_scopes(%ResourceOwner{}), do: []

  @impl Boruta.Oauth.ResourceOwners
  def claims(%ResourceOwner{sub: sub}, scope) do
    # The claim set follows the token's granted scope, so a token can
    # never unlock more identity data than its scope admits — even if
    # the authorize endpoint's fixed-scope rule changes later.
    case Accounts.get_user(sub) do
      {:ok, user} ->
        granted = String.split(scope || "", " ", trim: true)

        %{}
        |> put_scope_claims("email" in granted, %{
          "email" => user["email"],
          "email_verified" => true
        })
        |> put_scope_claims("profile" in granted, %{"name" => user["name"]})

      _ ->
        %{}
    end
  end

  defp put_scope_claims(claims, true, additions), do: Map.merge(claims, additions)
  defp put_scope_claims(claims, false, _additions), do: claims

  @doc "Builds the Boruta resource owner for an already-authenticated Comma user."
  @spec to_resource_owner(map()) :: ResourceOwner.t()
  def to_resource_owner(user) do
    %ResourceOwner{sub: user["id"], username: user["email"]}
  end
end
