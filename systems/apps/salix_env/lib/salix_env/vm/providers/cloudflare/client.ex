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
            control: nil,
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
      control: Keyword.get(merged, :control),
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

    with {:ok, observation} <- open_control(client, sandbox_id),
         {:ok, result} <- ensure_controlled(client, sandbox_id, body, observation) do
      {:ok, result}
    else
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
  def status(%__MODULE__{} = client, sandbox_id) do
    with {:ok, result} <-
           request_json(client, :get, sandbox_path(client, sandbox_id, "status"), nil, sandbox_id),
         :ok <- confirm_control_terminal(client, sandbox_id),
         do: {:ok, result}
  end

  defp confirm_control_terminal(%{group_id: nil}, _id), do: :ok

  defp confirm_control_terminal(client, id) do
    case owner_control(client) do
      nil ->
        :ok

      {:error, _} = error ->
        error

      _ ->
        with {:ok, observation} <- control_observation(client, id),
             do:
               SalixStore.Compute.settle_cloudflare_terminal(
                 client.group_id,
                 location_key(client, id),
                 observation
               )
    end
  end

  @doc "Observe DO storage without starting or connecting to its Container."
  def control_observation(client, sandbox_id) do
    path = sandbox_path(client, sandbox_id, "control")

    case Req.request(
           [
             method: :get,
             url: client.base_url <> path,
             headers: request_headers(client, :get, path, "", sandbox_id),
             retry: false
           ] ++ client.req_options
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %Req.Response{status: 404}} ->
        {:error, {:gateway_control_unsupported, client.profile_key}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, error_reason(status, body)}

      {:error, _} = error ->
        error
    end
  end

  defp open_control(%{group_id: nil, control: nil}, _id), do: {:ok, %{}}

  defp open_control(client, id) do
    with {:ok, observation} <- control_observation(client, id),
         :ok <- settle_terminal_observation(client, id, observation),
         {:ok, control} <- prepare_owner_control(client, id, :open),
         {:ok, result} <-
           request_json(
             client,
             :post,
             sandbox_path(client, id, "control"),
             %{"action" => "open", "control" => Map.put(control, "claim_id", "control-open")},
             id
           ) do
      {:ok, Map.merge(observation, result)}
    end
  end

  defp settle_terminal_observation(%{group_id: nil}, _id, _observation), do: :ok

  defp settle_terminal_observation(client, id, %{"control" => control} = observation)
       when is_map(control) do
    SalixStore.Compute.settle_cloudflare_terminal(
      client.group_id,
      location_key(client, id),
      observation
    )
  end

  defp settle_terminal_observation(_client, _id, _observation), do: :ok

  defp ensure_controlled(client, id, body, observation) do
    case get_in(observation, ["control", "pending", "action"]) do
      "ensure" ->
        case status(client, id) do
          {:ok, %{"status" => "ready"} = result} -> {:ok, result}
          _ -> {:error, :container_start_unsettled}
        end

      nil ->
        request_json(client, :post, sandbox_collection_path(client), body, id)

      _ ->
        {:error, :cloudflare_control_unsettled}
    end
  end

  def seal_control(client, id) do
    case owner_control(client) do
      {:error, _} = error ->
        error

      nil ->
        {:ok, %{"legacy" => true}}

      _ ->
        with {:ok, control} <- prepare_owner_control(client, id, :seal),
             {:ok, observation} <-
               request_json(
                 client,
                 :post,
                 sandbox_path(client, id, "control"),
                 %{"action" => "seal", "control" => Map.put(control, "claim_id", "control-seal")},
                 id,
                 :archive
               ),
             :ok <- settle_control(client, id, observation) do
          {:ok, observation}
        end
    end
  end

  def connector_control(client, id, action, scope \\ "full") when action in ["open", "seal"] do
    with control when is_map(control) <- owner_control(client),
         {:ok, %Req.Response{status: status, body: body}} <-
           proxy(client, id, "/control",
             method: :post,
             purpose: if(action == "seal", do: :archive, else: :normal),
             req_options: [receive_timeout: 100_000],
             body: %{"action" => action, "control" => control, "scope" => scope}
           ) do
      if status in 200..299,
        do: {:ok, normalize_body(body)},
        else: {:error, error_reason(status, body)}
    else
      nil -> {:error, :cloudflare_control_unbound}
      {:error, _} = error -> error
    end
  end

  def open_connector(%{group_id: nil, control: nil}, _id), do: :ok

  def open_connector(client, id) do
    case connector_control(client, id, "open") do
      {:ok, _} -> :ok
      {:error, {:api_error, 404, _}} -> :ok
      {:error, _} = error -> error
    end
  end

  def resume_control(client, id) do
    case owner_control(client) do
      {:error, _} = error ->
        error

      nil ->
        {:ok, :legacy}

      _ ->
        with {:ok, observation} <- control_observation(client, id),
             :ok <- settle_control(client, id, observation),
             {:ok, control} <- prepare_owner_control(client, id, :resume),
             {:ok, _} <-
               request_json(
                 client,
                 :post,
                 sandbox_path(client, id, "control"),
                 %{
                   "action" => "open",
                   "control" => Map.put(control, "claim_id", "control-resume")
                 },
                 id,
                 :archive
               ),
             {:ok, response} <-
               proxy(client, id, "/control",
                 method: :post,
                 purpose: :archive,
                 body: %{"action" => "open", "control" => control}
               ) do
          case response.status do
            status when status in 200..299 -> {:ok, :managed}
            404 -> {:ok, :legacy}
            status -> {:error, error_reason(status, response.body)}
          end
        end
    end
  end

  defp prepare_owner_control(%{group_id: nil, control: control}, _id, action)
       when is_map(control),
       do: {:ok, Map.put(control, "sealed", action == :seal)}

  defp prepare_owner_control(client, id, action),
    do:
      SalixStore.Compute.prepare_cloudflare_control(
        client.group_id,
        location_key(client, id),
        action
      )

  defp owner_control(%{group_id: nil, control: control}), do: control

  defp owner_control(client) do
    case SalixStore.Compute.cloudflare_control(client.group_id) do
      {:ok, control} -> control
      {:error, :cloudflare_control_unbound} -> nil
      {:error, _} = error -> error
    end
  end

  defp control_permit(client, claim) do
    control =
      if is_binary(client.group_id) and is_binary(claim) do
        with {:ok, record} <- SalixStore.Compute.group_workload(client.group_id),
             operation when is_map(operation) <- get_in(record, ["active_operations", claim]) do
          cond do
            is_integer(operation["control_revision"]) ->
              %{
                "owner_id" => record["workload_id"],
                "operation_id" => operation["owner_operation"],
                "generation" => operation["generation"],
                "revision" => operation["control_revision"]
              }

            is_nil(record["cloudflare_control"]) ->
              nil

            true ->
              {:error, :gateway_attempt_unqualified}
          end
        else
          {:error, _} = error -> error
          nil -> {:error, :gateway_attempt_unavailable}
          _ -> nil
        end
      else
        owner_control(client)
      end

    case control do
      {:error, _} = error ->
        error

      nil ->
        nil

      control ->
        control
        |> Map.take(~w(owner_id operation_id generation revision))
        |> Map.put("claim_id", claim || "direct-" <> random_hex(12))
    end
  end

  defp attempt_metadata(client, action) do
    case owner_control(client) do
      {:error, _} = error ->
        error

      nil ->
        %{}

      control ->
        %{
          "action" => action,
          "owner_operation" => control["operation_id"],
          "generation" => control["generation"],
          "control_revision" => control["revision"]
        }
    end
  end

  defp settle_control(%{group_id: nil}, _id, _observation), do: :ok

  defp settle_control(client, id, observation),
    do:
      SalixStore.Compute.settle_cloudflare_control(
        client.group_id,
        location_key(client, id),
        observation
      )

  defp controlled_path(path, nil), do: path

  defp controlled_path(path, permit),
    do:
      path <>
        if(String.contains?(path, "?"), do: "&", else: "?") <>
        URI.encode_query(%{"salix_control" => Jason.encode!(permit)})

  defp request_action(path) do
    cond do
      String.ends_with?(path, "/sandboxes") -> "ensure"
      String.ends_with?(path, "/control") -> "seal"
      String.ends_with?(path, "/status") or String.contains?(path, "/receipt?") -> "observe"
      true -> List.last(String.split(path, "/"))
    end
  end

  defp proxy_action("/control", :post, _), do: "connector_control"
  defp proxy_action("/archive", :post, %{"action" => "status"}), do: "observe"
  defp proxy_action("/archive", _, _), do: "import"

  defp proxy_action("/archive/export" <> _, method, _) when method in [:post, :put, :delete],
    do: "export"

  defp proxy_action(_, _, _), do: "observe"

  @spec destroy(t(), String.t()) :: :ok | {:error, term()}
  def destroy(%__MODULE__{} = client, sandbox_id, opts \\ []) do
    with {:ok, _} <- seal_control(client, sandbox_id) do
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

    with_gateway_attempt(
      client,
      Keyword.get(opts, :purpose, :normal),
      sandbox_id,
      proxy_action(path, method, body),
      fn permit ->
        proxy_path = controlled_path(proxy_path, permit)

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
      end
    )
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
        transfers \\ nil,
        scope \\ "full"
      )
      when method in [:get, :post, :delete] do
    query =
      if method == :post and is_binary(format),
        do: %{"operation" => operation, "format" => format, "scope" => scope},
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

    result =
      if body["action"] == "status" and is_map(owner_control(client)),
        do:
          request_json(
            client,
            :get,
            sandbox_path(client, sandbox_id, "receipt") <>
              "?" <> URI.encode_query(%{"operation" => body["operation"]}),
            nil,
            sandbox_id,
            :archive
          ),
        else:
          proxy(client, sandbox_id, "/archive", method: :post, body: body, req_options: options)

    case result do
      {:ok, result} when is_map(result) and not is_struct(result) ->
        with :ok <- confirm_control_terminal(client, sandbox_id), do: {:ok, result}

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
  def connect_request(%__MODULE__{} = client, sandbox_id, opts \\ []) do
    path = sandbox_path(client, sandbox_id, "connect")

    path =
      if Keyword.get(opts, :archive_repair, false), do: path <> "?archive_repair=true", else: path

    path = controlled_path(path, control_permit(client, Keyword.get(opts, :claim_id)))

    %{
      url: ws_url(client.base_url <> path),
      headers: request_headers(client, :get, path, "", sandbox_id)
    }
  end

  defp request_json(client, method, path, body, sandbox_id, purpose \\ :normal) do
    encoded_body = encode_body(body)

    with_gateway_attempt(
      client,
      purpose,
      sandbox_id || sandbox_id_from_path(path),
      request_action(path),
      fn permit ->
        path = controlled_path(path, permit)

        attempt(
          client,
          method,
          path,
          encoded_body,
          sandbox_id || sandbox_id_from_path(path),
          0,
          client.backoff_ms
        )
      end
    )
  end

  @doc "Claim a managed Gateway network attempt until its response settles."
  def begin_gateway_attempt(
        client,
        purpose \\ :normal,
        target_resource \\ nil,
        action \\ "connect"
      )

  def begin_gateway_attempt(
        %__MODULE__{group_id: group_id} = client,
        purpose,
        target_resource,
        action
      )
      when is_binary(group_id) do
    operation_id = "gateway-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    case attempt_metadata(client, action) do
      {:error, _} = error ->
        error

      metadata ->
        SalixStore.Compute.begin_cloudflare_gateway_attempt(
          group_id,
          operation_id,
          purpose,
          location_key(client, target_resource),
          metadata
        )
    end
  end

  def begin_gateway_attempt(%__MODULE__{group_id: nil}, _purpose, _target_resource, _action),
    do: {:ok, nil}

  def finish_gateway_attempt(%__MODULE__{group_id: group_id}, operation_id)
      when is_binary(group_id) and is_binary(operation_id) do
    SalixStore.Compute.finish_cloudflare_gateway_attempt(group_id, operation_id)
  end

  def finish_gateway_attempt(%__MODULE__{}, nil), do: :ok

  @doc "Retain one uncertain start for the exact Sandbox and Container profile."
  def mark_gateway_starting(%__MODULE__{group_id: nil}, _operation_id, _sandbox_id), do: :ok

  def mark_gateway_starting(%__MODULE__{group_id: group_id} = client, operation_id, sandbox_id) do
    case location_key(client, sandbox_id) do
      target when is_binary(target) ->
        SalixStore.Compute.mark_cloudflare_gateway_starting(group_id, operation_id, target)

      _ ->
        {:error, :gateway_target_unresolved}
    end
  end

  @doc "A ready response or connected WebSocket settles prior starts for this Sandbox."
  def finish_gateway_starting(%__MODULE__{group_id: nil}, _sandbox_id), do: :ok

  def finish_gateway_starting(%__MODULE__{group_id: group_id} = client, sandbox_id) do
    case location_key(client, sandbox_id) do
      target when is_binary(target) ->
        case owner_control(client) do
          {:error, _} = error ->
            error

          control ->
            SalixStore.Compute.finish_cloudflare_gateway_starting(
              group_id,
              target,
              if(is_map(control), do: control["revision"])
            )
        end

      _ ->
        {:error, :gateway_target_unresolved}
    end
  end

  defp with_gateway_attempt(client, purpose, target_resource, action, fun) do
    case begin_gateway_attempt(client, purpose, target_resource, action) do
      {:ok, operation_id} ->
        permit = control_permit(client, operation_id)

        if match?({:error, _}, permit) do
          permit
        else
          case fun.(permit) do
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
                case finish_gateway_starting(client, target_resource) do
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
                case mark_gateway_starting(client, operation_id, target_resource) do
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
        if retryable?(status) and n < client.max_retries and
             not String.contains?(path, "salix_control=") do
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
