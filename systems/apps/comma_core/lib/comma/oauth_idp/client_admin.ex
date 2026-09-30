defmodule Comma.OauthIdp.ClientAdmin do
  @moduledoc """
  Registration and lifecycle of OAuth IdP clients
  (docs/identity-security.md, §8 — PR 8/10). Wraps
  `Boruta.Ecto.Admin` so that every client row this deployment creates
  carries the v1 policy, non-negotiably:

    * `authorization_code` is the only grant, PKCE forced on;
    * redirect URIs are exact HTTPS URLs (loopback HTTP allowed for
      native-app development), no wildcards, no fragments;
    * confidential clients authenticate with `client_secret_basic` /
      `client_secret_post`; public clients with PKCE alone. JWT client
      authentication and `jwks_uri` are never enabled (the CVE surface
      the RFC keeps unrouted);
    * short TTLs: 60s codes, 600s access and id_tokens. The refresh
      token grant is absent, so its TTL column is irrelevant.

  Client names are rendered on the consent page, so even under D1's
  hand-picked registration they are validated as untrusted input:
  bounded printable text, and names that could impersonate Comma itself
  are rejected outright.

  The client secret is returned exactly once, by `create/1` and
  `rotate_secret/1`; every other projection omits it. Note the at-rest
  form is Boruta's: the secret is a plaintext column, because the token
  endpoint's client authentication compares it inside Boruta core with
  no replaceable seam — hashing it would mean forking the comparison
  path. Recorded as a known v1 limit (hand-picked clients, one secret
  each, rotatable here). The per-client RSA key pair Boruta generates
  on insert stays unused dead weight: `Comma.OauthIdp.Clients` overrides
  the signing material with the provider key on every read (D3).

  Disable is a soft switch under `metadata["comma_disabled_at"]` — the
  `oauth_clients` table has no status column and altering a
  library-owned table would couple us to its migration stream. A
  disabled client fails closed at `Comma.OauthIdp.Clients.get_client/1`
  (the single resolution path for authorize and token alike), and
  `enable/1` is the recovery path for a mistaken disable — a fresh
  registration would mint a new client_id and break the integrator.
  """

  import Ecto.Query

  # Narrow aliases on purpose: `alias Boruta.Ecto` would shadow every
  # later `Ecto.*` reference in this module (Ecto.UUID, Ecto.Changeset).
  alias Boruta.Ecto.Admin
  alias Boruta.Ecto.Client, as: ClientRecord
  alias Comma.Repo

  @max_clients 200
  @max_redirect_uris 8
  @max_redirect_uri_bytes 512
  @name_min 3
  @name_max 64

  @authorization_code_ttl 60
  @access_token_ttl 600
  @id_token_ttl 600
  # The column is NOT NULL; the grant list makes it unreachable.
  @refresh_token_ttl 600

  @disabled_key "comma_disabled_at"

  @type public_client :: %{required(String.t()) => term()}

  ## Commands. Parsing (strict DTO, no side effects) runs BEFORE audit
  ## intent; execution runs inside the audited transaction. The secret
  ## appears exactly once, in the create/rotate result.

  # The admin-command envelope fields ride along with every command body.
  @envelope_fields ~w(reason idempotency_key confirmation admin_command_id)
  @create_fields ~w(name redirect_uris confidential)

  @doc """
  Strict create DTO, validated BEFORE any audit intent is recorded
  (Admin RFC: invalid input is `rejected` and must not consume the
  idempotency key). Returns the typed command `execute_create/1` runs
  inside the audited transaction.
  """
  @spec parse_create(map()) ::
          {:ok, %{name: String.t(), redirect_uris: [String.t()], confidential: boolean()}}
          | {:error, atom()}
  def parse_create(attrs) when is_map(attrs) do
    with :ok <- reject_unknown_fields(attrs, @create_fields),
         {:ok, confidential} <- validate_confidential(attrs["confidential"]),
         {:ok, name} <- validate_name(attrs["name"]),
         {:ok, redirect_uris} <- validate_redirect_uris(attrs["redirect_uris"]) do
      {:ok, %{name: name, redirect_uris: redirect_uris, confidential: confidential}}
    end
  end

  def parse_create(_attrs), do: {:error, :invalid_oauth_client}

  @doc """
  Strict lifecycle DTO: the body carries only the command envelope, and
  the target must exist (an unknown id is a rejection, not a burned
  idempotency key). Returns the target id the executors act on.
  """
  @spec parse_lifecycle(String.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def parse_lifecycle(client_id, attrs) when is_map(attrs) do
    with :ok <- reject_unknown_fields(attrs, []),
         {:ok, record} <- fetch(client_id) do
      {:ok, record.id}
    end
  end

  def parse_lifecycle(_client_id, _attrs), do: {:error, :oauth_client_not_found}

  @doc """
  Rotation-specific DTO: same envelope-only body and existence check as
  `parse_lifecycle/2`, plus the confidential requirement — a public
  (PKCE-only) client has no usable secret, and asking to rotate one is
  an input rejection, not a burned idempotency key.
  """
  @spec parse_rotate(String.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def parse_rotate(client_id, attrs) when is_map(attrs) do
    with :ok <- reject_unknown_fields(attrs, []),
         {:ok, record} <- fetch(client_id),
         true <- record.confidential || {:error, :oauth_client_not_confidential} do
      {:ok, record.id}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :oauth_client_not_found}
    end
  end

  def parse_rotate(_client_id, _attrs), do: {:error, :oauth_client_not_found}

  @doc """
  Convenience composition of `parse_create/1` and `execute_create/1`
  for non-HTTP callers and tests. The HTTP command path calls the two
  phases separately so validation precedes audit intent.
  """
  @spec create(map()) :: {:ok, public_client()} | {:error, atom()}
  def create(attrs) do
    with {:ok, command} <- parse_create(attrs) do
      execute_create(command)
    end
  end

  @spec execute_create(%{
          name: String.t(),
          redirect_uris: [String.t()],
          confidential: boolean()
        }) :: {:ok, public_client()} | {:error, atom()}
  def execute_create(%{name: name, redirect_uris: redirect_uris, confidential: confidential}) do
    with :ok <- enforce_client_limit() do
      case suppress_credential_logs(fn ->
             Admin.create_client(%{
               name: name,
               redirect_uris: redirect_uris,
               confidential: confidential,
               supported_grant_types: ["authorization_code"],
               pkce: true,
               authorization_code_ttl: @authorization_code_ttl,
               access_token_ttl: @access_token_ttl,
               id_token_ttl: @id_token_ttl,
               refresh_token_ttl: @refresh_token_ttl,
               id_token_signature_alg: "RS256",
               token_endpoint_auth_methods:
                 if(confidential,
                   do: ["client_secret_basic", "client_secret_post"],
                   else: []
                 )
             })
           end) do
        {:ok, client} ->
          projection = public_client(client)

          {:ok,
           if(confidential,
             do: Map.put(projection, "client_secret", client.secret),
             else: projection
           )}

        {:error, %Ecto.Changeset{}} ->
          {:error, :invalid_oauth_client}
      end
    end
  end

  @doc """
  Rotates the client secret. Returns the new secret exactly once.
  Public (PKCE-only) clients have no usable secret to rotate.
  """
  @spec rotate_secret(String.t()) :: {:ok, public_client()} | {:error, atom()}
  def rotate_secret(client_id) do
    with {:ok, record} <- fetch(client_id),
         true <- record.confidential || {:error, :oauth_client_not_confidential},
         {:ok, rotated} <-
           suppress_credential_logs(fn -> Admin.regenerate_client_secret(record) end) do
      {:ok, Map.put(public_client(rotated), "client_secret", rotated.secret)}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :oauth_client_rotation_failed}
    end
  end

  @doc """
  Disables the client: authorize and token resolution fail closed
  immediately (`Comma.OauthIdp.Clients` refuses disabled rows and the
  update invalidates Boruta's client cache). Already-issued access
  tokens live out their ≤600s TTL; that bound is the accepted blast
  radius, same as the RFC's key-rotation reasoning.
  """
  @spec disable(String.t()) :: {:ok, public_client()} | {:error, atom()}
  def disable(client_id) do
    with {:ok, record} <- fetch(client_id) do
      set_disabled_marker(record, DateTime.to_iso8601(DateTime.utc_now()))
    end
  end

  @doc "Re-enables a disabled client (the recovery path for a mistaken disable)."
  @spec enable(String.t()) :: {:ok, public_client()} | {:error, atom()}
  def enable(client_id) do
    with {:ok, record} <- fetch(client_id) do
      set_disabled_marker(record, nil)
    end
  end

  ## Queries

  @doc "Public projections of every registered client, newest first. Never includes secrets."
  @spec list() :: [public_client()]
  def list do
    Repo.all(from(c in ClientRecord, order_by: [desc: c.inserted_at]))
    |> Enum.map(&public_client/1)
  end

  @doc "True when the row carries the disabled marker."
  @spec disabled?(map() | struct()) :: boolean()
  def disabled?(%{metadata: metadata}) when is_map(metadata) do
    is_binary(metadata[@disabled_key])
  end

  def disabled?(_client), do: false

  ## Validation (names render on the consent page: untrusted input)

  defp validate_name(name) when is_binary(name) do
    normalized = name |> String.trim() |> String.replace(~r/\s+/u, " ")

    cond do
      String.length(normalized) < @name_min -> {:error, :invalid_oauth_client_name}
      String.length(normalized) > @name_max -> {:error, :invalid_oauth_client_name}
      String.match?(normalized, ~r/[\p{C}]/u) -> {:error, :invalid_oauth_client_name}
      reserved_name?(normalized) -> {:error, :reserved_oauth_client_name}
      true -> {:ok, normalized}
    end
  end

  defp validate_name(_name), do: {:error, :invalid_oauth_client_name}

  # `confidential` is a typed JSON boolean, not a truthy flag (the same
  # contract as the user-system RFC's `restricted`): "true" silently
  # becoming a public client would change the authentication policy the
  # operator asked for.
  defp validate_confidential(value) when value in [true, false], do: {:ok, value}
  defp validate_confidential(nil), do: {:ok, false}
  defp validate_confidential(_other), do: {:error, :invalid_oauth_client_confidential}

  defp reject_unknown_fields(attrs, command_fields) do
    allowed = command_fields ++ @envelope_fields

    case Enum.reject(Map.keys(attrs), &(&1 in allowed)) do
      [] -> :ok
      _unknown -> {:error, :invalid_oauth_client_field}
    end
  end

  # The one-time client secret (and, on create, Boruta's generated
  # per-client RSA private key) are INSERT/UPDATE parameters, and Ecto's
  # query logger prints parameters. Suppressing this process's logging
  # for exactly the persistence call keeps the "shown exactly once"
  # promise out of application logs; telemetry measurements (durations,
  # counts) are unaffected.
  defp suppress_credential_logs(fun) do
    Logger.put_process_level(self(), :none)

    try do
      fun.()
    after
      Logger.delete_process_level(self())
    end
  end

  # Anti-impersonation: a third-party app must not present itself as
  # Comma on the consent page. Deliberately narrow — "Barbecue Planner"
  # is fine; being or leading with "Comma", or claiming officialdom, is
  # not. D1's self-serve follow-up owns the broader policy.
  defp reserved_name?(normalized) do
    folded = String.downcase(normalized)

    folded == "comma" or
      String.starts_with?(folded, "comma ") or
      String.contains?(folded, "comma official") or
      String.contains?(folded, "comma team") or
      String.contains?(folded, "comma官方") or
      String.contains?(folded, "comma 官方")
  end

  defp validate_redirect_uris(uris) when is_list(uris) and uris != [] do
    if length(uris) > @max_redirect_uris do
      {:error, :too_many_redirect_uris}
    else
      normalized = Enum.map(uris, &validate_redirect_uri/1)

      case Enum.find(normalized, &match?({:error, _reason}, &1)) do
        nil -> {:ok, Enum.map(normalized, fn {:ok, uri} -> uri end)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp validate_redirect_uris(_uris), do: {:error, :invalid_redirect_uri}

  defp validate_redirect_uri(uri) when is_binary(uri) do
    parsed = URI.parse(uri)

    cond do
      byte_size(uri) > @max_redirect_uri_bytes -> {:error, :invalid_redirect_uri}
      String.contains?(uri, "*") -> {:error, :invalid_redirect_uri}
      parsed.fragment != nil -> {:error, :invalid_redirect_uri}
      parsed.host in [nil, ""] -> {:error, :invalid_redirect_uri}
      parsed.scheme == "https" -> {:ok, uri}
      parsed.scheme == "http" and loopback_host?(parsed.host) -> {:ok, uri}
      true -> {:error, :invalid_redirect_uri}
    end
  end

  defp validate_redirect_uri(_uri), do: {:error, :invalid_redirect_uri}

  # Loopback IP literals only, per RFC 8252 §8.3: `localhost` can be
  # remapped via DNS/hosts and is deliberately not accepted.
  defp loopback_host?(host), do: host in ["127.0.0.1", "::1"]

  # A bound nobody should reach under D1's hand-picked registration; if
  # it fires, the answer is the self-serve RFC, not a bigger number.
  defp enforce_client_limit do
    if Repo.aggregate(ClientRecord, :count) >= @max_clients do
      {:error, :oauth_client_limit_reached}
    else
      :ok
    end
  end

  ## Plumbing

  defp fetch(client_id) when is_binary(client_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(client_id),
         %ClientRecord{} = record <- Repo.get(ClientRecord, client_id) do
      {:ok, record}
    else
      _missing -> {:error, :oauth_client_not_found}
    end
  end

  defp fetch(_client_id), do: {:error, :oauth_client_not_found}

  defp set_disabled_marker(record, disabled_at) do
    metadata =
      case {record.metadata, disabled_at} do
        {metadata, nil} when is_map(metadata) -> Map.delete(metadata, @disabled_key)
        {metadata, at} when is_map(metadata) -> Map.put(metadata, @disabled_key, at)
        {_other, nil} -> %{}
        {_other, at} -> %{@disabled_key => at}
      end

    case Admin.update_client(record, %{metadata: metadata}) do
      {:ok, updated} -> {:ok, public_client(updated)}
      {:error, _changeset} -> {:error, :oauth_client_update_failed}
    end
  end

  defp public_client(client) do
    %{
      "id" => client.id,
      "name" => client.name,
      "confidential" => client.confidential == true,
      "redirect_uris" => client.redirect_uris,
      "disabled_at" => (is_map(client.metadata) && client.metadata[@disabled_key]) || nil,
      "created_at" => client.inserted_at && DateTime.to_iso8601(client.inserted_at)
    }
  end
end
