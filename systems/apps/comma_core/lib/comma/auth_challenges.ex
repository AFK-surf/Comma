defmodule Comma.AuthChallenges do
  @moduledoc "Passwordless email login challenges for Comma users."

  alias Comma.Accounts
  alias Comma.Accounts.Email
  alias Comma.Accounts.{SessionClientMetadata, SessionIssuer}

  @default_ttl_seconds 900
  @default_max_attempts 5
  @default_session_ttl_seconds 30 * 24 * 60 * 60
  @default_resend_cooldown_seconds 60
  @default_email_request_limit 5
  @default_email_request_window_seconds 15 * 60
  # `conn.remote_ip` is the authenticated network peer. Behind Cloudflare and
  # GCLB that peer can be shared by many users, so keep this coarse backstop
  # above the per-email limit until the edge provides a verifiable client IP.
  @default_ip_request_limit 500
  @default_ip_request_window_seconds 15 * 60
  @default_verification_failure_limit 10
  @default_verification_failure_window_seconds 15 * 60
  @default_provider_failure_threshold 5
  @default_provider_failure_window_seconds 60
  @default_provider_circuit_open_seconds 60

  # Only the SSH connection owner supplies the key and connection binding.
  def request_ssh_enrollment(attrs, binding) when is_binary(binding) do
    with {:ok, email} <- Email.normalize_recipient(attrs["email"]),
         {:ok, response} <-
           request_challenge(email, "ssh_enrollment", %{"binding" => binding}, attrs) do
      {:ok, response}
    end
  end

  def verify_ssh_enrollment(id, code, binding) do
    with true <- is_binary(code) and code =~ ~r/^\d{6}$/,
         {:ok, hashed} <- code_hash(id, "ssh_enrollment", code),
         {:ok, challenge} <- store_verify(id, hashed),
         :ok <- require_purpose(challenge, "ssh_enrollment"),
         true <- challenge["binding"] == binding,
         {:ok, user} <- user_for_email(challenge["email"]) do
      {:ok, user}
    else
      _ -> {:error, :invalid_verification_code}
    end
  end

  def request_email_login(attrs) when is_map(attrs) do
    with {:ok, email} <- Email.normalize_recipient(attrs["email"] || attrs[:email]),
         {:ok, response} <- request_challenge(email, "email_login", %{}, attrs) do
      {:ok, response}
    end
  end

  def verify_email_login(attrs) when is_map(attrs) do
    id = trim(attrs["challenge_id"] || attrs[:challenge_id])
    code = trim(attrs["code"] || attrs[:code])

    with true <- id != "" and code =~ ~r/^\d{6}$/,
         {:ok, hashed_code} <- code_hash(id, "email_login", code),
         {:ok, challenge} <- store_verify(id, hashed_code),
         :ok <- require_purpose(challenge, "email_login"),
         {:ok, user} <- user_for_email(challenge["email"]),
         {:ok, response} <-
           SessionIssuer.issue(
             user,
             Keyword.merge(
               [
                 auth_method: "email_otp",
                 ttl_seconds: session_ttl_seconds()
               ],
               SessionClientMetadata.options(attrs)
             )
           ) do
      {:ok, response}
    else
      false -> {:error, :invalid_verification_code}
      {:error, :invalid_code} -> {:error, :invalid_verification_code}
      {:error, :not_found} -> {:error, :invalid_verification_code}
      {:error, :too_many_attempts} -> {:error, :invalid_verification_code}
      {:error, :wrong_purpose} -> {:error, :invalid_verification_code}
      {:error, :rate_limited, retry_after} -> {:error, :rate_limited, retry_after}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec request_google_link_verification(map()) :: {:ok, map()} | {:error, term()}
  def request_google_link_verification(link_state) when is_map(link_state) do
    with {:ok, email} <- Email.normalize_recipient(link_state["email"] || link_state[:email]),
         true <- nonempty?(link_state["user_id"] || link_state[:user_id]),
         {:ok, response} <-
           request_challenge(
             email,
             "google_link",
             %{
               "user_id" => link_state["user_id"] || link_state[:user_id],
               "issuer" => link_state["issuer"] || link_state[:issuer],
               "subject" => link_state["subject"] || link_state[:subject],
               "email_verified" => link_state["email_verified"] || false,
               "hosted_domain" => link_state["hosted_domain"] || link_state[:hosted_domain],
               "client_kind" => link_state["client_kind"] || link_state[:client_kind],
               "client_platform" => link_state["client_platform"] || link_state[:client_platform]
             },
             link_state
           ) do
      {:ok,
       response
       |> Map.put("status", "otp_required")
       |> Map.put("email", email)}
    else
      false -> {:error, :invalid_google_identity}
      {:error, _reason} = error -> error
      {:error, _reason, _retry_after} = error -> error
    end
  end

  def request_google_link_verification(_link_state), do: {:error, :invalid_google_identity}

  @spec verify_google_link_challenge(map()) :: {:ok, map()} | {:error, atom() | term()}
  def verify_google_link_challenge(attrs) when is_map(attrs) do
    id = trim(attrs["challenge_id"] || attrs[:challenge_id])
    code = trim(attrs["code"] || attrs[:code])

    with true <- id != "" and code =~ ~r/^\d{6}$/,
         {:ok, hashed_code} <- code_hash(id, "google_link", code),
         {:ok, challenge} <- store_verify(id, hashed_code),
         :ok <- require_purpose(challenge, "google_link") do
      {:ok, challenge}
    else
      false ->
        {:error, :invalid_verification_code}

      {:error, reason} when reason in [:invalid_code, :not_found, :too_many_attempts] ->
        {:error, :invalid_verification_code}

      {:error, :wrong_purpose} ->
        {:error, :invalid_verification_code}

      {:error, :rate_limited, retry_after} ->
        {:error, :rate_limited, retry_after}

      {:error, _reason} = error ->
        error
    end
  end

  def verify_google_link_challenge(_attrs), do: {:error, :invalid_verification_code}

  defp request_challenge(email, purpose, extra, attrs) do
    with {:ok, code} <- verification_code(),
         id <- random_challenge_id(),
         {:ok, email_fingerprint} <- fingerprint("email", email),
         {:ok, ip_fingerprint} <- fingerprint("ip", remote_ip(attrs)),
         {:ok, challenge} <-
           challenge(id, email, email_fingerprint, code, purpose, extra),
         :ok <- store_reserve(challenge, ip_fingerprint) do
      deliver_challenge(email, code, id, purpose)
    end
  end

  defp challenge(id, email, email_fingerprint, code, purpose, extra) do
    with {:ok, hashed_code} <- code_hash(id, purpose, code) do
      {:ok,
       Map.merge(
         %{
           "id" => id,
           "purpose" => purpose,
           "email" => email,
           "email_fingerprint" => email_fingerprint,
           "code_hash" => hashed_code,
           "attempts" => 0
         },
         extra
       )}
    end
  end

  defp user_for_email(email) do
    if auto_create_users?() do
      Accounts.get_or_create_user_by_email(email)
    else
      Accounts.get_user_by_email(email)
    end
  end

  defp verification_code do
    <<n::32>> = :crypto.strong_rand_bytes(4)
    {:ok, n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")}
  end

  defp random_challenge_id,
    do: "comma_auth_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp code_hash(id, purpose, code) do
    with {:ok, secret} <- configured_secret(:secret) do
      {:ok,
       :crypto.mac(:hmac, :sha256, secret, id <> ":" <> purpose <> ":" <> code)
       |> Base.encode16(case: :lower)}
    end
  end

  defp fingerprint(kind, value) do
    with {:ok, secret} <- configured_secret(:rate_limit_secret) do
      {:ok,
       :crypto.mac(:hmac, :sha256, secret, kind <> ":" <> value)
       |> Base.url_encode64(padding: false)}
    end
  end

  defp ttl_seconds, do: get_in(auth_config(), [:challenge_ttl_seconds]) || @default_ttl_seconds
  defp max_attempts, do: get_in(auth_config(), [:max_attempts]) || @default_max_attempts

  defp session_ttl_seconds do
    get_in(auth_config(), [:session_ttl_seconds]) || @default_session_ttl_seconds
  end

  defp auto_create_users?, do: get_in(auth_config(), [:auto_create_users]) != false
  defp expose_codes?, do: get_in(auth_config(), [:expose_codes]) == true

  defp store do
    get_in(auth_config(), [:challenge_store]) || Comma.AuthChallengeStore.Redis
  end

  defp email_delivery do
    get_in(auth_config(), [:email_delivery]) || Comma.EmailDelivery.Postmark
  end

  defp store_reserve(challenge, ip_fingerprint) do
    case observe(:redis_challenge, fn ->
           store().reserve(challenge, ttl_seconds(), request_limit_options(ip_fingerprint))
         end) do
      :ok -> :ok
      {:error, :rate_limited, _retry_after} = error -> error
      {:error, :provider_unavailable, _retry_after} = error -> error
      {:error, _internal_reason} -> {:error, :auth_unavailable}
    end
  end

  defp store_verify(id, hashed_code) do
    case observe(:redis_challenge, fn ->
           store().verify(id, hashed_code, max_attempts(), verification_limit_options())
         end) do
      {:ok, _challenge} = success ->
        success

      {:error, reason} = error when reason in [:not_found, :invalid_code, :too_many_attempts] ->
        error

      {:error, :rate_limited, _retry_after} = error ->
        error

      {:error, _internal_reason} ->
        {:error, :auth_unavailable}
    end
  end

  defp send_login_code(email, code, id, purpose) do
    observe(email_delivery_operation(), fn ->
      email_delivery().send_login_code(email, code, %{
        challenge_id: id,
        purpose: purpose,
        ttl_seconds: ttl_seconds()
      })
    end)
  end

  defp email_delivery_operation do
    case email_delivery() do
      Comma.EmailDelivery.Postmark -> :postmark_delivery
      Comma.EmailDelivery.SMTP -> :smtp_delivery
      Comma.EmailDelivery.Logger -> :test_email_delivery
      _other -> :email_delivery
    end
  end

  defp deliver_challenge(email, code, id, purpose) do
    response = challenge_response(id, code)

    case send_login_code(email, code, id, purpose) do
      :ok ->
        record_delivery(:ok)
        {:ok, response}

      {:error, {:transport, _reason}} ->
        # The provider may have accepted the request before the connection
        # failed. Do not auto-retry and double-deliver; leave the bounded
        # challenge usable in case the message arrives.
        record_delivery(:error)
        {:ok, response}

      {:error, :recipient_rejected} ->
        # This challenge cannot be delivered, but a recipient-specific
        # rejection says nothing about provider availability for other users.
        delete_challenge(id)
        {:error, :email_delivery_unavailable}

      {:error, _reason} ->
        record_delivery(:error)
        delete_challenge(id)
        {:error, :email_delivery_unavailable}
    end
  end

  defp challenge_response(id, code) do
    response = %{"challenge_id" => id}
    if expose_codes?(), do: Map.put(response, "code", code), else: response
  end

  defp record_delivery(outcome) do
    observe(:redis_challenge, fn -> store().record_delivery(outcome, circuit_options()) end)
  end

  defp delete_challenge(id) do
    observe(:redis_challenge, fn -> store().delete(id) end)
  end

  defp observe(operation, fun) do
    started = System.monotonic_time()

    try do
      result = fun.()

      CommaProduct.Telemetry.emit_operation(
        operation,
        dependency_outcome(result),
        System.monotonic_time() - started
      )

      result
    rescue
      exception ->
        CommaProduct.Telemetry.emit_operation(
          operation,
          :error,
          System.monotonic_time() - started
        )

        reraise exception, __STACKTRACE__
    end
  end

  defp dependency_outcome({:error, reason})
       when reason in [:invalid_code, :not_found, :too_many_attempts],
       do: :rejected

  defp dependency_outcome({:error, :rate_limited, _retry_after}), do: :rate_limited
  defp dependency_outcome({:error, :provider_unavailable, _retry_after}), do: :unavailable
  defp dependency_outcome({:ok, :circuit_open}), do: :unavailable
  defp dependency_outcome({:error, :timeout}), do: :timeout
  defp dependency_outcome({:error, _reason}), do: :error
  defp dependency_outcome(_result), do: :ok

  defp request_limit_options(ip_fingerprint) do
    %{
      ip_fingerprint: ip_fingerprint,
      resend_cooldown_seconds:
        nonnegative_config(:resend_cooldown_seconds, @default_resend_cooldown_seconds),
      email_request_limit: positive_config(:email_request_limit, @default_email_request_limit),
      email_request_window_seconds:
        positive_config(:email_request_window_seconds, @default_email_request_window_seconds),
      ip_request_limit: positive_config(:ip_request_limit, @default_ip_request_limit),
      ip_request_window_seconds:
        positive_config(:ip_request_window_seconds, @default_ip_request_window_seconds)
    }
  end

  defp verification_limit_options do
    %{
      verification_failure_limit:
        positive_config(:verification_failure_limit, @default_verification_failure_limit),
      verification_failure_window_seconds:
        positive_config(
          :verification_failure_window_seconds,
          @default_verification_failure_window_seconds
        )
    }
  end

  defp circuit_options do
    %{
      provider_failure_threshold:
        positive_config(:provider_failure_threshold, @default_provider_failure_threshold),
      provider_failure_window_seconds:
        positive_config(
          :provider_failure_window_seconds,
          @default_provider_failure_window_seconds
        ),
      provider_circuit_open_seconds:
        positive_config(:provider_circuit_open_seconds, @default_provider_circuit_open_seconds)
    }
  end

  defp positive_config(key, default) do
    case get_in(auth_config(), [key]) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp nonnegative_config(key, default) do
    case get_in(auth_config(), [key]) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end

  defp configured_secret(key) do
    case get_in(auth_config(), [key]) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :auth_not_configured}
          secret -> {:ok, secret}
        end

      _other ->
        {:error, :auth_not_configured}
    end
  end

  defp remote_ip(attrs) do
    value = attrs["remote_ip"] || attrs[:remote_ip] || "unknown"

    case trim(value) do
      "" -> "unknown"
      normalized -> normalized
    end
  end

  defp auth_config, do: Application.get_env(:comma_core, :auth, [])
  defp require_purpose(%{"purpose" => purpose}, purpose), do: :ok
  defp require_purpose(_challenge, _purpose), do: {:error, :wrong_purpose}
  defp nonempty?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty?(_value), do: false
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""
end
