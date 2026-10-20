defmodule SalixIM.Provider.Lark.API do
  @moduledoc """
  Narrow Req-based adapter for the Lark OpenAPI surface used by Salix IM.

  Lark is the open platform at `open.larksuite.com`. It publishes no Elixir
  server SDK, so the HTTP surface the bot needs is kept here. A Lark connect
  carries its own app credentials: the App ID and App Secret are fields of the
  connect, and every call is made as that app.
  """

  use SystemsRuntime.Server

  @read_retries 2
  @resource_receive_timeout_ms 120_000
  @token_cache_table :salix_im_lark_tenant_token_cache
  @default_token_ttl_seconds 3_600
  @token_expiry_skew_seconds 60
  @token_rejection_codes [99_991_661, 99_991_663, 99_991_665, 99_991_677]
  @default_api_base "https://open.larksuite.com/open-apis"
  @resource_ref_key_domain "salix-im/lark/resource-ref/v1/signing-key"

  @doc false
  def start_link(_opts), do: SystemsRuntime.Server.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    table =
      SystemsRuntime.ETS.new(@token_cache_table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{token_cache_table: table}}
  end

  @doc """
  The connect acting as one person who signed in to its app
  (`SalixIM.LarkUserAccounts`): every call made with it carries that
  person's user access token instead of the app's tenant access token, so
  Lark answers with what that person may see.
  """
  @spec as_user(map(), String.t()) :: map()
  def as_user(connect, user_access_token) when is_map(connect) and is_binary(user_access_token),
    do: Map.put(connect, "user_access_token", user_access_token)

  @spec tenant_access_token(map()) :: {:ok, String.t()} | {:error, String.t()}
  def tenant_access_token(%{"user_access_token" => token})
      when is_binary(token) and token != "",
      do: {:ok, token}

  def tenant_access_token(%{"tenant_access_token" => token})
      when is_binary(token) and token != "",
      do: {:ok, token}

  def tenant_access_token(connect) when is_map(connect) do
    with {:ok, app} <- tenant_app(connect),
         app_id <- app_id_for(connect, app),
         app_secret <- str(app["app_secret"]),
         :ok <- ensure_value(app_id, "Lark app id is not configured"),
         :ok <- ensure_value(app_secret, "Lark app secret is not configured") do
      cached_tenant_access_token(connect, app_id, app_secret)
    end
  end

  @doc """
  Derives the key that signs this connect's resource references
  (`SalixIM.Provider.Lark.ResourceRef`) from the connect's App Secret.
  """
  @spec resource_ref_signing_key(map()) :: {:ok, binary()} | {:error, String.t()}
  def resource_ref_signing_key(connect) when is_map(connect) do
    with {:ok, app} <- tenant_app(connect),
         app_id <- app_id_for(connect, app),
         app_secret <- str(app["app_secret"]),
         :ok <- ensure_value(app_id, "Lark app id is not configured"),
         :ok <- ensure_value(app_secret, "Lark app secret is not configured") do
      {:ok,
       :crypto.mac(
         :hmac,
         :sha256,
         app_secret,
         @resource_ref_key_domain <> <<0>> <> app_id
       )}
    end
  end

  @doc false
  def reset_token_cache do
    case SystemsRuntime.ETS.whereis(@token_cache_table) do
      :undefined -> :ok
      table -> SystemsRuntime.ETS.delete_all_objects(table)
    end

    :ok
  end

  @spec get(map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def get(connect, path, params \\ %{}),
    do: request(connect, :get, path, params: compact(params), read_retries: @read_retries)

  @spec post(map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def post(connect, path, body), do: request(connect, :post, path, json: body)

  @doc """
  A POST that only reads, such as a document fetch. It gets the bounded read
  retries of `get/3`, because a repeat cannot change what Lark holds.
  """
  @spec post_read(map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def post_read(connect, path, body),
    do: request(connect, :post, path, json: body, read_retries: @read_retries, safe_retry: true)

  @spec put(map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def put(connect, path, body), do: request(connect, :put, path, json: body)

  @spec patch(map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def patch(connect, path, body), do: request(connect, :patch, path, json: body)

  @spec delete(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def delete(connect, path), do: request(connect, :delete, path)

  @spec delete(map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def delete(connect, path, body), do: request(connect, :delete, path, json: body)

  @spec upload_image(map(), String.t(), Enumerable.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def upload_image(connect, filename, stream, size) do
    fields = %{
      image_type: "message",
      image: {stream, filename: Path.basename(filename), size: size}
    }

    request(connect, :post, "/im/v1/images", form_multipart: fields, plugins: [SalixIM.Multipart])
    |> extract_key("image_key", "Lark image upload response missing image_key")
  end

  @spec upload_file(map(), String.t(), Enumerable.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def upload_file(connect, filename, stream, size) do
    fields = %{
      file_type: file_type(filename),
      file_name: Path.basename(filename),
      file: {stream, filename: Path.basename(filename), size: size}
    }

    request(connect, :post, "/im/v1/files", form_multipart: fields, plugins: [SalixIM.Multipart])
    |> extract_key("file_key", "Lark upload response missing file_key")
  end

  @doc """
  Uploads one image or file into a cloud document. `parent_node` is the empty
  document block that receives it, and the document id routes the upload.
  """
  @spec upload_doc_media(
          map(),
          String.t(),
          Enumerable.t(),
          non_neg_integer(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, String.t()}
  def upload_doc_media(connect, filename, stream, size, parent_type, parent_node, document_id)
      when parent_type in ["docx_image", "docx_file"] do
    fields = %{
      file_name: Path.basename(filename),
      parent_type: parent_type,
      parent_node: parent_node,
      size: Integer.to_string(size),
      extra: Jason.encode!(%{"drive_route_token" => document_id}),
      file: {stream, filename: Path.basename(filename), size: size}
    }

    request(connect, :post, "/drive/v1/medias/upload_all",
      form_multipart: fields,
      plugins: [SalixIM.Multipart]
    )
    |> extract_key("file_token", "Lark media upload response missing file_token")
  end

  @doc "Authenticated streaming download for a resource embedded in a Lark message."
  @spec stream_message_resource(
          map(),
          String.t(),
          String.t(),
          String.t(),
          function()
        ) :: {:ok, Req.Response.t()} | {:error, term()}
  def stream_message_resource(connect, message_id, file_key, resource_type, into)
      when resource_type in ["image", "file"] and is_function(into, 2) do
    stream_get(
      connect,
      "/im/v1/messages/#{segment(message_id)}/resources/#{segment(file_key)}",
      %{type: resource_type},
      into
    )
  end

  @doc "Authenticated streaming GET for a binary resource, such as cloud-document media."
  @spec stream_get(map(), String.t(), map(), function()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def stream_get(connect, path, params, into) when is_function(into, 2) do
    with {:ok, token} <- tenant_access_token(connect) do
      result = do_stream_get(connect, path, params, into, token)

      if stream_token_rejected?(result) and refreshable_token?(connect) do
        invalidate_cached_token(connect)

        with {:ok, refreshed_token} <- tenant_access_token(connect) do
          do_stream_get(connect, path, params, into, refreshed_token)
        end
      else
        result
      end
    end
  end

  @doc """
  Streaming GET of a pre-signed HTTPS URL that Lark returned, such as a
  Minutes media link. The URL carries its own authorization, so no app token
  is sent to it.
  """
  @spec stream_signed_url(String.t(), function()) :: {:ok, Req.Response.t()} | {:error, term()}
  def stream_signed_url("https://" <> _ = signed_url, into) when is_function(into, 2) do
    Req.get(signed_url,
      retry: false,
      redirect: false,
      receive_timeout: @resource_receive_timeout_ms,
      decode_body: false,
      into: into
    )
  end

  def stream_signed_url(_url, _into), do: {:error, "Lark download URL must use HTTPS"}

  defp do_stream_get(connect, path, params, into, token) do
    Req.get(
      url(connect, path),
      params: compact(params),
      headers: auth(token),
      retry: false,
      receive_timeout: @resource_receive_timeout_ms,
      decode_body: false,
      into: into
    )
  end

  defp request(connect, method, path, opts \\ []) do
    with {:ok, token} <- tenant_access_token(connect) do
      result = do_request(connect, method, path, Keyword.put(opts, :headers, auth(token)))

      if token_rejected?(result) and refreshable_token?(connect) do
        invalidate_cached_token(connect)

        with {:ok, refreshed_token} <- tenant_access_token(connect) do
          do_request(connect, method, path, Keyword.put(opts, :headers, auth(refreshed_token)))
        end
      else
        result
      end
    end
  end

  defp request_without_auth(connect, method, path, opts),
    do: do_request(connect, method, path, opts)

  defp do_request(connect, method, path, opts) do
    retries = Keyword.get(opts, :read_retries, 0)
    safe_retry? = Keyword.get(opts, :safe_retry, false)
    opts = Keyword.drop(opts, [:read_retries, :safe_retry])
    execute_request(connect, method, path, opts, retries, safe_retry?)
  end

  defp execute_request(connect, method, path, opts, retries_left, safe_retry?) do
    request_opts =
      opts
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, url(connect, path))
      |> Keyword.put(:retry, false)

    case Req.request(request_opts) do
      {:ok, %{status: status}}
      when (method == :get or safe_retry?) and retries_left > 0 and
             (status == 429 or status in 500..599) ->
        SystemsClock.sleep(25 * (@read_retries - retries_left + 1))
        execute_request(connect, method, path, opts, retries_left - 1, safe_retry?)

      {:error, _reason} when (method == :get or safe_retry?) and retries_left > 0 ->
        SystemsClock.sleep(25 * (@read_retries - retries_left + 1))
        execute_request(connect, method, path, opts, retries_left - 1, safe_retry?)

      response ->
        decode_response(response, if(safe_retry?, do: :get, else: method))
    end
  end

  defp cached_tenant_access_token(connect, app_id, app_secret) do
    key = token_cache_key(connect, app_id, app_secret)

    case read_cached_token(key) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        SystemsRuntime.Proc.global_trans(
          {{__MODULE__, :tenant_token, key}, SystemsRuntime.Proc.self()},
          fn ->
            case read_cached_token(key) do
              {:ok, token} -> {:ok, token}
              :miss -> mint_and_cache_tenant_access_token(connect, app_id, app_secret, key)
            end
          end
        )
    end
  end

  defp mint_and_cache_tenant_access_token(connect, app_id, app_secret, key) do
    request_without_auth(
      connect,
      :post,
      "/auth/v3/tenant_access_token/internal",
      json: %{"app_id" => app_id, "app_secret" => app_secret},
      read_retries: @read_retries,
      safe_retry: true
    )
    |> case do
      {:ok, body} when is_map(body) ->
        token = body["tenant_access_token"] || get_in(body, ["data", "tenant_access_token"])
        expires_in = body["expire"] || get_in(body, ["data", "expire"])

        if is_binary(token) and token != "" do
          cache_token(key, token, expires_in)
          {:ok, token}
        else
          {:error, "Lark tenant_access_token response missing token"}
        end

      other ->
        other
    end
  end

  defp read_cached_token(key) do
    table = token_cache_table()
    now_ms = SystemsClock.monotonic_time(:millisecond)

    case SystemsRuntime.ETS.lookup(table, key) do
      [{^key, token, expires_at_ms}] when expires_at_ms > now_ms -> {:ok, token}
      [_expired] -> SystemsRuntime.ETS.delete(table, key) && :miss
      [] -> :miss
    end
  end

  defp cache_token(key, token, expires_in) do
    ttl_seconds =
      expires_in
      |> int_or(@default_token_ttl_seconds)
      |> max(@token_expiry_skew_seconds + 1)
      |> Kernel.-(@token_expiry_skew_seconds)

    expires_at_ms = SystemsClock.monotonic_time(:millisecond) + ttl_seconds * 1_000
    true = SystemsRuntime.ETS.insert(token_cache_table(), {key, token, expires_at_ms})
    :ok
  end

  defp token_cache_key(connect, app_id, app_secret) do
    secret_fingerprint = :crypto.hash(:sha256, app_secret)
    {base_url(connect), app_id, secret_fingerprint}
  end

  defp invalidate_cached_token(connect) do
    with {:ok, app} <- tenant_app(connect) do
      app_id = app_id_for(connect, app)
      app_secret = str(app["app_secret"])
      SystemsRuntime.ETS.delete(token_cache_table(), token_cache_key(connect, app_id, app_secret))
    end

    :ok
  end

  defp token_cache_table do
    case SystemsRuntime.ETS.whereis(@token_cache_table) do
      :undefined ->
        raise "Lark tenant token cache is not started"

      table ->
        table
    end
  end

  defp refreshable_token?(connect),
    do:
      not Enum.any?(
        [connect["user_access_token"], connect["tenant_access_token"]],
        &(is_binary(&1) and &1 != "")
      )

  defp token_rejected?({:error, message}) when is_binary(message),
    do: Enum.any?(@token_rejection_codes, &String.contains?(message, "error #{&1} "))

  defp token_rejected?(_result), do: false

  defp stream_token_rejected?({:ok, response}) do
    body = response.private[:lark_error_body] || response.body

    case body do
      body when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"code" => code}} -> code in @token_rejection_codes
          _ -> false
        end

      %{"code" => code} ->
        code in @token_rejection_codes

      _ ->
        false
    end
  end

  defp stream_token_rejected?(_result), do: false

  defp decode_response({:ok, %{status: status, body: %{"code" => 0, "data" => data}}}, _method)
       when status in 200..299,
       do: {:ok, data}

  defp decode_response({:ok, %{status: status, body: %{"code" => 0} = body}}, _method)
       when status in 200..299,
       do: {:ok, body}

  defp decode_response({:ok, %{status: status}}, method)
       when method in [:post, :put, :patch, :delete] and status in 500..599,
       do:
         {:error,
          "Lark write outcome unknown after HTTP #{status}; do not blindly retry without a read-after-write check"}

  defp decode_response(
         {:ok, %{status: status, body: %{"code" => code, "msg" => msg}}},
         _method
       ),
       do: {:error, provider_error(code, msg, status)}

  defp decode_response({:ok, %{status: status}}, _method),
    do: {:error, "Lark HTTP #{status}"}

  defp decode_response({:error, reason}, method) when method in [:post, :put, :patch, :delete],
    do:
      {:error,
       "Lark write outcome unknown; do not blindly retry without a read-after-write check: #{inspect(reason)}"}

  defp decode_response({:error, reason}, _method),
    do: {:error, "Lark request failed: #{inspect(reason)}"}

  @doc "Maps a Lark response code to a safe, actionable operator error."
  @spec provider_error(term(), term(), integer()) :: String.t()
  def provider_error(code, msg, status) do
    action =
      case code do
        code when code in [99_991_672, 99_991_679, 230_027] ->
          " Missing Lark permission or an unpublished app version; import the required scope JSON, publish, and reinstall the app."

        code when code in [230_002, 234_004] ->
          " Add this bot to the target chat before retrying."

        code when code in [40_004, 40_014] ->
          " The app's Contacts & organization data scope does not include this department or user; expand the administrator-granted data range, publish, and reinstall the app."

        234_003 ->
          " The file_key does not belong to this message_id; use the pair returned by the same history item."

        230_006 ->
          " Enable the Bot capability in Lark Developer Console and publish the app."

        230_013 ->
          " Add the user to the app availability range and publish the app version."

        230_046 ->
          " This chat only allows owners or administrators to Pin messages."

        234_009 ->
          " This resource is unavailable in the current external chat."

        234_037 ->
          " Lark message resources larger than 100 MB cannot be downloaded."

        234_038 ->
          " This chat or message is in restricted/confidential mode and blocks resource download."

        code when code in [230_050, 234_040] ->
          " The bot cannot see this message; check whether new members may view chat history."

        # 2889902, 2889906 and 2889914 are the codes Lark documents for reading
        # a document's content (`GET /docs/v1/content`).
        code when code in [2_889_902, 1_770_032, 131_006] ->
          " This app cannot open the document. Share the document with a chat that includes the bot, or add the app to the document (... > More > Add document app). Do not retry unchanged."

        code when code in [2_889_906, 2_889_914, 1_770_002, 131_005] ->
          " The document does not exist, was deleted, or the token is wrong. Check the link."

        99_991_400 ->
          " Lark rate limit reached; wait before retrying."

        _ ->
          ""
      end

    "Lark API error #{code} (HTTP #{status}): #{msg}.#{action}"
  end

  defp extract_key({:ok, body}, key, message) when is_map(body) do
    value = Map.get(body, key) || get_in(body, ["data", key])

    if is_binary(value) and value != "",
      do: {:ok, value},
      else: {:error, message}
  end

  defp extract_key(other, _key, _message), do: other

  # The connect is the app: it holds the App ID and the App Secret.
  defp tenant_app(connect) do
    if str(connect["app_secret"]) == "",
      do: {:error, "Lark app secret is not configured"},
      else: {:ok, connect}
  end

  defp app_id_for(connect, _app), do: str(connect["app_id"])

  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  defp url(connect, path),
    do: String.trim_trailing(base_url(connect), "/") <> "/" <> String.trim_leading(path, "/")

  defp base_url(_connect),
    do: SystemsRuntime.get_env(:salix_im, :lark_api_base_url, @default_api_base)

  defp compact(params),
    do:
      params
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

  defp segment(value), do: value |> str() |> URI.encode_www_form()

  defp ensure_value("", message), do: {:error, message}
  defp ensure_value(_value, _message), do: :ok

  defp file_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".mp4" -> "mp4"
      ".mp3" -> "mp3"
      ".wav" -> "wav"
      ".pdf" -> "pdf"
      ".doc" -> "doc"
      ".docx" -> "docx"
      ".xls" -> "xls"
      ".xlsx" -> "xlsx"
      ".ppt" -> "ppt"
      ".pptx" -> "pptx"
      _ -> "stream"
    end
  end

  defp str(nil), do: ""
  defp str(value) when is_binary(value), do: String.trim(value)
  defp str(value), do: value |> to_string() |> String.trim()

  defp int_or(value, _default) when is_integer(value), do: value

  defp int_or(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp int_or(_value, default), do: default
end
