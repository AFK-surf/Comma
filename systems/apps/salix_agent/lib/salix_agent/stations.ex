defmodule SalixAgent.Stations do
  @moduledoc """
  Port to still.fail stations enrolled in the agent's workspace.

  A station is a user machine that runs still.fail's station service and is
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
      `:requester_required`, `:station_not_found`, `:forbidden`, ...).
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
  @optional_callbacks offered?: 1
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

  def describe_error(:requester_required),
    do: "station tools need a workspace member who asked for this turn"

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
