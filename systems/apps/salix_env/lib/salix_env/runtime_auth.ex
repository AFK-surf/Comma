defmodule SalixEnv.RuntimeAuth do
  @moduledoc """
  Strict, credential-free contract for Connector-owned runtime authentication.

  Native providers own ordinary self-configured runtime credentials. A managed
  organization binding delivers its typed credential projection separately.
  This module accepts only the
  bounded state, ceremony, input-offer, and receipt fields Salix may relay;
  arbitrary provider payloads, commands, paths, account details, and tokens are
  rejected rather than projected.

  The retired connector models are historical evidence only; see
  `tla/connector/README.md`. Contract changes require runtime regression tests.
  """

  @snapshot_required ~w(schema_version status requires_openai_auth observed_at)
  @snapshot_optional ~w(mode issue backend)
  @snapshot_fields @snapshot_required ++ @snapshot_optional
  @statuses ~w(unknown unauthenticated configured pending authenticated not_required error)
  @modes ~w(chatgpt api_key amazon_bedrock other)
  @issues ~w(login_failed login_timeout auth_probe_failed)
  @flow "device_code"
  @codex_verification_url "https://auth.openai.com/codex/device"
  @connector_attempt_ttl_ms 15 * 60 * 1_000
  @ceremony_clock_skew_ms 60_000
  @max_timestamp 9_999_999_999_999
  @max_attempt_id_bytes 128
  @max_verification_url_bytes 2_048
  @max_user_code_bytes 128

  @input_issues [
    ""
    | ~w(target_changed invalid_format runtime_busy applying attempt_unavailable canceled native_writer_unavailable native_storage_unsupported native_login_required storage_prepare_failed storage_commit_failed storage_sync_failed native_helper_failed provider_unavailable native_probe_failed verification_timeout credentials_missing credentials_rejected permission_denied quota_exhausted rate_limited verification_model_unavailable native_refresh_failed storage_operation_failed storage_lock_changed)
  ]

  @type operation ::
          :read
          | :status
          | :verify
          | :login_start
          | :login_cancel
          | :input_begin
          | :input_submit
          | :input_cancel

  @spec validate_snapshot(term()) ::
          {:ok, %{required(String.t()) => term()}}
          | {:error, :invalid_runtime_auth_snapshot}
  def validate_snapshot(snapshot) when is_map(snapshot) do
    snapshot = stringify_keys(snapshot)
    keys = Map.keys(snapshot)

    if Enum.sort(keys) ==
         Enum.sort(
           @snapshot_required ++ Enum.filter(@snapshot_optional, &Map.has_key?(snapshot, &1))
         ) and
         snapshot["schema_version"] == 1 and
         snapshot["status"] in @statuses and
         is_boolean(snapshot["requires_openai_auth"]) and
         valid_timestamp?(snapshot["observed_at"]) and
         optional_enum?(snapshot, "mode", @modes) and
         optional_enum?(snapshot, "issue", @issues) and
         optional_enum?(snapshot, "backend", ~w(chatgpt openai openrouter anthropic other)) do
      {:ok, Map.take(snapshot, @snapshot_fields)}
    else
      {:error, :invalid_runtime_auth_snapshot}
    end
  rescue
    _exception -> {:error, :invalid_runtime_auth_snapshot}
  end

  def validate_snapshot(_snapshot), do: {:error, :invalid_runtime_auth_snapshot}

  @spec validate_result(operation(), term()) ::
          {:ok, %{required(String.t()) => term()}}
          | {:error, :invalid_runtime_auth_response}
  def validate_result(operation, result)
      when operation in [
             :read,
             :status,
             :verify,
             :login_start,
             :login_cancel,
             :input_begin,
             :input_submit,
             :input_cancel
           ] and is_map(result) do
    result = stringify_keys(result)

    case operation do
      :status -> validate_status_result(result)
      :verify -> validate_verification_result(result)
      :read -> validate_read_result(result)
      :login_start -> validate_start_result(result)
      :login_cancel -> validate_cancel_result(result)
      :input_begin -> validate_input_offer(result)
      operation when operation in [:input_submit, :input_cancel] -> validate_input_outcome(result)
    end
  rescue
    _exception -> {:error, :invalid_runtime_auth_response}
  end

  def validate_result(_operation, _result), do: {:error, :invalid_runtime_auth_response}

  defp validate_verification_result(result) do
    if exact_keys?(result, ~w(status issue)) and
         result["status"] in ~w(authenticated unauthenticated error) and
         result["issue"] in @input_issues,
       do: {:ok, result},
       else: {:error, :invalid_runtime_auth_response}
  end

  defp validate_status_result(result) do
    with true <-
           exact_keys?(result, ~w(provider auth native_ready dispatch_ready methods attempt)),
         true <- result["provider"] in ~w(codex pi claude),
         {:ok, _} <- validate_snapshot(result["auth"]),
         true <- is_boolean(result["native_ready"]) and is_boolean(result["dispatch_ready"]),
         true <-
           not result["dispatch_ready"] or
             (result["native_ready"] and
                result["auth"]["status"] in ~w(authenticated not_required)),
         methods when is_list(methods) and length(methods) <= 8 <- result["methods"],
         true <- Enum.all?(methods, &valid_method?(&1, result["provider"])),
         true <- valid_private_attempt?(result["attempt"]) do
      {:ok, result}
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  end

  defp valid_method?(method, provider) when is_map(method) do
    exact_keys?(method, ~w(backend method form schema_version)) and method["schema_version"] == 1 and
      ((provider == "codex" and method["backend"] == "chatgpt" and
          method["method"] == "native_login" and method["form"] == "device_code") or
         (provider == "claude" and method["backend"] == "anthropic" and
            method["method"] == "native_login" and method["form"] == "authorization_code") or
         (provider == "pi" and method["backend"] == "openrouter" and method["method"] == "verify" and
            method["form"] == "api_key") or
         (provider == "claude" and method["backend"] in ~w(anthropic openrouter) and
            method["method"] == "verify" and method["form"] == "api_key") or
         (method["method"] == "credential_import" and
            supported_input_form?(Map.put(method, "provider", provider))))
  end

  defp valid_method?(_method, _provider), do: false

  defp valid_private_attempt?(nil), do: true

  defp valid_private_attempt?(attempt) when is_map(attempt) do
    exact_keys?(
      attempt,
      ~w(attempt_id expires_at owned phase save_result issue) ++
        if(Map.has_key?(attempt, "ceremony"), do: ["ceremony"], else: [])
    ) and
      valid_private_ceremony?(attempt) and
      validate_attempt_id(attempt["attempt_id"]) == :ok and
      valid_ceremony_expiry?(attempt["expires_at"]) and
      is_boolean(attempt["owned"]) and
      attempt["phase"] in ~w(awaiting_user receiving applying verifying completed canceled expired failed outcome_unknown) and
      attempt["save_result"] in ~w(not_requested not_committed committed unknown) and
      attempt["issue"] in @input_issues
  end

  defp valid_private_attempt?(_attempt), do: false

  defp valid_private_ceremony?(%{"ceremony" => ceremony, "owned" => true})
       when is_map(ceremony) do
    (exact_keys?(ceremony, ~w(verification_url user_code)) and
       ceremony["verification_url"] == @codex_verification_url and
       valid_user_code?(ceremony["user_code"])) or
      (exact_keys?(ceremony, ~w(verification_url user_code input)) and
         valid_claude_verification_url?(ceremony["verification_url"]) and
         ceremony["user_code"] == "" and match?({:ok, _}, validate_input_offer(ceremony["input"])))
  end

  defp valid_private_ceremony?(attempt), do: not Map.has_key?(attempt, "ceremony")

  @spec validate_flow(term()) :: :ok | {:error, :invalid_runtime_auth_flow}
  def validate_flow(@flow), do: :ok
  def validate_flow(_flow), do: {:error, :invalid_runtime_auth_flow}

  @spec validate_attempt_id(term()) :: :ok | {:error, :invalid_runtime_auth_attempt_id}
  def validate_attempt_id(attempt_id) when is_binary(attempt_id) do
    if byte_size(attempt_id) in 1..@max_attempt_id_bytes and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, attempt_id),
       do: :ok,
       else: {:error, :invalid_runtime_auth_attempt_id}
  rescue
    _exception -> {:error, :invalid_runtime_auth_attempt_id}
  end

  def validate_attempt_id(_attempt_id), do: {:error, :invalid_runtime_auth_attempt_id}

  @input_context_strings ~w(actor_id tenant_id project_id target_kind workload_id device_id runtime_id provider backend method form attempt_id runtime_instance_id generation connection_epoch allocation_id allocation_generation native_generation auth_epoch)
  @input_context_numbers ~w(schema_version sequence expires_at)

  defp validate_input_offer(result) do
    context = result["context"]

    with true <- exact_keys?(result, ~w(context public_key phase save_result)),
         true <- result["phase"] == "awaiting_user" and result["save_result"] == "not_committed",
         true <- is_map(context),
         true <- exact_keys?(context, @input_context_strings ++ @input_context_numbers),
         true <-
           Enum.all?(@input_context_strings, fn key ->
             value = context[key]
             is_binary(value) and String.valid?(value) and byte_size(value) <= 256
           end),
         true <-
           Enum.all?(
             ~w(actor_id tenant_id project_id attempt_id generation connection_epoch),
             &(context[&1] != "")
           ),
         true <- context["target_kind"] in ~w(compute_workload connected_runtime),
         true <- supported_input_context?(context),
         true <- context["schema_version"] == 1 and context["sequence"] == 1,
         true <- valid_ceremony_expiry?(context["expires_at"]),
         :ok <- validate_attempt_id(context["attempt_id"]),
         key when is_binary(key) <- result["public_key"],
         {:ok, <<4, _::binary-size(64)>>} <- Base.decode64(key) do
      {:ok, result}
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  end

  defp supported_input_form?(%{
         "provider" => "codex",
         "backend" => backend,
         "form" => "codex_auth_file"
       }),
       do: backend in ~w(chatgpt openai)

  defp supported_input_form?(%{
         "provider" => "pi",
         "backend" => "openrouter",
         "form" => form
       })
       when form in ~w(pi_auth_entry api_key),
       do: true

  defp supported_input_form?(%{
         "provider" => "codex",
         "backend" => "openai",
         "form" => "api_key"
       }),
       do: true

  defp supported_input_form?(%{
         "provider" => "claude",
         "backend" => "anthropic",
         "form" => form
       })
       when form in ~w(api_key claude_backend_config claude_credentials_file),
       do: true

  defp supported_input_form?(%{
         "provider" => "claude",
         "backend" => "openrouter",
         "form" => form
       })
       when form in ~w(api_key claude_backend_config),
       do: true

  defp supported_input_form?(_context), do: false

  defp supported_input_context?(%{
         "provider" => "claude",
         "backend" => "anthropic",
         "method" => "native_login",
         "form" => "authorization_code"
       }),
       do: true

  defp supported_input_context?(%{"method" => "credential_import"} = context),
    do: supported_input_form?(context)

  defp supported_input_context?(_context), do: false

  defp validate_input_outcome(result) do
    if exact_keys?(result, ~w(save_result issue)) and
         result["save_result"] in ~w(not_requested not_committed committed unknown) and
         result["issue"] in @input_issues do
      {:ok, result}
    else
      {:error, :invalid_runtime_auth_response}
    end
  end

  defp validate_read_result(result) do
    active_fields = ~w(attempt_id flow expires_at)
    allowed = ["auth" | active_fields]
    active_count = Enum.count(active_fields, &Map.has_key?(result, &1))

    with true <- exact_subset?(result, allowed),
         true <- Map.has_key?(result, "auth"),
         true <- active_count in [0, length(active_fields)],
         {:ok, auth} <- validate_snapshot(result["auth"]),
         :ok <- validate_optional_attempt(result, active_count > 0) do
      {:ok, Map.put(result, "auth", auth)}
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  end

  defp validate_start_result(result) do
    if Map.has_key?(result, "context") do
      validate_claude_start_result(result)
    else
      validate_codex_start_result(result)
    end
  end

  defp validate_codex_start_result(result) do
    required =
      ~w(auth attempt_id flow verification_url user_code expires_at reused)

    with true <- exact_keys?(result, required),
         {:ok, auth} <- validate_snapshot(result["auth"]),
         :ok <- validate_attempt_id(result["attempt_id"]),
         :ok <- validate_flow(result["flow"]),
         true <- valid_verification_url?(result["verification_url"]),
         true <- valid_user_code?(result["user_code"]),
         true <- valid_ceremony_expiry?(result["expires_at"]),
         true <- is_boolean(result["reused"]) do
      {:ok, Map.put(result, "auth", auth)}
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  end

  defp validate_claude_start_result(result) do
    offer = Map.drop(result, ["verification_url"])

    with true <- exact_keys?(result, ~w(context public_key phase save_result verification_url)),
         {:ok, _offer} <- validate_input_offer(offer),
         true <- result["context"]["provider"] == "claude",
         true <- result["context"]["backend"] == "anthropic",
         true <- result["context"]["method"] == "native_login",
         true <- result["context"]["form"] == "authorization_code",
         true <- valid_claude_verification_url?(result["verification_url"]) do
      {:ok, result}
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  end

  defp valid_claude_verification_url?(value) when is_binary(value) do
    with true <- byte_size(value) in 1..@max_verification_url_bytes,
         %URI{
           scheme: "https",
           host: "claude.com",
           path: "/cai/oauth/authorize",
           fragment: nil,
           query: query
         }
         when is_binary(query) <- URI.parse(value),
         pairs <- Enum.to_list(URI.query_decoder(query)),
         true <- length(pairs) == 8 and length(Enum.uniq_by(pairs, &elem(&1, 0))) == 8,
         params <- Map.new(pairs),
         true <-
           Map.keys(params) |> Enum.sort() ==
             ~w(client_id code code_challenge code_challenge_method redirect_uri response_type scope state),
         true <- params["code"] == "true" and params["response_type"] == "code",
         true <- params["redirect_uri"] == "https://platform.claude.com/oauth/code/callback",
         true <- params["code_challenge_method"] == "S256",
         true <-
           Enum.all?(
             ~w(client_id code_challenge scope state),
             &(is_binary(params[&1]) and params[&1] != "")
           ) do
      true
    else
      _ -> false
    end
  rescue
    _exception -> false
  end

  defp valid_claude_verification_url?(_value), do: false

  defp validate_cancel_result(result) do
    required = ~w(auth attempt_id canceled)

    with true <- exact_keys?(result, required),
         {:ok, auth} <- validate_snapshot(result["auth"]),
         :ok <- validate_attempt_id(result["attempt_id"]),
         true <- result["canceled"] == true do
      {:ok, Map.put(result, "auth", auth)}
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  end

  defp validate_optional_attempt(_result, false), do: :ok

  defp validate_optional_attempt(result, true) do
    with :ok <- validate_attempt_id(result["attempt_id"]),
         :ok <- validate_flow(result["flow"]),
         true <- valid_ceremony_expiry?(result["expires_at"]) do
      :ok
    else
      _ -> {:error, :invalid_runtime_auth_response}
    end
  end

  defp valid_verification_url?(url) when is_binary(url),
    do:
      byte_size(url) in 1..@max_verification_url_bytes and String.valid?(url) and
        url == @codex_verification_url

  defp valid_verification_url?(_url), do: false

  defp valid_user_code?(code) when is_binary(code) do
    byte_size(code) in 1..@max_user_code_bytes and String.valid?(code) and
      String.trim(code) == code and not Regex.match?(~r/[\x00-\x20\x7F]/u, code)
  end

  defp valid_user_code?(_code), do: false

  defp valid_timestamp?(timestamp),
    do: is_integer(timestamp) and timestamp > 0 and timestamp <= @max_timestamp

  # Expired attempts remain valid transport responses so callers can clear and
  # best-effort cancel them. Only the future retention window is bounded.
  defp valid_ceremony_expiry?(timestamp) do
    valid_timestamp?(timestamp) and
      timestamp <=
        System.system_time(:millisecond) + @connector_attempt_ttl_ms + @ceremony_clock_skew_ms
  end

  defp optional_enum?(map, key, values) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> value in values
    end
  end

  defp exact_keys?(map, fields), do: Enum.sort(Map.keys(map)) == Enum.sort(fields)

  defp exact_subset?(map, fields),
    do: Enum.all?(Map.keys(map), &(&1 in fields))

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {key, value}
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {_key, _value} -> raise Protocol.UndefinedError, protocol: String.Chars, value: map
    end)
  end
end
