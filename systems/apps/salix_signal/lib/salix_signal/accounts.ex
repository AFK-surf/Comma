defmodule SalixSignal.Accounts do
  @moduledoc """
  Signal account records and the placement of their owner processes.

  An account is a Signal account ID plus device ID that Comma registered as a
  primary device, owned by the platform or by one Organization (the Signal
  Account entity of the domain inventory). Its record and state live in
  `signal_accounts` (`SalixSignal.Storage`). Its only writer is one
  `SalixSignal.Account.Server` on the `SalixCluster.Ring` owner node of the
  account ID; `ensure_started/1` starts it there and `call/3` sends a
  request to it from any node. When the ring moves the account, the new
  owner claims it with a higher owner epoch and the old process is fenced
  (PLAN "Design rules").
  """

  alias SalixSignal.Account.{Registration, Server}
  alias SalixSignal.Storage

  @registry SalixSignal.Account.Registry
  @supervisor SalixSignal.Account.Supervisor

  @doc """
  Stores a registered account and returns its ID. `attrs`: `aci`, `pni`,
  `e164`, `device_id`, `password`, `identities` (`%{aci: key_pair, pni:
  key_pair | nil}`), `registration_ids`, `profile_key`, `pre_keys`
  (`%{aci: store, pni: store | nil}`), `scope` (`:platform` or
  `{:organization, id}`), `environment`, and optional `state` (default
  `:active`).
  """
  @spec create(map()) :: {:ok, String.t()} | {:error, term()}
  defdelegate create(attrs), to: Storage, as: :create_account

  @doc """
  Registers the E.164 `number` as a new primary device (CRS-02 §3) and
  returns the new account ID.

  The new keys, device password, registration IDs and profile key are
  stored (state `registering`) before the registration request is sent, so
  a crash after the service accepted the request never leaves it holding
  keys that Comma lacks. On success the account becomes `active`. On failure
  the stored account stays `registering`, and `resume_registration/4` sends
  the same keys again.

  `verification` is `{:session, id}` or `{:recovery_password, bytes}`.
  `attributes` are the account attributes of
  `SalixSignalProto.Registration.account_attributes/1`; the unidentified
  access key defaults to the one of the new profile key. Options:
  `:transport` (required, a `SalixSignal.Account.Transport`), `:scope`,
  `:environment`.

  Returns `{:ok, account_id}` or `{:error, reason, account_id | nil}`.
  """
  @spec register(String.t(), tuple(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term(), String.t() | nil}
  def register(number, verification, attributes, opts) do
    now = System.system_time(:millisecond)

    with {:ok, new} <- Registration.new_account(number, now),
         {:ok, id} <-
           Storage.create_account(%{
             state: :registering,
             aci: nil,
             pni: nil,
             e164: number,
             device_id: 1,
             password: new.password,
             identities: %{aci: new.aci.identity, pni: new.pni.identity},
             registration_ids: %{aci: new.registration_id, pni: new.pni_registration_id},
             profile_key: :crypto.strong_rand_bytes(32),
             pre_keys: %{aci: new.aci, pni: new.pni},
             scope: Keyword.get(opts, :scope, :platform),
             environment: Keyword.get(opts, :environment, :production)
           }) do
      resume_registration(id, verification, attributes, opts)
    else
      {:error, reason} -> {:error, reason, nil}
    end
  end

  @doc "Sends the registration of a stored `registering` account again (see `register/4`)."
  @spec resume_registration(String.t(), tuple(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term(), String.t()}
  def resume_registration(id, verification, attributes, opts) do
    transport = Keyword.fetch!(opts, :transport)

    with {:ok, %{account: new, profile_key: profile_key}} <- Storage.registration(id),
         attributes =
           Map.put_new_lazy(attributes, :unidentified_access_key, fn ->
             SalixSignalProto.SealedSender.AccessKey.derive(profile_key)
           end),
         {:ok, registered} <- Registration.register(transport, new, verification, attributes),
         :ok <- Storage.complete_registration(id, registered) do
      {:ok, id}
    else
      {:error, reason} -> {:error, reason, id}
    end
  end

  @doc "The account summary (no secrets)."
  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate get(id), to: Storage, as: :get_account

  @doc "The account registered with this ACI."
  @spec find_by_aci(String.t()) :: {:ok, map()} | {:error, term()}
  def find_by_aci(aci), do: Storage.find_account({:aci, aci})

  @doc "The account registered with this E.164 number."
  @spec find_by_number(String.t()) :: {:ok, map()} | {:error, term()}
  def find_by_number(e164), do: Storage.find_account({:number, e164})

  @doc """
  Every account stored with this E.164 number, in any state and
  environment, newest first (at most 50). A number can have an `active`
  account, a `registering` one left by a failed registration, and older
  `re_registering` or `retired` ones.
  """
  @spec list_by_number(String.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_by_number(e164), to: Storage, as: :accounts_by_number

  @doc "One page of account summaries (`:limit`, `:after`, `:state`)."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    case Storage.list_accounts(opts) do
      {:ok, accounts} -> accounts
      {:error, _reason} -> []
    end
  end

  @doc """
  Sets the account state. An account that is not `:active` stops at its
  next owner claim or keeper pass and is not started again.
  """
  @spec set_state(String.t(), :registering | :active | :re_registering | :retired) ::
          :ok | {:error, :not_found}
  def set_state(id, state) do
    with :ok <- Storage.set_state(id, state) do
      if state != :active, do: stop_everywhere(id)
      :ok
    end
  end

  defp stop_everywhere(id) do
    for node <- [node() | Node.list(:visible)] do
      :erpc.cast(node, __MODULE__, :stop_local, [id])
    end
  end

  @doc "The node that should own the account now."
  @spec owner_node(String.t()) :: node()
  def owner_node(id) do
    if Process.whereis(SalixCluster.Ring), do: SalixCluster.Ring.owner(id), else: node()
  end

  @doc "Starts the account's owner process on its ring owner node."
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(id) do
    case owner_node(id) do
      owner when owner == node() -> start_local(id)
      owner -> :erpc.call(owner, __MODULE__, :start_local, [id], 15_000)
    end
  rescue
    error -> {:error, {:owner_unreachable, error}}
  catch
    :exit, reason -> {:error, {:owner_unreachable, reason}}
  end

  @doc false
  # Starts the owner process on this node. `opts` are extra
  # `SalixSignal.Account.Server` options (tests).
  def start_local(id, opts \\ []) do
    case DynamicSupervisor.start_child(@supervisor, {Server, [account_id: id] ++ opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def stop_local(id) do
    case whereis(id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc "The account's owner process on this node, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Sends `request` to the account's owner process, starting it on its ring
  owner when it is not running.
  """
  @spec call(String.t(), term(), timeout()) :: term()
  def call(id, request, timeout \\ 60_000) do
    case owner_node(id) do
      owner when owner == node() -> call_local(id, request, timeout)
      owner -> :erpc.call(owner, __MODULE__, :call_local, [id, request, timeout], timeout + 5_000)
    end
  rescue
    _error -> {:error, :not_started}
  catch
    :exit, _reason -> {:error, :not_started}
  end

  @doc false
  def call_local(id, request, timeout) do
    with {:ok, pid} <- start_local(id) do
      GenServer.call(pid, request, timeout)
    end
  catch
    :exit, {{:shutdown, :fenced}, _} -> {:error, :fenced}
    :exit, _reason -> {:error, :not_started}
  end
end
