defmodule SalixSignal.Account.Usernames do
  @moduledoc """
  Username endpoints (CRS-02 §10.5) and claiming a username.

  The service stores only the username hash. Claiming a username is two
  steps: reserve one of up to 20 candidate hashes, then confirm it with a
  proof that the account knows the username (`SalixSignalProto.Username`).
  Byte fields in these requests are base64url without padding.

  The lookups are anonymous: they refuse a request with credentials (400),
  so they need an unauthenticated transport.
  """

  alias SalixSignal.Account.Transport
  alias SalixSignal.Service.Response
  alias SalixSignalProto.Username

  @max_candidates 20
  @default_attempts 3

  @type claimed :: %{username: String.t(), hash: binary(), link_handle: String.t() | nil}

  @doc """
  Reserves one of `hashes` (1 to 20 hashes of 32 bytes). Returns the hash
  that the service reserved, or `{:error, :taken}` when all are taken.
  """
  @spec reserve(Transport.t(), [binary()]) :: {:ok, binary()} | {:error, term()}
  def reserve(transport, hashes) when is_list(hashes) and length(hashes) in 1..@max_candidates do
    body = %{"usernameHashes" => Enum.map(hashes, &encode/1)}

    case Transport.request(transport, "PUT", "/v1/accounts/username_hash/reserve", json: body) do
      {:ok, %Response{status: 200} = response} ->
        with %{"usernameHash" => encoded} <- Transport.json_object(response),
             {:ok, hash} <- decode(encoded),
             true <- hash in hashes do
          {:ok, hash}
        else
          _ -> {:error, :malformed}
        end

      other ->
        failure(other, %{409 => :taken})
    end
  end

  @doc """
  Confirms a reserved hash with its proof. `encrypted_username` (optional)
  is the username link value (`SalixSignalProto.Username.encrypt_link/3`),
  which also sets the link. Errors: `:no_reservation` (409), `:gone` (410,
  no longer available) and `:invalid_proof` (422).
  """
  @spec confirm(Transport.t(), binary(), binary(), binary() | nil) ::
          {:ok, %{hash: binary(), link_handle: String.t() | nil}} | {:error, term()}
  def confirm(transport, hash, proof, encrypted_username \\ nil) do
    body =
      %{"usernameHash" => encode(hash), "zkProof" => encode(proof)}
      |> then(fn body ->
        if encrypted_username,
          do: Map.put(body, "encryptedUsername", encode(encrypted_username)),
          else: body
      end)

    case Transport.request(transport, "PUT", "/v1/accounts/username_hash/confirm", json: body) do
      {:ok, %Response{status: 200} = response} ->
        body = Transport.json_object(response) || %{}
        handle = if is_binary(body["usernameLinkHandle"]), do: body["usernameLinkHandle"]
        {:ok, %{hash: hash, link_handle: handle}}

      other ->
        failure(other, %{409 => :no_reservation, 410 => :gone, 422 => :invalid_proof})
    end
  end

  @doc "Deletes the account's username (`DELETE /v1/accounts/username_hash`)."
  @spec delete(Transport.t()) :: :ok | {:error, term()}
  def delete(transport), do: no_content(transport, "DELETE", "/v1/accounts/username_hash")

  @doc """
  Sets the username link to `encrypted_username`. With `keep_handle`, an
  existing handle is reused. Returns the link handle (a UUID string).
  `{:error, :no_username}` means the account has no username (409).
  """
  @spec set_link(Transport.t(), binary(), boolean()) :: {:ok, String.t()} | {:error, term()}
  def set_link(transport, encrypted_username, keep_handle \\ true) do
    body = %{
      "usernameLinkEncryptedValue" => encode(encrypted_username),
      "keepLinkHandle" => keep_handle
    }

    case Transport.request(transport, "PUT", "/v1/accounts/username_link", json: body) do
      {:ok, %Response{status: 200} = response} ->
        case Transport.json_object(response) do
          %{"usernameLinkHandle" => handle} when is_binary(handle) -> {:ok, handle}
          _ -> {:error, :malformed}
        end

      other ->
        failure(other, %{409 => :no_username})
    end
  end

  @doc "Deletes the username link."
  @spec delete_link(Transport.t()) :: :ok | {:error, term()}
  def delete_link(transport), do: no_content(transport, "DELETE", "/v1/accounts/username_link")

  @doc "Looks up the ACI of a username hash. Needs an unauthenticated transport."
  @spec lookup(Transport.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def lookup(transport, <<_::binary-size(32)>> = hash) do
    case Transport.request(transport, "GET", "/v1/accounts/username_hash/" <> encode(hash), []) do
      {:ok, %Response{status: 200} = response} ->
        case Transport.json_object(response) do
          %{"uuid" => aci} when is_binary(aci) -> {:ok, aci}
          _ -> {:error, :malformed}
        end

      other ->
        failure(other, %{404 => :not_found})
    end
  end

  @doc "Fetches the encrypted value of a username link by its handle (UUID string)."
  @spec lookup_link(Transport.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def lookup_link(transport, handle) do
    case SalixSignalProto.Address.parse_service_id(handle) do
      {:ok, {:aci, _}} ->
        path = "/v1/accounts/username_link/" <> String.downcase(handle)

        case Transport.request(transport, "GET", path, []) do
          {:ok, %Response{status: 200} = response} ->
            with %{"usernameLinkEncryptedValue" => encoded} <- Transport.json_object(response),
                 {:ok, value} <- decode(encoded) do
              {:ok, value}
            else
              _ -> {:error, :malformed}
            end

          other ->
            failure(other, %{404 => :not_found})
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  @doc """
  Claims a username for `nickname` (3 to 32 characters): reserves one of 20
  candidates with random discriminators, proves it and confirms it. When all
  candidates are taken, or the reservation is lost before confirmation, it
  tries again with longer discriminators, at most `:attempts` times
  (default 3).

  With `:link_entropy` (32 bytes), the confirmation also sets the username
  link, and the result carries its handle.
  """
  @spec claim(Transport.t(), String.t(), keyword()) :: {:ok, claimed()} | {:error, term()}
  def claim(transport, nickname, opts \\ []) do
    with {:ok, _} <- Username.from_parts(nickname, "01") do
      attempt(transport, nickname, 0, Keyword.get(opts, :attempts, @default_attempts), opts)
    end
  end

  defp attempt(_transport, _nickname, n, attempts, _opts) when n >= attempts, do: {:error, :taken}

  defp attempt(transport, nickname, n, attempts, opts) do
    by_hash =
      Map.new(candidates(nickname, n), fn username ->
        {:ok, hash} = Username.hash(username)
        {hash, username}
      end)

    with {:ok, hash} <- reserve(transport, Map.keys(by_hash)),
         username = Map.fetch!(by_hash, hash),
         {:ok, proof} <- Username.proof(username),
         {:ok, encrypted} <- link_value(username, Keyword.get(opts, :link_entropy)),
         {:ok, confirmed} <- confirm(transport, hash, proof, encrypted) do
      {:ok, %{username: username, hash: hash, link_handle: confirmed.link_handle}}
    else
      {:error, reason} when reason in [:taken, :gone] ->
        attempt(transport, nickname, n + 1, attempts, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_value(_username, nil), do: {:ok, nil}
  defp link_value(username, entropy), do: Username.encrypt_link(username, entropy)

  @doc """
  Up to 20 distinct candidate usernames for attempt `n` (0-based): attempt 0
  uses two-digit discriminators (`01` to `99`), attempt 1 three digits, and
  so on up to nine digits.
  """
  @spec candidates(String.t(), non_neg_integer()) :: [String.t()]
  def candidates(nickname, n) do
    digits = min(n + 2, 9)
    low = if digits == 2, do: 1, else: Integer.pow(10, digits - 1)
    high = Integer.pow(10, digits) - 1

    Stream.repeatedly(fn -> low + :rand.uniform(high - low + 1) - 1 end)
    |> Stream.uniq()
    |> Enum.take(@max_candidates)
    |> Enum.map(&(nickname <> "." <> String.pad_leading(Integer.to_string(&1), digits, "0")))
  end

  defp no_content(transport, method, path) do
    case Transport.request(transport, method, path, []) do
      {:ok, %Response{status: status}} when status in 200..299 -> :ok
      other -> failure(other, %{})
    end
  end

  defp failure({:ok, %Response{status: status} = response}, specific) do
    {:error, Map.get_lazy(specific, status, fn -> common_error(response) end)}
  end

  defp failure({:error, reason}, _specific), do: {:error, {:transport, reason}}

  defp common_error(%Response{status: 422}), do: :invalid_request
  defp common_error(%Response{status: 400}), do: :invalid_request
  defp common_error(response), do: Transport.error(response)

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)

  defp decode(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp decode(_encoded), do: :error
end
