defmodule SalixSignal.ContactDiscovery do
  @moduledoc """
  Contact discovery: maps E.164 phone numbers to Signal service IDs for the
  binding flow (CRS-11).

  One lookup runs in the calling process and makes one connection:

    1. `GET /v2/directory/auth` on the chat service gives a short-lived
       credential (§2).
    2. A WebSocket upgrade to the contact discovery host at
       `/v1/<MRENCLAVE hex>/discovery`, with that credential as HTTP Basic
       authentication and the pinned Signal roots for TLS 1.3 (§3).
    3. The enclave sends its attestation, which must pass every check of
       `SalixSignalProto.ContactDiscovery.Attestation` before the client
       sends anything (§5). Any failure ends the lookup:
       contact discovery fails closed.
    4. A `Noise_NKhfs_25519+Kyber1024_ChaChaPoly_SHA256` handshake to the
       attested key, the encrypted request, the rate-limit token, its
       acknowledgement, and the results until the enclave closes with 1000
       (§4 and §6).

  A number alone yields only the account's PNI. The ACI comes back only for
  accounts whose ACI and access key the request carries (§6.3).

  Secret-key KEM operations need OTP `:crypto` with ML-KEM-1024 (OpenSSL
  3.5): without it the lookup returns `{:error, :kem_unsupported}` before it
  sends anything (owner decision on KEM use, `SalixSignalProto.KemBackend`).

  Bounds: at most 50,000 new numbers per lookup (the deployed clients'
  default hard limit, §6.4), one deadline for the whole lookup (default
  30 s), and at most `max_message_bytes` (default 8 MiB) per received
  WebSocket message.
  """

  alias SalixSignal.Account.Transport
  alias SalixSignal.Service.{Credentials, Endpoints, Response}
  alias SalixSignalProto.ContactDiscovery.{Attestation, Lookup, Noise}
  alias SalixSignalProto.Crypto.{MlKem1024, X25519}
  alias SalixSignalProto.KemBackend

  @max_numbers 50_000
  @default_timeout_ms 30_000
  @default_user_agent "Salix-Signal/0.1"

  @type result :: %{pni: {:pni, <<_::128>>}, aci: {:aci, <<_::128>>} | nil}

  @type error ::
          :kem_unsupported
          | :invalid_number
          | :too_many_numbers
          | :invalid_credentials
          | {:attestation_failed, Attestation.failure()}
          | :handshake_failed
          | :missing_token
          | :invalid_token
          | :invalid_argument
          | {:rate_limited, non_neg_integer() | nil}
          | {:unavailable, integer()}
          | :unauthorized
          | {:upgrade_rejected, integer()}
          | :protocol_error
          | :timeout
          | {:transport, term()}
          | {:http_error, integer()}
          | :client_deprecated
          | {:challenge_required, term()}

  @doc """
  Looks up `numbers` (E.164 strings, not sent before) through `transport`,
  the account's chat transport (`SalixSignal.Account.Transport`), which
  fetches the credential.

  Options:

    * `:environment` - `:production` (default) or `:staging`; selects the
      host and the pinned MRENCLAVE.
    * `:token` and `:previous_numbers` - the token and the numbers of the
      previous full lookup; the enclave then charges only for `numbers`
      (§6.4). A one-off lookup sends neither.
    * `:aci_access_keys` - `{aci_uuid_bytes, access_key}` pairs whose ACIs
      the enclave may return (§6.3).
    * `:timeout` - the deadline for the whole lookup in ms.
    * `:host`, `:port`, `:roots`, `:pins`, `:user_agent`,
      `:max_message_bytes` - connection overrides for tests and staging.

  Returns `{:ok, %{results: %{e164 => result | nil}, token: token}}`; a
  number maps to nil when it is not registered or not discoverable. On
  `{:error, :invalid_token}` the caller discards its stored token and
  previous numbers.
  """
  @spec lookup(Transport.t(), [Lookup.e164()], keyword()) ::
          {:ok, %{results: %{Lookup.e164() => result() | nil}, token: binary()}}
          | {:error, error()}
  def lookup(transport, numbers, opts \\ []) when is_list(numbers) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @default_timeout_ms)

    environment = Keyword.get(opts, :environment, :production)
    pins = Keyword.get(opts, :pins, Attestation.pins(environment))

    with :ok <- check_kem(),
         :ok <- check_count(numbers),
         {:ok, request} <-
           Lookup.encode_request(
             new_numbers: numbers,
             previous_numbers: Keyword.get(opts, :previous_numbers, []),
             token: Keyword.get(opts, :token),
             aci_access_keys: Keyword.get(opts, :aci_access_keys, [])
           ),
         {:ok, credentials} <- credentials(transport),
         {:ok, socket} <- connect(credentials, pins, environment, opts, deadline) do
      try do
        run(socket, request, pins)
      after
        Mint.HTTP.close(socket.conn)
      end
    end
  end

  # The Noise channel generates and decapsulates an ML-KEM-1024 key.
  defp check_kem do
    _backend = KemBackend.select!(:mlkem1024)
    :ok
  rescue
    KemBackend.UnsupportedError -> {:error, :kem_unsupported}
  end

  defp check_count(numbers) when length(numbers) <= @max_numbers, do: :ok
  defp check_count(_numbers), do: {:error, :too_many_numbers}

  @doc """
  Fetches the contact discovery credential from the chat service (§2). The
  username and password are opaque strings.
  """
  @spec credentials(Transport.t()) :: {:ok, Credentials.t()} | {:error, term()}
  def credentials(transport) do
    case Transport.request(transport, "GET", "/v2/directory/auth", []) do
      {:ok, %Response{status: 200} = response} ->
        case Transport.json_object(response) do
          %{"username" => username, "password" => password}
          when is_binary(username) and is_binary(password) and username != "" ->
            {:ok, %Credentials{username: username, password: password}}

          _ ->
            {:error, :invalid_credentials}
        end

      {:ok, %Response{} = response} ->
        {:error, Transport.error(response)}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # --- Protocol ------------------------------------------------------------

  defp run(socket, request, pins) do
    with {:ok, attestation, socket} <- receive_binary(socket),
         {:ok, %{public_key: enclave_key}} <- attest(attestation, pins),
         {:ok, message1, handshake} <-
           Noise.initiator_write(enclave_key,
             ephemeral: X25519.generate_private_key(),
             kem: MlKem1024.keypair(:crypto.strong_rand_bytes(64))
           ),
         {:ok, socket} <- send_binary(socket, message1),
         {:ok, message2, socket} <- receive_binary(socket),
         {:ok, _payload, noise} <- Noise.initiator_read(handshake, message2),
         {:ok, noise, socket} <- send_sealed(socket, noise, request),
         {:ok, first, noise, socket} <- receive_response(socket, noise, %Lookup.Response{}),
         {:ok, token} <- Lookup.token(first),
         {:ok, noise, socket} <- send_sealed(socket, noise, Lookup.token_ack()),
         {:ok, final, _socket} <- receive_results(socket, noise, nil),
         {:ok, results} <- Lookup.results(final) do
      {:ok, %{results: Map.new(results, &service_ids/1), token: token}}
    end
  end

  defp attest(message, pins) do
    case Attestation.verify(message, pins, System.os_time(:second)) do
      {:ok, attested} -> {:ok, attested}
      {:error, reason} -> {:error, {:attestation_failed, reason}}
    end
  end

  defp service_ids({number, nil}), do: {number, nil}

  defp service_ids({number, %{pni: pni, aci: aci}}),
    do: {number, %{pni: {:pni, pni}, aci: aci && {:aci, aci}}}

  defp send_sealed(socket, noise, plaintext) do
    with {:ok, sealed, noise} <- Noise.seal(noise, plaintext),
         {:ok, socket} <- send_binary(socket, sealed) do
      {:ok, noise, socket}
    end
  end

  defp receive_response(socket, noise, response) do
    with {:ok, sealed, socket} <- receive_binary(socket),
         {:ok, plaintext, noise} <- open(noise, sealed),
         {:ok, response} <- merge(response, plaintext) do
      {:ok, response, noise, socket}
    end
  end

  # After the acknowledgement the client reads until a close: every further
  # binary message merges into the response (§6.2).
  defp receive_results(socket, noise, response) do
    case receive_frame(socket) do
      {:ok, {:binary, sealed}, socket} ->
        with {:ok, plaintext, noise} <- open(noise, sealed),
             {:ok, response} <- merge(response || %Lookup.Response{}, plaintext) do
          receive_results(socket, noise, response)
        end

      {:closed, 1000, _reason, socket} when response != nil ->
        {:ok, response, socket}

      {:closed, :no_frame, _reason, socket} when response != nil ->
        {:ok, response, socket}

      {:closed, code, reason, _socket} when is_integer(code) and code != 1000 ->
        Lookup.close(code, reason)

      {:closed, _code, _reason, _socket} ->
        {:error, :protocol_error}

      {:error, _} = error ->
        error
    end
  end

  defp open(noise, sealed) do
    case Noise.open(noise, sealed) do
      {:ok, plaintext, noise} -> {:ok, plaintext, noise}
      {:error, _} -> {:error, :protocol_error}
    end
  end

  defp merge(response, plaintext) do
    case Lookup.merge_response(response, plaintext) do
      {:ok, response} -> {:ok, response}
      {:error, :malformed} -> {:error, :protocol_error}
    end
  end

  # A binary message before the results; a close here ends the lookup.
  defp receive_binary(socket) do
    case receive_frame(socket) do
      {:ok, {:binary, bytes}, socket} -> {:ok, bytes, socket}
      {:closed, 1000, _reason, _socket} -> {:error, :protocol_error}
      {:closed, code, reason, _socket} when is_integer(code) -> Lookup.close(code, reason)
      {:closed, _code, _reason, _socket} -> {:error, :protocol_error}
      {:error, _} = error -> error
    end
  end

  # --- WebSocket -----------------------------------------------------------

  defp connect(credentials, pins, environment, opts, deadline) do
    host = Keyword.get(opts, :host, Endpoints.host(environment, :cdsi))
    port = Keyword.get(opts, :port, 443)
    path = "/v1/" <> Base.encode16(pins.mrenclave, case: :lower) <> "/discovery"

    tls =
      [versions: [:"tlsv1.3"]]
      |> then(fn tls -> if roots = opts[:roots], do: [{:roots, roots} | tls], else: tls end)
      |> Endpoints.tls_options()

    headers = [
      {"user-agent", Keyword.get(opts, :user_agent, @default_user_agent)},
      {"authorization", Credentials.authorization(credentials)}
    ]

    with {:ok, conn} <-
           Mint.HTTP.connect(:https, host, port,
             mode: :passive,
             protocols: [:http1],
             transport_opts: tls ++ [timeout: remaining(deadline)]
           )
           |> transport_result(),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(:wss, conn, path, headers) |> transport_result(),
         {:ok, conn, status, response_headers, early} <-
           upgrade_response(conn, ref, {nil, [], []}, deadline) do
      case Mint.WebSocket.new(conn, ref, status, response_headers, mode: :passive) do
        {:ok, conn, ws} ->
          socket = %{
            conn: conn,
            ref: ref,
            ws: ws,
            frames: [],
            deadline: deadline,
            max_message_bytes: Keyword.get(opts, :max_message_bytes, 8 * 1024 * 1024)
          }

          # Frames that arrived with the upgrade response, such as the
          # attestation message, are decoded first.
          case decode(socket, early) do
            {:ok, socket} ->
              {:ok, socket}

            error ->
              Mint.HTTP.close(conn)
              error
          end

        {:error, conn, %Mint.WebSocket.UpgradeFailureError{status_code: code}} ->
          Mint.HTTP.close(conn)
          {:error, upgrade_error(code, response_headers)}

        {:error, conn, reason} ->
          Mint.HTTP.close(conn)
          {:error, {:transport, reason}}
      end
    end
  end

  defp transport_result({:ok, conn}), do: {:ok, conn}
  defp transport_result({:ok, conn, ref}), do: {:ok, conn, ref}

  defp transport_result({:error, conn, reason}) do
    Mint.HTTP.close(conn)
    {:error, {:transport, reason}}
  end

  defp transport_result({:error, reason}), do: {:error, {:transport, reason}}

  defp upgrade_response(conn, ref, acc, deadline) do
    case Mint.HTTP.recv(conn, 0, remaining(deadline)) do
      {:ok, conn, responses} ->
        {{status, headers, data}, done} =
          Enum.reduce(responses, {acc, false}, fn
            {:status, ^ref, status}, {{_, headers, data}, done} ->
              {{status, headers, data}, done}

            {:headers, ^ref, more}, {{status, headers, data}, done} ->
              {{status, headers ++ more, data}, done}

            {:data, ^ref, more}, {{status, headers, data}, done} ->
              {{status, headers, [data, more]}, done}

            {:done, ^ref}, {acc, _} ->
              {acc, true}

            _other, acc ->
              acc
          end)

        if done,
          do: {:ok, conn, status, headers, data},
          else: upgrade_response(conn, ref, {status, headers, data}, deadline)

      {:error, conn, reason, _responses} ->
        Mint.HTTP.close(conn)
        {:error, timeout_or_transport(reason)}
    end
  end

  defp upgrade_error(code, headers) do
    response = %Response{
      status: code,
      headers: Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
    }

    case Response.outcome(response) do
      {:rate_limited, seconds} -> {:rate_limited, seconds}
      outcome when outcome in [:unauthorized, :forbidden] -> :unauthorized
      _ -> {:upgrade_rejected, code}
    end
  end

  # Returns `{:ok, frame, socket}` for a complete data message,
  # `{:closed, code | :no_frame, reason, socket}` for a close, or an error.
  # Pings are answered; a text frame is a protocol error (§3).
  defp receive_frame(%{frames: [frame | rest]} = socket) do
    socket = %{socket | frames: rest}

    case frame do
      {:binary, bytes} ->
        {:ok, {:binary, bytes}, socket}

      {:ping, data} ->
        case send_frame(socket, {:pong, data}) do
          {:ok, socket} -> receive_frame(socket)
          error -> error
        end

      {:pong, _} ->
        receive_frame(socket)

      {:close, code, reason} ->
        {:closed, code, reason, socket}

      {:text, _} ->
        {:error, :protocol_error}

      {:error, _reason} ->
        {:error, :protocol_error}
    end
  end

  defp receive_frame(socket) do
    case Mint.WebSocket.recv(socket.conn, 0, remaining(socket.deadline)) do
      {:ok, conn, responses} ->
        socket = %{socket | conn: conn}

        data = for {:data, ref, data} <- responses, ref == socket.ref, do: data
        closed? = Enum.any?(responses, &match?({:done, _}, &1))

        with {:ok, socket} <- decode(socket, data) do
          cond do
            socket.frames != [] -> receive_frame(socket)
            closed? -> {:closed, :no_frame, "", socket}
            true -> receive_frame(socket)
          end
        end

      {:error, _conn, %Mint.TransportError{reason: :closed}, _responses} ->
        {:closed, :no_frame, "", socket}

      {:error, _conn, reason, _responses} ->
        {:error, timeout_or_transport(reason)}
    end
  end

  defp decode(socket, data) when data == [] or data == "", do: {:ok, socket}

  defp decode(socket, data) do
    case Mint.WebSocket.decode(socket.ws, IO.iodata_to_binary(data)) do
      {:ok, ws, frames} ->
        if Enum.any?(frames, &oversized?(&1, socket.max_message_bytes)),
          do: {:error, :protocol_error},
          else: {:ok, %{socket | ws: ws, frames: socket.frames ++ frames}}

      {:error, _ws, _reason} ->
        {:error, :protocol_error}
    end
  end

  defp oversized?({:binary, bytes}, max), do: byte_size(bytes) > max
  defp oversized?(_frame, _max), do: false

  defp send_binary(socket, bytes), do: send_frame(socket, {:binary, bytes})

  defp send_frame(socket, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(socket.ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(socket.conn, socket.ref, data) do
      {:ok, %{socket | ws: ws, conn: conn}}
    else
      {:error, _state, reason} -> {:error, {:transport, reason}}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp timeout_or_transport(%Mint.TransportError{reason: :timeout}), do: :timeout
  defp timeout_or_transport(:timeout), do: :timeout
  defp timeout_or_transport(reason), do: {:transport, reason}
end
