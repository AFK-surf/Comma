defmodule SalixAgent.Stations do
  @moduledoc """
  Port to Comma stations enrolled in the agent's workspace.

  A station is a user machine that runs the Comma station service and is
  enrolled in a Comma workspace (the Station concept in
  `docs/architecture/DOMAIN_CONCEPTS.md`). Salix reaches its device tools
  through the Comma station gateway (`systems/gateway/comma-station-gateway`),
  which speaks the `comma/tools/1` iroh protocol. Agent tools address a station as a device
  target with `device_id` `"station:<station id>"`; see
  `SalixAgent.Stations.Env` and `SalixAgent.Tools.Stations`.

  The implementation resolves, from the tool `ctx`, the workspace that owns
  the agent's group and the person who asked for the current turn, checks that
  the station belongs to that workspace, and forwards the op with the context
  fields `workspace`, `user_id`, `user_email`, `agent` and `conversation`.
  The station applies its own `tools.access` setting.

  Configure with `Application.put_env(:salix_agent, :stations, Module)`.
  The default `SalixAgent.Stations.None` reports `:not_configured`.

  Results:

    * `{:ok, result}` — the station ran the op; `result` is its `result` map.
    * `{:error, {:tool, %{"code" => _, "message" => _}}}` — the station
      refused or failed the op.
    * `{:error, {:gateway, code, message}}` — the station did not answer.
      `station_unreachable`, `overloaded` and `gateway_unreachable` mean
      nothing was sent; after `timeout`, `station_disconnected`,
      `bad_station_response` or `gateway_disconnected` the outcome is unknown.
    * `{:error, reason}` — the call was not made (`:not_configured`,
      `:requester_required`, `{:requester_refused, reason}`,
      `:station_not_found`, `:forbidden`, ...).
  """

  @type ctx :: map()
  @type station :: %{required(String.t()) => term()}
  @type error ::
          {:tool, map()}
          | {:gateway, String.t(), String.t()}
          | atom()
          | term()

  @callback configured?() :: boolean()
  @callback offered?(ctx()) :: boolean()
  @callback member(ctx()) :: {:ok, %{email: String.t(), role: String.t()}} | {:error, term()}
  @callback stillfail_stations(ctx()) :: {:ok, [map()]} | {:error, term()}
  @optional_callbacks offered?: 1, member: 1, stillfail_stations: 1
  @callback list(ctx()) :: {:ok, [station()]} | {:error, error()}
  @callback call(ctx(), station_id :: String.t(), op :: String.t(), args :: map()) ::
              {:ok, map()} | {:error, error()}

  @target_prefix "station:"
  # Gateway codes after which the op may have run (contract §9 changelog).
  @sent_unknown ~w(timeout station_disconnected bad_station_response)
  # Codes for requests that never left the gateway or Salix.
  @not_sent ~w(overloaded unauthorized invalid_request gateway_unreachable)

  @doc "Device id prefix that marks a station target."
  def target_prefix, do: @target_prefix

  @doc "The station id of a `station:<id>` device id, else `nil`."
  @spec station_id(term()) :: String.t() | nil
  def station_id(@target_prefix <> id) when id != "", do: id
  def station_id(%{device_id: device_id}), do: station_id(device_id)
  def station_id(%{"device_id" => device_id}), do: station_id(device_id)
  def station_id(_target), do: nil

  @spec configured?() :: boolean()
  def configured?, do: impl().configured?()

  @doc "The member who asked for this turn, by their email and role in the Group."
  @spec member(ctx()) :: {:ok, %{email: String.t(), role: String.t()}} | {:error, term()}
  def member(ctx) do
    impl = impl()
    SystemsRuntime.Proc.ensure_loaded?(impl)

    if function_exported?(impl, :member, 1),
      do: impl.member(ctx),
      else: {:error, :not_configured}
  end

  @doc """
  Whether the agent's workspace should see the `station.*` tools: the gateway
  is configured and the workspace has at least one enrolled station. An
  implementation without `offered?/1` falls back to `configured?/0`.
  """
  @spec offered?(ctx()) :: boolean()
  def offered?(ctx) do
    impl = impl()
    SystemsRuntime.Proc.ensure_loaded?(impl)

    if function_exported?(impl, :offered?, 1),
      do: impl.offered?(ctx),
      else: impl.configured?()
  end

  @spec list(ctx()) :: {:ok, [station()]} | {:error, error()}
  def list(ctx), do: impl().list(ctx)

  @spec call(ctx(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, error()}
  def call(ctx, station_id, op, args), do: impl().call(ctx, station_id, op, args)

  @doc """
  The still.fail stations connected to the agent's Group through Comma's
  still.fail plugin (Devices of `device_kind` `stillfail`, not Stations of the
  roster): `"id"`, `"name"` (what the station called itself, nil before it
  first connected), `"connected"` and `"connected_at"`. An implementation
  without `stillfail_stations/1` has none.
  """
  @spec stillfail_stations(ctx()) :: {:ok, [map()]} | {:error, term()}
  def stillfail_stations(ctx) do
    impl = impl()
    SystemsRuntime.Proc.ensure_loaded?(impl)

    if function_exported?(impl, :stillfail_stations, 1),
      do: impl.stillfail_stations(ctx),
      else: {:ok, []}
  end

  @doc """
  A tool-facing message for an error from `list/1` or `call/4`. It says
  whether the request reached the station: before sending, a retry is safe;
  after sending, the op may have run and its state must be checked first.
  """
  @spec describe_error(error()) :: String.t()
  def describe_error({:tool, %{} = error}),
    do: "station refused: #{error["code"] || "error"}: #{error["message"] || ""}"

  def describe_error({:gateway, code, _message}) when code in @sent_unknown,
    do:
      "the request reached the station but no valid answer came back (#{code}); the operation may have run. Check its state before retrying."

  def describe_error({:gateway, "station_unreachable", _message}),
    do: "station is offline or unreachable; the request was not sent, so retrying later is safe"

  def describe_error({:gateway, code, message}) when code in @not_sent,
    do: "station gateway refused the request before sending it (#{code}): #{message}"

  def describe_error({:gateway, code, message}),
    do: "station gateway error #{code}: #{message}; whether the operation ran is unknown"

  def describe_error(:not_configured), do: "stations are not available in this deployment"

  # No member asked for this turn, and nothing said in the chat changes that:
  # the model goes on without a machine instead of asking for authorization.
  def describe_error(:requester_required),
    do:
      "station tools are unavailable for this turn because no workspace member asked for it, and nobody can grant that from the chat. Do the work without a Station (your own API tools, files in your VFS, script.run, or a sandbox Task where your instructions offer one) and do not ask anyone to authorize it."

  # A chat app's user with no member's account, refused by the app's own
  # answer about them (`CommaWeb.Stations`).
  def describe_error({:requester_refused, :not_available}),
    do:
      "station tools are unavailable for this turn: the person who asked is outside the chat app's availability range. An administrator of the chat app can add them to it. Do not ask the person to authorize anything."

  def describe_error({:requester_refused, :no_email}),
    do:
      "station tools are unavailable for this turn: the person who asked has no organization email in the chat app's directory, so they cannot be matched to a person. Do not ask the person to authorize anything."

  def describe_error({:requester_refused, {:missing_scope, scope}}),
    do:
      "station tools for chat senders need the chat app permission #{scope}; an administrator adds it to the app and publishes a new app version."

  def describe_error({:requester_refused, :check_failed}),
    do:
      "the chat app's availability check for the person who asked failed; nothing was sent to a station. Retry later."

  def describe_error(:station_not_found),
    do: "station is not enrolled in this workspace; use station.list"

  def describe_error(:forbidden), do: "the requesting member may not use this station operation"
  def describe_error(reason), do: "station call failed: #{inspect(reason)}"

  defp impl, do: SystemsRuntime.get_env(:salix_agent, :stations, __MODULE__.None)

  defmodule None do
    @moduledoc "Default: no station gateway in this deployment."
    @behaviour SalixAgent.Stations

    @impl true
    def configured?, do: false
    @impl true
    def list(_ctx), do: {:error, :not_configured}
    @impl true
    def call(_ctx, _station_id, _op, _args), do: {:error, :not_configured}
  end
end
