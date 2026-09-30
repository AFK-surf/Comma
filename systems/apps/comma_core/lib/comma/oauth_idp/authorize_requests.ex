defmodule Comma.OauthIdp.AuthorizeRequests do
  @moduledoc """
  One-time server-side custody for in-flight authorization requests
  (docs/identity-security.md): the authorize GET validates the
  request and stores its parameters under an opaque handle; the consent
  POST trusts **only** the handle — resubmitted query parameters are
  never a source of truth, which closes the parameter-confusion surface
  between what the user saw and what gets approved.

  Rows are single-use: `consume/2` is an atomic compare-and-set on
  `consumed_at`, so a replayed consent POST (double-click, resubmitted
  form, stolen handle) loses the race and fails closed. Expiry is
  enforced in the same UPDATE. Expired rows are swept opportunistically
  on insert; there is no background job to operate.
  """

  import Ecto.Query

  alias Comma.Repo

  @ttl_seconds 600
  @sweep_grace_seconds 3_600
  # AGENTS.md bounds request-path work: one authorize GET deletes at
  # most this many expired rows. A backlog drains across subsequent
  # requests instead of making one user's login own it.
  @sweep_batch_limit 100

  defmodule Request do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "comma_oauth_authorize_requests" do
      field(:csrf_token, :string)
      field(:user_id, :string)
      field(:client_id, :binary_id)
      field(:redirect_uri, :string)
      field(:scope, :string)
      field(:state, :string)
      field(:nonce, :string)
      field(:code_challenge, :string)
      field(:code_challenge_method, :string)
      field(:expires_at, :utc_datetime_usec)
      field(:consumed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end
  end

  @doc """
  Stores a validated authorization request and returns the row. The
  handle (`id`) and `csrf_token` are both random; the CSRF token is
  bound to this one request, so it needs no session coupling and dies
  with the handle.
  """
  @spec create!(%{
          required(:user_id) => String.t() | nil,
          required(:client_id) => String.t(),
          required(:redirect_uri) => String.t(),
          required(:scope) => String.t(),
          optional(:state) => String.t() | nil,
          optional(:nonce) => String.t() | nil,
          required(:code_challenge) => String.t(),
          required(:code_challenge_method) => String.t()
        }) :: Request.t()
  def create!(attrs) do
    sweep_expired()

    now = DateTime.utc_now()

    Repo.insert!(%Request{
      id: Ecto.UUID.generate(),
      csrf_token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      user_id: attrs[:user_id],
      client_id: attrs.client_id,
      redirect_uri: attrs.redirect_uri,
      scope: attrs.scope,
      state: attrs[:state],
      nonce: attrs[:nonce],
      code_challenge: attrs.code_challenge,
      code_challenge_method: attrs.code_challenge_method,
      expires_at: DateTime.add(now, @ttl_seconds, :second)
    })
  end

  @doc """
  Atomically consumes the handle for the given user. Exactly one caller
  can ever succeed; expired, already-consumed, unknown, or
  other-user handles all return `:error` indistinguishably.
  """
  @spec consume(String.t(), String.t()) :: {:ok, Request.t()} | :error
  def consume(handle, user_id) when is_binary(handle) and is_binary(user_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(handle) do
      now = DateTime.utc_now()

      query =
        from(r in Request,
          where:
            r.id == ^handle and is_nil(r.consumed_at) and r.expires_at > ^now and
              r.user_id == ^user_id,
          select: r
        )

      case Repo.update_all(query, set: [consumed_at: now, updated_at: now]) do
        {1, [request]} -> {:ok, request}
        {0, _none} -> :error
      end
    else
      :error -> :error
    end
  end

  @doc """
  Atomically consumes a logged-out (anonymous) handle: a row stored by
  the authorize endpoint before redirecting the user to the login page
  (RFC §5). Only rows with no bound user qualify — a consent-stage
  handle (bound to a user) can never be replayed through the resume
  path. Same one-shot semantics as `consume/2`: exactly one caller
  succeeds; expired, consumed, unknown, and user-bound handles are
  indistinguishable errors.
  """
  @spec consume_anonymous(String.t()) :: {:ok, Request.t()} | :error
  def consume_anonymous(handle) when is_binary(handle) do
    with {:ok, _uuid} <- Ecto.UUID.cast(handle) do
      now = DateTime.utc_now()

      query =
        from(r in Request,
          where:
            r.id == ^handle and is_nil(r.consumed_at) and r.expires_at > ^now and
              is_nil(r.user_id),
          select: r
        )

      case Repo.update_all(query, set: [consumed_at: now, updated_at: now]) do
        {1, [request]} -> {:ok, request}
        {0, _none} -> :error
      end
    else
      :error -> :error
    end
  end

  defp sweep_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -@sweep_grace_seconds, :second)

    batch =
      from(r in Request,
        where: r.expires_at < ^cutoff,
        limit: @sweep_batch_limit,
        select: r.id
      )

    Repo.delete_all(from(r in Request, where: r.id in subquery(batch)))
  end
end
