defmodule SalixEnv.VM.Providers.Cloudflare.Client do
  @moduledoc """
  Client for the Salix-owned Cloudflare Sandbox gateway Worker.

  The BEAM side talks only to the Worker internal API. It does not use the
  Cloudflare SDK and does not own tenant, group, billing, or default-provider
  semantics.
  """

  @enforce_keys [:base_url, :secret]
  defstruct base_url: nil,
            secret: nil,
            profile_key: "cf-standard-2",
            group_id: nil,
            worker_name: nil,
            worker_version_id: nil,
            max_retries: 2,
            backoff_ms: 250,
            req_options: []

  @type t :: %__MODULE__{
          base_url: String.t(),
          secret: String.t(),
          profile_key: String.t(),
          group_id: String.t() | nil,
          worker_name: String.t() | nil,
          worker_version_id: String.t() | nil,
          max_retries: non_neg_integer(),
          backoff_ms: pos_integer(),
          req_options: keyword()
        }

  @type signed_request :: %{url: String.t(), headers: [{String.t(), String.t()}]}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    cfg =
      case Application.get_env(:salix_env, :cloudflare_vm_gateway, []) do
        cfg when is_list(cfg) -> cfg
        cfg when is_map(cfg) -> Map.to_list(cfg)
      end

    merged = Keyword.merge(cfg, opts)

    base_url =
      Keyword.get(merged, :base_url) ||
        raise ArgumentError,
              "Cloudflare VM gateway client requires :base_url (config :salix_env, :cloudflare_vm_gateway or new/1 opts)"

    secret =
      Keyword.get(merged, :secret) ||
        raise ArgumentError,
              "Cloudflare VM gateway client requires :secret (config :salix_env, :cloudflare_vm_gateway or new/1 opts)"

    %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      secret: secret,
      profile_key: Keyword.get(merged, :profile_key, "cf-standard-2"),
      group_id: Keyword.get(merged, :group_id),
      worker_name: Keyword.get(merged, :worker_name),
      worker_version_id: Keyword.get(merged, :worker_version_id),
      max_retries: Keyword.get(merged, :max_retries, 2),
      backoff_ms: Keyword.get(merged, :backoff_ms, 250),
      req_options: Keyword.get(merged, :req_options, [])
    }
  end

  @spec ensure(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure(%__MODULE__{} = client, sandbox_id, opts \\ []) do
    body =
      %{"sandbox_id" => sandbox_id}
      |> maybe_put("keep_alive", Keyword.get(opts, :keep_alive))

    case request_json(client, :post, sandbox_collection_path(client), body, sandbox_id) do
      # The Gateway answers 404 on the sandbox collection only when it does not
      # serve this profile: a pre-profile Worker or a profile it does not know.
      # The caller fails closed instead of retrying until its provisioning budget ends.
      {:error, {:api_error, 404, _code, _message}} ->
        {:error, {:gateway_profile_unsupported, client.profile_key}}

      {:error, {:api_error, 404, _body}} ->
        {:error, {:gateway_profile_unsupported, client.profile_key}}

      result ->
        result
    end
  end

  @spec status(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def status(%__MODULE__{} = client, sandbox_id),
    do: request_json(client, :get, sandbox_path(client, sandbox_id, "status"), nil, sandbox_id)

  @spec destroy(t(), String.t()) :: :ok | {:error, term()}
  def destroy(%__MODULE__{} = client, sandbox_id, opts \\ []) do
    case request_json(
           client,
           :post,
           sandbox_path(client, sandbox_id, "destroy"),
           %{},
           sandbox_id,
           Keyword.get(opts, :purpose, :normal)
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec checkpoint(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def checkpoint(%__MODULE__{} = client, sandbox_id, opts \\ []) do
    case archive_get(client, sandbox_id) do
      {:ok, archive} ->
        {:ok, %{"archive" => archive}}

      {:error, reason} ->
        if Keyword.get(opts, :provider_neutral_required, false) do
          {:error, reason}
        else
          body = %{"dir" => Keyword.get(opts, :dir, "/workspace")}

          request_json(
            client,
            :post,
            sandbox_path(client, sandbox_id, "checkpoint"),
            body,
            sandbox_id
          )
        end
    end
  end

  @spec backup(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def backup(%__MODULE__{} = client, sandbox_id, opts \\ []) do
    body = %{"dir" => Keyword.get(opts, :dir, "/workspace")}
    request_json(client, :post, sandbox_path(client, sandbox_id, "checkpoint"), body, sandbox_id)
  end

  @spec restore(t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def restore(%__MODULE__{} = client, sandbox_id, %{"type" => "connector_tar_gz"} = archive),
    do: archive_put(client, sandbox_id, archive)

  def restore(%__MODULE__{} = client, sandbox_id, archive),
    do:
      request_json(
        client,
        :post,
        sandbox_path(client, sandbox_id, "restore"),
        %{"archive" => archive},
        sandbox_id
      )

  @spec keepalive(t(), String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def keepalive(%__MODULE__{} = client, sandbox_id, keep_alive, opts \\ []),
    do:
      request_json(
        client,
        :post,
        sandbox_path(client, sandbox_id, "keepalive"),
        %{
          "keep_alive" => keep_alive
        },
        sandbox_id,
        Keyword.get(opts, :purpose, :normal)
      )

  @spec proxy(t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def proxy(%__MODULE__{} = client, sandbox_id, path, opts \\ []) do
    proxy_path = sandbox_path(client, sandbox_id, "proxy/" <> String.trim_leading(path, "/"))
    method = Keyword.get(opts, :method, :get)
    body = Keyword.get(opts, :body)
    encoded_body = encode_body(body)

    with_gateway_attempt(client, Keyword.get(opts, :purpose, :normal), sandbox_id, fn ->
      case Req.request(
             [
               method: method,
               url: client.base_url <> proxy_path,
               headers: request_headers(client, method, proxy_path, encoded_body, sandbox_id),
               body: encoded_body,
               retry: false
             ] ++ client.req_options ++ Keyword.get(opts, :req_options, [])
           ) do
        {:ok, %Req.Response{status: status}} = result when status in 200..299 ->
          {:settled, result}

        {:ok, %Req.Response{} = response} = result ->
          if Req.Response.get_header(response, "x-salix-container-response") == ["1"] or
               (response.status in 400..499 and response.status not in [408, 429]),
             do: {:settled, result},
             else: {:uncertain, result}

        {:error, _} = result ->
          {:uncertain, result}
      end
    end)
  end

  @spec archive_get(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def archive_get(%__MODULE__{} = client, sandbox_id) do
    case proxy(client, sandbox_id, "/archive", purpose: :archive) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        with {:ok, raw} <- archive_body(body) do
          {:ok,
           %{
             "type" => "connector_tar_gz",
             "encoding" => "base64",
             "byte_size" => byte_size(raw),
             "data" => Base.encode64(raw)
           }}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, error_reason(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Begin a quiesced Connector export, or read its durable spool status."
  def archive_export(
        %__MODULE__{} = client,
        sandbox_id,
        operation,
        method \\ :get,
        format \\ nil,
        transfers \\ nil
      )
      when method in [:get, :post, :delete] do
    query =
      if method == :post and is_binary(format),
        do: %{"operation" => operation, "format" => format},
        else: %{"operation" => operation}

    path = "/archive/export?" <> URI.encode_query(query)
    archive_export_request(client, sandbox_id, path, method, transfers)
  end

  @doc "Read one fixed-size chunk of a completed Connector export."
  def archive_export_part(%__MODULE__{} = client, sandbox_id, operation, offset)
      when is_integer(offset) and offset >= 0 do
    path =
      "/archive/export?" <>
        URI.encode_query(%{"operation" => operation, "offset" => offset})

    archive_export_request(client, sandbox_id, path, :get, nil)
  end

  @doc "Have Connector upload one local archive part directly to signed object URLs."
  def archive_export_signed_part(%__MODULE__{} = client, sandbox_id, operation, offset, urls)
      when is_integer(offset) and offset >= 0 and is_map(urls) do
    path =
      "/archive/export?" <>
        URI.encode_query(%{"operation" => operation, "offset" => offset})

    case proxy(client, sandbox_id, path,
           method: :put,
           body: urls,
           purpose: :archive,
           req_options: [receive_timeout: 75_000]
         ) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, error_reason(status, body)}

      {:error, _} = error ->
        error
    end
  end

  defp archive_export_request(client, sandbox_id, path, method, transfers) do
    case proxy(client, sandbox_id, path,
           method: method,
           body: if(method == :post and is_list(transfers), do: %{"transfers" => transfers}),
           purpose: :archive,
           req_options: [receive_timeout: 20_000]
         ) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, error_reason(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Write or complete a replayable chunked Connector import on a fresh Sandbox."
  def archive_import(%__MODULE__{} = client, sandbox_id, body) when is_map(body) do
    options = if body["action"] == "stream", do: [receive_timeout: 900_000], else: []

    case proxy(client, sandbox_id, "/archive", method: :post, body: body, req_options: options) do
      {:ok, %Req.Response{status: status, body: result}}
      when status in 200..299 and is_map(result) ->
        {:ok, result}

      {:ok, %Req.Response{status: status, body: result}} ->
        {:error, error_reason(status, result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec archive_put(t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def archive_put(
        %__MODULE__{} = client,
        sandbox_id,
        %{"encoding" => "base64", "data" => data} = archive
      )
      when is_binary(data) do
    path =
      case archive["restore_operation"] do
        operation when is_binary(operation) ->
          "/archive?" <> URI.encode_query(%{"operation" => operation})

        _ ->
          "/archive"
      end

    with {:ok, raw} <- Base.decode64(data),
         {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           proxy(client, sandbox_id, path, method: :put, body: raw) do
      {:ok,
       %{
         "archive" => %{"type" => "connector_tar_gz"},
         "restore" => normalize_archive_response(body)
       }}
    else
      {:ok, %Req.Response{status: status, body: body}} -> {:error, error_reason(status, body)}
      :error -> {:error, :invalid_archive_encoding}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec connect_request(t(), String.t()) :: signed_request()
  def connect_request(%__MODULE__{} = client, sandbox_id) do
    path = sandbox_path(client, sandbox_id, "connect")

    %{
      url: ws_url(client.base_url <> path),
      headers: request_headers(client, :get, path, "", sandbox_id)
    }
  end

  defp request_json(client, method, path, body, sandbox_id, purpose \\ :normal) do
    encoded_body = encode_body(body)

    with_gateway_attempt(client, purpose, sandbox_id || sandbox_id_from_path(path), fn ->
      attempt(
        client,
        method,
        path,
        encoded_body,
        sandbox_id || sandbox_id_from_path(path),
        0,
        client.backoff_ms
      )
    end)
  end

  @doc "Claim a managed Gateway network attempt until its response settles."
  def begin_gateway_attempt(client, purpose \\ :normal, target_resource \\ nil)

  def begin_gateway_attempt(%__MODULE__{group_id: group_id} = client, purpose, target_resource)
      when is_binary(group_id) do
    operation_id = "gateway-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    SalixStore.Compute.begin_cloudflare_gateway_attempt(
      group_id,
      operation_id,
      purpose,
      location_key(client, target_resource)
    )
  end

  def begin_gateway_attempt(%__MODULE__{group_id: nil}, _purpose, _target_resource),
    do: {:ok, nil}

  def finish_gateway_attempt(%__MODULE__{group_id: group_id}, operation_id)
      when is_binary(group_id) and is_binary(operation_id) do
    SalixStore.Compute.finish_cloudflare_gateway_attempt(group_id, operation_id)
  end

  def finish_gateway_attempt(%__MODULE__{}, nil), do: :ok

  defp with_gateway_attempt(client, purpose, target_resource, fun) do
    case begin_gateway_attempt(client, purpose, target_resource) do
      {:ok, operation_id} ->
        case fun.() do
          {:settled, result} ->
            case finish_gateway_attempt(client, operation_id) do
              :ok ->
                :ok

              {:error, reason} ->
                require Logger

                Logger.error(
                  "Cloudflare Gateway attempt claim did not settle: #{inspect(reason)}"
                )
            end

            if match?({:ok, %{"status" => "ready"}}, result) and
                 is_binary(client.group_id) and is_binary(target_resource) do
              case SalixStore.Compute.finish_cloudflare_gateway_starting(
                     client.group_id,
                     location_key(client, target_resource)
                   ) do
                :ok ->
                  :ok

                {:error, reason} ->
                  require Logger

                  Logger.error(
                    "Cloudflare Gateway pending start did not settle: #{inspect(reason)}"
                  )
              end
            end

            result

          {:uncertain, {:ok, %{"status" => "starting"}} = result} ->
            if is_binary(client.group_id) and is_binary(target_resource) do
              case SalixStore.Compute.mark_cloudflare_gateway_starting(
                     client.group_id,
                     operation_id,
                     location_key(client, target_resource)
                   ) do
                :ok ->
                  :ok

                {:error, reason} ->
                  require Logger

                  Logger.error(
                    "Cloudflare Gateway starting claim did not persist: #{inspect(reason)}"
                  )
              end
            end

            result

          {:uncertain, result} ->
            result
        end

      {:error, _} = error ->
        error
    end
  end

  defp attempt(client, method, path, encoded_body, sandbox_id, n, backoff) do
    req_opts =
      [
        method: method,
        url: client.base_url <> path,
        headers: request_headers(client, method, path, encoded_body, sandbox_id),
        body: encoded_body,
        retry: false
      ] ++ client.req_options

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        normalized = normalize_body(body)

        if normalized["status"] == "starting" do
          {:uncertain, {:ok, normalized}}
        else
          {:settled, {:ok, normalized}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        if retryable?(status) and n < client.max_retries do
          Process.sleep(backoff)
          attempt(client, method, path, encoded_body, sandbox_id, n + 1, backoff * 2)
        else
          result = {:error, error_reason(status, body)}

          if status in 400..499 and status not in [408, 429],
            do: {:settled, result},
            else: {:uncertain, result}
        end

      {:error, reason} ->
        {:uncertain, {:error, reason}}
    end
  end

  defp sign_headers(client, method, path, encoded_body) do
    timestamp = System.system_time(:second) |> Integer.to_string()
    nonce = random_hex(16)
    request_id = random_hex(16)
    signature = signature(client.secret, method, path, timestamp, nonce, encoded_body)

    [
      {"content-type", "application/json"},
      {"x-salix-request-id", request_id},
      {"x-salix-timestamp", timestamp},
      {"x-salix-nonce", nonce},
      {"x-salix-signature", signature}
    ]
  end

  defp request_headers(client, method, path, encoded_body, sandbox_id) do
    client
    |> sign_headers(method, path, encoded_body)
    |> put_worker_version_key(sandbox_id)
    |> put_worker_version_override(client)
  end

  defp put_worker_version_key(headers, sandbox_id)
       when is_binary(sandbox_id) and sandbox_id != "",
       do: [{"Cloudflare-Workers-Version-Key", sandbox_id} | headers]

  defp put_worker_version_key(headers, _sandbox_id), do: headers

  defp put_worker_version_override(headers, %{
         worker_name: worker_name,
         worker_version_id: worker_version_id
       })
       when is_binary(worker_name) and worker_name != "" and is_binary(worker_version_id) and
              worker_version_id != "" do
    [
      {"Cloudflare-Workers-Version-Overrides", "#{worker_name}=\"#{worker_version_id}\""}
      | headers
    ]
  end

  defp put_worker_version_override(headers, _client), do: headers

  @doc false
  def signature(secret, method, path, timestamp, nonce, encoded_body) do
    body_hash = :crypto.hash(:sha256, encoded_body || "") |> Base.encode16(case: :lower)

    canonical =
      [method |> to_string() |> String.upcase(), path, timestamp, nonce, body_hash]
      |> Enum.join("\n")

    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, canonical) |> Base.encode16(case: :lower))
  end

  defp sandbox_collection_path(%{profile_key: "cf-standard-2"}),
    do: "/internal/v1/sandboxes"

  defp sandbox_collection_path(%{profile_key: "cf-standard-1"}),
    do: "/internal/v1/profiles/cf-standard-1/sandboxes"

  defp sandbox_collection_path(_client),
    do: "/internal/v1/profiles/unknown/sandboxes"

  defp location_key(%{profile_key: profile_key}, sandbox_id)
       when is_binary(profile_key) and is_binary(sandbox_id),
       do: profile_key <> ":" <> sandbox_id

  defp location_key(_client, _sandbox_id), do: nil

  defp sandbox_path(client, sandbox_id, suffix),
    do:
      sandbox_collection_path(client) <>
        "/" <>
        URI.encode(sandbox_id, &URI.char_unreserved?/1) <> "/" <> suffix

  defp sandbox_id_from_path("/internal/v1/profiles/cf-standard-1/sandboxes/" <> rest) do
    rest
    |> String.split("/", parts: 2)
    |> List.first()
    |> URI.decode()
  end

  defp sandbox_id_from_path("/internal/v1/sandboxes/" <> rest) do
    rest
    |> String.split("/", parts: 2)
    |> List.first()
    |> URI.decode()
  end

  defp sandbox_id_from_path(_path), do: nil

  defp encode_body(nil), do: ""
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: Jason.encode!(body)

  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(body) when is_binary(body), do: Jason.decode!(body)
  defp normalize_body(body), do: body

  defp normalize_archive_response(body) when is_map(body), do: body

  defp normalize_archive_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"body" => body}
    end
  end

  defp normalize_archive_response(body), do: body

  defp archive_body(body) when is_binary(body), do: {:ok, body}
  defp archive_body(_body), do: {:error, :not_binary_archive}

  defp error_reason(status, %{"error" => %{"code" => code, "message" => message}}),
    do: {:api_error, status, code, message}

  defp error_reason(status, body), do: {:api_error, status, body}

  defp retryable?(status), do: status == 429 or status >= 500

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)

  defp ws_url("https://" <> rest), do: "wss://" <> rest
  defp ws_url("http://" <> rest), do: "ws://" <> rest
end
