defmodule SalixSignal.Groups do
  @moduledoc """
  Groups v2 client for the Signal storage service (CRS-09b).

  The cryptography and wire formats are in `SalixSignalProto.Group`. This
  module does the network part:

    * `fetch_credentials/4` gets the group auth credentials for today to
      today plus 7 days over the authenticated chat socket (section 2).
    * `get_group/3`, `get_join_info/4`, `patch_group/4`, `get_logs/4` and
      `joined_at_revision/3` call the storage-service endpoints (section 5).
      Every request carries a fresh auth presentation (section 3).
    * `join_by_link/4` runs the join flow of section 7, and `change/4`
      retries a change after a revision conflict (section 5.2).

  A client is a map made by `client/3`: the server public params, the
  received auth credentials (a map from day to credential) and the storage
  base URL. The storage service answers with `X-Signal-Timestamp`; a response
  without it is treated as a server error (section 5).

  Options: `:environment` (`:production` or `:staging`), `:storage_url` (for
  tests), `:http` (options for `SalixSignal.Service.Http.request/3`) and
  `:now` (a zero-arity function returning Unix seconds, for tests).
  """

  alias SalixSignal.Service.{Chat, Endpoints, Http, Response}
  alias SalixSignalProto.Group.{Change, InviteLink, Params, ServerParams, State, Storage}

  @content_type "application/x-protobuf"
  @max_attempts 5
  # A group state or change log page; the storage service bounds group size.
  @max_body_bytes 4 * 1_048_576
  @join_direct 1
  @join_approval 3

  @type client :: %{
          server: ServerParams.Public.t(),
          credentials: %{integer() => binary()},
          base_url: String.t(),
          http: keyword(),
          now: (-> integer())
        }

  @doc """
  Requests group auth credentials over the chat socket and receives them for
  the account's raw 16-byte ACI (CRS-09b section 2). `salt` is the account's
  PNI credential salt, used only when the response has no PNI.
  """
  @spec fetch_credentials(GenServer.server(), ServerParams.Public.t(), <<_::128>>, keyword()) ::
          {:ok, %{integer() => binary()}} | {:error, term()}
  def fetch_credentials(
        chat,
        %ServerParams.Public{} = server,
        <<_::binary-size(16)>> = aci,
        opts \\ []
      ) do
    {first, last} = Storage.credential_range(now(opts).())

    path =
      "/v1/certificate/auth/group?redemptionStartSeconds=#{first}&redemptionEndSeconds=#{last}&v101=true"

    with {:ok, %Response{status: 200} = response} <- Chat.request(chat, "GET", path),
         {:ok, body} <- Response.json(response) do
      Storage.receive_credentials(server, aci, body, opts[:salt])
    else
      {:ok, %Response{} = response} -> {:error, Response.outcome(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Makes a storage client from the server public params and received credentials."
  @spec client(ServerParams.Public.t(), %{integer() => binary()}, keyword()) :: client()
  def client(%ServerParams.Public{} = server, credentials, opts \\ []) when is_map(credentials) do
    %{
      server: server,
      credentials: credentials,
      base_url:
        Keyword.get_lazy(opts, :storage_url, fn ->
          "https://" <> Endpoints.host(Keyword.get(opts, :environment, :production), :storage)
        end),
      http: Keyword.get(opts, :http, []),
      now: now(opts)
    }
  end

  @doc """
  Fetches and decrypts the current group state (`GET /v2/groups/`). Returns
  the state and the endorsement response bytes (empty when none).
  """
  @spec get_group(client(), Params.t()) ::
          {:ok, %{state: State.t(), endorsements: binary()}} | {:error, term()}
  def get_group(client, %Params{} = params) do
    with {:ok, body} <- storage(client, params, :get, "/v2/groups/"),
         {:ok, %{group: group, endorsements: endorsements}} <- Storage.decode_group_response(body),
         {:ok, state} <- State.decrypt(params, group) do
      {:ok, %{state: state, endorsements: endorsements}}
    end
  end

  @doc """
  Reads the join information behind an invite link password
  (`GET /v2/groups/join/<pw>`), with the title and description decrypted.
  A 403 means the link is disabled or the caller is banned.
  """
  @spec get_join_info(client(), Params.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_join_info(client, %Params{} = params, password, _opts \\ []) do
    with {:ok, body} <-
           storage(
             client,
             params,
             :get,
             "/v2/groups/join/" <> InviteLink.encode_password(password)
           ) do
      Storage.decode_join_info(params, body)
    end
  end

  @doc """
  Sends change actions (`PATCH /v2/groups/`, with `?inviteLinkPassword=`
  when `:link_password` is given). Returns the signed change as the server
  filled and signed it, and the endorsement response bytes. A revision
  conflict is `{:error, :conflict}`.
  """
  @spec patch_group(client(), Params.t(), binary(), keyword()) ::
          {:ok, %{change: binary(), endorsements: binary()}} | {:error, term()}
  def patch_group(client, %Params{} = params, actions, opts \\ []) when is_binary(actions) do
    path =
      case opts[:link_password] do
        nil -> "/v2/groups/"
        password -> "/v2/groups/?inviteLinkPassword=" <> InviteLink.encode_password(password)
      end

    with {:ok, body} <- storage(client, params, :patch, path, actions) do
      Storage.decode_change_response(body)
    end
  end

  @doc """
  Fetches one page of the change log from revision `from` (section 5.4).
  Returns the decoded log and, for a partial page, the `Content-Range`
  numbers `{first, last, current}`.
  """
  @spec get_logs(client(), Params.t(), non_neg_integer(), keyword()) ::
          {:ok, %{log: struct(), range: {integer(), integer(), integer()} | nil}}
          | {:error, term()}
  def get_logs(client, %Params{} = params, from, opts \\ [])
      when is_integer(from) and from >= 0 do
    path =
      "/v2/groups/logs/#{from}?maxSupportedChangeEpoch=#{Change.max_epoch()}" <>
        "&includeFirstState=#{Keyword.get(opts, :include_first_state, false)}&includeLastState=false"

    headers = [
      {"cached-send-endorsements", Integer.to_string(Keyword.get(opts, :cached_endorsements, 0))}
    ]

    with {:ok, body, response} <- storage_response(client, params, :get, path, nil, headers),
         {:ok, log} <- State.decode(SalixSignalProto.Group.Wire.ChangeLog, body) do
      range =
        case Storage.content_range(Response.header(response, "content-range")) do
          {:ok, range} -> range
          :error -> nil
        end

      {:ok, %{log: log, range: range}}
    end
  end

  @doc "The caller's joined-at revision (`GET /v2/groups/joined_at_version`)."
  @spec joined_at_revision(client(), Params.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def joined_at_revision(client, %Params{} = params) do
    with {:ok, body} <- storage(client, params, :get, "/v2/groups/joined_at_version"),
         {:ok, member} <- State.decode(SalixSignalProto.Group.Wire.Member, body) do
      {:ok, member.joined_at_revision}
    end
  end

  @doc """
  Applies a change with conflict retry (CRS-09b section 5.2). `build` gets
  the current decrypted state and returns a list of
  `SalixSignalProto.Group.Change` operations, or `[]` when nothing is left
  to do. After a 409 the state is fetched again and the change rebuilt, up
  to 5 attempts. Returns the signed change and the resulting state.
  """
  @spec change(client(), Params.t(), State.t(), (State.t() -> [Change.operation()])) ::
          {:ok, %{change: binary() | nil, state: State.t(), endorsements: binary()}}
          | {:error, term()}
  def change(client, %Params{} = params, %State{} = state, build) when is_function(build, 1) do
    attempt_change(client, params, state, build, 1)
  end

  defp attempt_change(client, params, state, build, attempt) do
    case build.(state) do
      [] ->
        {:ok, %{change: nil, state: state, endorsements: ""}}

      operations ->
        actions = Change.build(state.revision + 1, operations)

        case patch_group(client, params, actions) do
          {:ok, %{change: signed, endorsements: endorsements}} ->
            with {:ok, applied} <- apply_own_change(client, params, state, signed) do
              {:ok, %{change: signed, state: applied, endorsements: endorsements}}
            end

          {:error, :conflict} when attempt < @max_attempts ->
            with {:ok, %{state: fresh}} <- get_group(client, params) do
              attempt_change(client, params, fresh, build, attempt + 1)
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # The server's response is trusted over TLS (section 5.4); applying it
  # locally saves a fetch. An inconsistency falls back to the full state.
  defp apply_own_change(client, params, state, signed) do
    with {:ok, %{actions: actions, epoch: epoch}} <- Change.decode_signed(signed),
         {:ok, applied} <- Change.apply_actions(state, params, actions, epoch) do
      {:ok, applied}
    else
      _ ->
        with {:ok, %{state: fresh}} <- get_group(client, params), do: {:ok, fresh}
    end
  end

  @doc """
  Joins a group from an invite link (CRS-09b section 7). `presentation` is
  a function that returns a fresh expiring profile key credential
  presentation of the caller for the given group params. Joins directly
  when the link allows it and requests admin approval otherwise.

  Returns `{:joined, params, state, signed_change}` or
  `{:requested, params, signed_change}`.
  """
  @spec join_by_link(client(), String.t(), (Params.t() -> binary()), keyword()) ::
          {:ok, {:joined, Params.t(), State.t(), binary()} | {:requested, Params.t(), binary()}}
          | {:error, term()}
  def join_by_link(client, url, presentation, opts \\ []) when is_function(presentation, 1) do
    with {:ok, {master_key, password}} <- InviteLink.parse(url) do
      params = Params.from_master_key(master_key)
      join_attempt(client, params, password, presentation, opts, 1)
    end
  end

  defp join_attempt(client, params, password, presentation, opts, attempt) do
    with {:ok, info} <- get_join_info(client, params, password, opts),
         {:ok, operation, kind} <- join_operation(info, presentation.(params)) do
      actions = Change.build(info.revision + 1, [operation])

      case patch_group(client, params, actions, link_password: password) do
        {:ok, %{change: signed}} when kind == :joined ->
          with {:ok, %{state: state}} <- get_group(client, params) do
            {:ok, {:joined, params, state, signed}}
          end

        {:ok, %{change: signed}} ->
          {:ok, {:requested, params, signed}}

        {:error, :conflict} when attempt < @max_attempts ->
          join_attempt(client, params, password, presentation, opts, attempt + 1)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp join_operation(%{join_by_link: @join_direct}, presentation),
    do: {:ok, {:add_member, presentation, State.role_member()}, :joined}

  defp join_operation(%{join_by_link: @join_approval}, presentation),
    do: {:ok, {:add_requesting_member, presentation}, :requested}

  defp join_operation(_info, _presentation), do: {:error, :link_disabled}

  # --- storage requests ---

  defp storage(client, params, method, path, body \\ nil) do
    with {:ok, body, _response} <- storage_response(client, params, method, path, body, []),
         do: {:ok, body}
  end

  defp storage_response(client, params, method, path, body, extra_headers) do
    with {:ok, authorization} <-
           Storage.authorize(client.server, params, client.credentials, client.now.()) do
      headers =
        [{"authorization", authorization}] ++
          if(body, do: [{"content-type", @content_type}], else: []) ++ extra_headers

      request_opts =
        [headers: headers, body: body, max_body_bytes: @max_body_bytes] ++ client.http

      case Http.request(method, client.base_url <> path, request_opts) do
        {:ok, %Response{} = response} -> classify(response)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp classify(%Response{} = response) do
    cond do
      Response.server_time_ms(response) == nil -> {:error, {:server_error, response.status}}
      response.status in [200, 206] -> {:ok, response.body, response}
      true -> {:error, status_error(response)}
    end
  end

  defp status_error(%Response{status: 400}), do: :rejected

  defp status_error(%Response{status: 403} = r),
    do: {:forbidden, Response.header(r, "x-signal-forbidden-reason")}

  defp status_error(%Response{status: 404}), do: :not_found
  defp status_error(%Response{status: 409}), do: :conflict
  defp status_error(%Response{status: 423}), do: :terminated
  defp status_error(%Response{} = response), do: Response.outcome(response)

  defp now(opts), do: Keyword.get(opts, :now, fn -> System.os_time(:second) end)
end
