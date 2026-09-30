defmodule SalixAgent.EnvDispatch do
  @moduledoc """
  Decoupling seam for connector-backed command environments.

  Caller agent_id is the authenticated runtime identity, never a model-authored
  tool argument. Device reads derive canonical tenant/group from that identity;
  runtime admission and role-specific authorization remain at their owners.


    * `list_devices/2` — discover one bounded page of devices.
    * `list_envs/1` — internal environment inventory for existing worker placement.
    * `get_device/2` — read one stable device exactly within that group.
    * `exec/4` — run a shell command on an explicit device/environment target.
    * `computer_use/3` — relay a `{environment, action, thinking?, args?}`
      payload to the connector's computer-use daemon.
    * `android/3` — relay one bounded Android lifecycle or UI action.
    * `process_list/2`, `process_write/5`, and `process_tail/4` — operate on
      long-lived connector processes started through an environment.
    * `read_stream/3` / `write_stream/4` — binary-safe file movement used by
      remote file tools.

  The active implementation is configured with

      Application.put_env(:salix_agent, :env_dispatch, MyDispatcher)

  and defaults to `SalixAgent.EnvDispatch.None`, which returns
  `{:error, :no_environment}` for every call. The tool layer maps that to the
  existing remote-connector unavailable result.
  """

  @typedoc "One environment entry, string-keyed (at minimum `\"alias\"`)."
  @type env_entry :: %{optional(String.t()) => term()}

  @typedoc "An explicit device-local command environment; never a connector run."
  @type target :: %{device_id: String.t(), environment_id: String.t()}

  @callback list_devices(String.t(), keyword()) ::
              {:ok, %{devices: [map()], next_cursor: String.t() | nil}} | {:error, term()}

  @callback create_device_install(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks create_device_install: 2

  @callback list_envs(agent_id :: String.t()) :: {:ok, [env_entry()]} | {:error, term()}
  @callback get_device(agent_id :: String.t(), device_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback exec(
              agent_id :: String.t(),
              target :: target(),
              cmd :: String.t(),
              opts :: %{optional(String.t()) => term()}
            ) :: {:ok, map()} | {:error, term()}

  @callback request(String.t(), target(), String.t(), map()) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks request: 4

  @callback computer_use(
              agent_id :: String.t(),
              target :: target(),
              action :: %{optional(String.t()) => term()}
            ) :: {:ok, map()} | {:error, term()}

  @callback android(
              agent_id :: String.t(),
              target :: target(),
              action :: %{optional(String.t()) => term()}
            ) :: {:ok, map()} | {:error, term()}

  @callback process_list(agent_id :: String.t(), target :: target()) ::
              {:ok, map()} | {:error, term()}

  @callback process_write(
              agent_id :: String.t(),
              target :: target(),
              process_name :: String.t(),
              data :: String.t(),
              opts :: %{optional(String.t()) => term()}
            ) :: {:ok, map()} | {:error, term()}

  @callback process_tail(
              agent_id :: String.t(),
              target :: target(),
              process_name :: String.t(),
              opts :: %{optional(String.t()) => term()}
            ) :: {:ok, map()} | {:error, term()}

  @callback read_stream(
              agent_id :: String.t(),
              target :: target(),
              path :: String.t()
            ) ::
              {:ok, Enumerable.t(), non_neg_integer() | nil} | {:error, term()}

  @callback write_stream(
              agent_id :: String.t(),
              target :: target(),
              path :: String.t(),
              stream :: Enumerable.t()
            ) :: {:ok, map()} | {:error, term()}

  @spec list_devices(String.t(), keyword()) ::
          {:ok, %{devices: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def list_devices(agent_id, opts), do: impl().list_devices(agent_id, opts)

  @spec list_envs(String.t()) :: {:ok, [env_entry()]} | {:error, term()}
  def list_envs(agent_id), do: impl().list_envs(agent_id)

  @spec get_device(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_device(agent_id, device_id), do: impl().get_device(agent_id, device_id)

  @spec exec(String.t(), target(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def exec(agent_id, target, cmd, opts \\ %{}),
    do: impl().exec(agent_id, target, cmd, opts)

  def request(agent_id, target, method, params),
    do: impl().request(agent_id, target, method, params)

  @spec computer_use(String.t(), target(), map()) :: {:ok, map()} | {:error, term()}
  def computer_use(agent_id, target, action),
    do: impl().computer_use(agent_id, target, action)

  @spec android(String.t(), target(), map()) :: {:ok, map()} | {:error, term()}
  def android(agent_id, target, action),
    do: impl().android(agent_id, target, action)

  @spec process_list(String.t(), target()) :: {:ok, map()} | {:error, term()}
  def process_list(agent_id, target),
    do: impl().process_list(agent_id, target)

  @spec process_write(String.t(), target(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def process_write(agent_id, target, process_name, data, opts \\ %{}),
    do: impl().process_write(agent_id, target, process_name, data, opts)

  @spec process_tail(String.t(), target(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def process_tail(agent_id, target, process_name, opts \\ %{}),
    do: impl().process_tail(agent_id, target, process_name, opts)

  @spec read_stream(String.t(), target(), String.t()) ::
          {:ok, Enumerable.t(), non_neg_integer() | nil} | {:error, term()}
  def read_stream(agent_id, target, path),
    do: impl().read_stream(agent_id, target, path)

  @spec write_stream(String.t(), target(), String.t(), Enumerable.t()) ::
          {:ok, map()} | {:error, term()}
  def write_stream(agent_id, target, path, stream),
    do: impl().write_stream(agent_id, target, path, stream)

  def create_device_install(agent_id, name), do: impl().create_device_install(agent_id, name)

  defp impl, do: Application.get_env(:salix_agent, :env_dispatch, __MODULE__.None)

  defmodule None do
    @moduledoc """
    Default implementation: no remote connector is attached to this node.
    Every call returns `{:error, :no_environment}`.
    """
    @behaviour SalixAgent.EnvDispatch

    @impl true
    def create_device_install(_agent_id, _name), do: {:error, :no_environment}

    @impl true
    def list_devices(_agent_id, _opts), do: {:error, :no_environment}

    @impl true
    def list_envs(_agent_id), do: {:error, :no_environment}

    @impl true
    def get_device(_agent_id, _device_id), do: {:error, :no_environment}

    @impl true
    def exec(_agent_id, _target, _cmd, _opts), do: {:error, :no_environment}

    @impl true
    def request(_agent_id, _target, _method, _params), do: {:error, :no_environment}

    @impl true
    def computer_use(_agent_id, _target, _action), do: {:error, :no_environment}

    @impl true
    def android(_agent_id, _target, _action), do: {:error, :no_environment}

    @impl true
    def process_list(_agent_id, _target), do: {:error, :no_environment}

    @impl true
    def process_write(_agent_id, _target, _process_name, _data, _opts),
      do: {:error, :no_environment}

    @impl true
    def process_tail(_agent_id, _target, _process_name, _opts),
      do: {:error, :no_environment}

    @impl true
    def read_stream(_agent_id, _target, _path), do: {:error, :no_environment}

    @impl true
    def write_stream(_agent_id, _target, _path, _body), do: {:error, :no_environment}
  end
end
