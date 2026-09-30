defmodule BridgeForTeams.OrgCreationInvites do
  @moduledoc """
  Manual invite-code flow for bootstrapping a new BridgeForTeams organization.

  Operators create a one-time code from an Elixir shell with
  `create_invite_code/1`. An anonymous user can redeem that code exactly once to
  create both their user account and organization; the user is added as the org
  owner in the same database transaction.
  """
  import Ecto.Query

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.OrgCreationInvite
  alias BridgeForTeams.{Accounts, Memberships, Observability, Orgs}

  @default_ttl_seconds 30 * 24 * 60 * 60

  @doc """
  Create a one-time invite code for org/account bootstrap.

  Returns the raw `:code` once. Only `code_hash` is stored.

  Options:

    * `:org_name` - organization display name to create.
    * `:org_slug` - organization slug to create.
    * `:ttl_seconds` - seconds until expiry; defaults to 30 days. Use `nil` for
      no expiry.
    * `:expires_at` - explicit UTC `DateTime`, overriding `:ttl_seconds`.
    * `:note` - optional operator note.
    * `:code` - optional caller-supplied code, mainly for deterministic tests.
  """
  @spec create_invite_code(map() | keyword()) ::
          {:ok, %{code: String.t(), invite: OrgCreationInvite.t()}}
          | {:error, Ecto.Changeset.t()}
  def create_invite_code(attrs \\ %{}) do
    attrs = normalize_attrs(attrs)
    code = attrs["code"] || generate_code()

    insert_attrs = %{
      "code_hash" => code_hash(code),
      "org_name" => attrs["org_name"],
      "org_slug" => attrs["org_slug"],
      "expires_at" => expires_at(attrs),
      "note" => attrs["note"]
    }

    case %OrgCreationInvite{} |> OrgCreationInvite.changeset(insert_attrs) |> Repo.insert() do
      {:ok, invite} -> {:ok, %{code: code, invite: invite}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Redeem a one-time invite code and create the owner user + organization.

  Required attrs: `email`. Optional attr: `name`.
  """
  @spec redeem_invite_code(String.t(), map() | keyword(), keyword()) ::
          {:ok, %{invite: OrgCreationInvite.t(), org: map(), user: map(), membership: map()}}
          | {:error, term()}
  def redeem_invite_code(code, attrs, opts \\ [])

  def redeem_invite_code(code, attrs, opts) when is_binary(code) do
    attrs = normalize_attrs(attrs)
    request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())

    Repo.transaction(fn ->
      with {:ok, invite} <- fetch_redeemable_invite(code),
           {:ok, user} <- create_user(attrs),
           {:ok, org} <- create_org(invite),
           audit_opts = audit_opts(opts, user, request_id),
           {:ok, membership} <- Memberships.put_org_member(org.id, user.id, "owner", audit_opts),
           {:ok, invite} <- mark_used(invite, user, org),
           {:ok, _audit} <-
             maybe_record_invite_redeemed_audit(invite, org, user, membership, audit_opts) do
        %{invite: invite, org: org, user: user, membership: membership}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def redeem_invite_code(_code, _attrs, _opts), do: {:error, :invalid_invite_code}

  @doc "Fetch a valid, unused invite code for display without consuming it."
  @spec get_redeemable_invite(String.t()) ::
          {:ok, OrgCreationInvite.t()}
          | {:error, :invalid_invite_code | :invite_already_used | :invite_expired}
  def get_redeemable_invite(code) when is_binary(code) do
    code
    |> code_hash()
    |> fetch_redeemable_invite_by_hash()
  end

  def get_redeemable_invite(_code), do: {:error, :invalid_invite_code}

  defp fetch_redeemable_invite(code) do
    code
    |> code_hash()
    |> fetch_redeemable_invite_by_hash_for_update()
  end

  defp fetch_redeemable_invite_by_hash(hash) do
    query =
      from i in OrgCreationInvite,
        where: i.code_hash == ^hash

    case Repo.one(query) do
      nil -> {:error, :invalid_invite_code}
      %OrgCreationInvite{used_at: %DateTime{}} -> {:error, :invite_already_used}
      %OrgCreationInvite{} = invite -> check_expiry(invite)
    end
  end

  defp fetch_redeemable_invite_by_hash_for_update(hash) do
    query =
      from i in OrgCreationInvite,
        where: i.code_hash == ^hash,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :invalid_invite_code}
      %OrgCreationInvite{used_at: %DateTime{}} -> {:error, :invite_already_used}
      %OrgCreationInvite{} = invite -> check_expiry(invite)
    end
  end

  defp check_expiry(%OrgCreationInvite{expires_at: nil} = invite), do: {:ok, invite}

  defp check_expiry(%OrgCreationInvite{expires_at: expires_at} = invite) do
    case DateTime.compare(expires_at, now()) do
      :gt -> {:ok, invite}
      _ -> {:error, :invite_expired}
    end
  end

  defp create_user(attrs) do
    Accounts.create_user(%{
      "email" => attrs["email"],
      "name" => blank_to_nil(attrs["name"])
    })
  end

  defp create_org(invite) do
    Orgs.create_org(%{
      "name" => invite.org_name,
      "slug" => invite.org_slug
    })
  end

  defp mark_used(%OrgCreationInvite{} = invite, user, org) do
    invite
    |> OrgCreationInvite.changeset(%{
      "used_at" => now(),
      "used_by_user_id" => user.id,
      "used_org_id" => org.id
    })
    |> Repo.update()
  end

  defp maybe_record_invite_redeemed_audit(invite, org, user, membership, opts) do
    if audit_enabled?(opts) do
      Observability.record_audit(%{
        org_id: org.id,
        actor_user_id: user.id,
        actor_label: audit_actor_label(user),
        action: "org_creation_invite.redeemed",
        resource_type: "organization",
        resource_id: org.id,
        resource_label: org.name,
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: %{
          "invite_id" => invite.id,
          "org_id" => org.id,
          "org_slug" => org.slug,
          "owner_user_id" => user.id,
          "membership_id" => membership.id,
          "source" => "signup"
        },
        redacted_diff: %{
          "organization" => %{"from" => nil, "to" => "created"},
          "owner_membership" => %{"from" => nil, "to" => "owner"}
        }
      })
    else
      {:ok, nil}
    end
  end

  defp audit_opts(opts, user, request_id) do
    if audit_enabled?(opts) do
      opts
      |> Keyword.put(:actor_user_id, user.id)
      |> Keyword.put(:actor_label, audit_actor_label(user))
      |> Keyword.put(:request_id, request_id)
    else
      opts
    end
  end

  defp audit_actor_label(user) do
    cond do
      present?(user.email) -> String.trim(user.email)
      present?(user.name) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      present?(Keyword.get(opts, :actor_user_id)) ||
      present?(Keyword.get(opts, :actor_label))
  end

  defp expires_at(%{"expires_at" => %DateTime{} = expires_at}), do: expires_at
  defp expires_at(%{"ttl_seconds" => nil}), do: nil

  defp expires_at(attrs) do
    ttl = Map.get(attrs, "ttl_seconds", @default_ttl_seconds)
    DateTime.add(now(), ttl, :second)
  end

  defp generate_code do
    "bft_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp code_hash(code), do: code |> normalize_code() |> Sessions.hash_token()

  defp normalize_code(code) when is_binary(code), do: String.trim(code)

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
