defmodule SalixAgent.Colab.KeyCallback do
  @moduledoc """
  OTP `:ssh_client_key_api` for Google Colab WebSocket-SSH tunnels.

  - Uses an ephemeral in-memory Ed25519 keypair per tunnel (never the Group SSH key).
  - Never reads or writes Group `known_hosts`.
  - Pins the server host key SHA-256 fingerprint onto `colab_vm_leases.host_key_fingerprint`
    on first connect (fenced on `generation`) and fails closed on mismatch.
  - Runs the DB pin check via `SystemsRuntime.TaskSupervisor.async_nolink/2` so OTP `:ssh`
    never sees a linked task exit.
  """

  @behaviour :ssh_client_key_api

  alias SalixAgent.Colab.Leases

  @ed25519 {1, 3, 101, 112}

  @type ephemeral_keypair :: %{
          private_key: tuple(),
          public_key: tuple(),
          public_key_line: String.t(),
          fingerprint: String.t()
        }

  @doc "Generate a fresh in-memory Ed25519 keypair and OpenSSH `ssh-ed25519` public key line."
  @spec generate_ephemeral_keypair() :: ephemeral_keypair()
  def generate_ephemeral_keypair do
    {public, private} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
    curve = {:namedCurve, @ed25519}
    public_key = {{:ECPoint, public}, curve}
    private_key = {:ECPrivateKey, :ecPrivkeyVer1, private, curve, public, :asn1_NOVALUE}

    public_key_line =
      [{public_key, [comment: ~c"comma-colab"]}]
      |> :ssh_file.encode(:openssh_key)
      |> String.trim()

    %{
      private_key: private_key,
      public_key: public_key,
      public_key_line: public_key_line,
      fingerprint: to_string(:ssh.hostkey_fingerprint(:sha256, public_key))
    }
  end

  @impl true
  def is_host_key(key, _host, _port, _algorithm, options) do
    opts = Keyword.fetch!(options, :key_cb_private)
    fingerprint = to_string(:ssh.hostkey_fingerprint(:sha256, key))
    pin_fn = Keyword.get(opts, :pin_fn, &Leases.pin_host_key/3)
    vm_id = Keyword.fetch!(opts, :vm_id)
    generation = Keyword.fetch!(opts, :generation)

    # OTP terminates the SSH client on any linked process exit, including :normal.
    # Run DB I/O via async_nolink outside the SSH client process.
    result =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        pin_fn.(vm_id, generation, fingerprint)
      end)
      |> SystemsRuntime.Task.await(:infinity)

    SystemsRuntime.Proc.send(
      Keyword.fetch!(opts, :owner),
      {Keyword.fetch!(opts, :ref), {:host_key, result}}
    )

    match?({:ok, _status, _fp}, result)
  end

  @impl true
  def add_host_key(_host, _port, _key, _options), do: :ok

  @impl true
  def user_key(:"ssh-ed25519", options) do
    public_key = options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:public_key)
    {:ok, {:ssh2_pubkey, :ssh_file.encode(public_key, :ssh2_pubkey)}}
  end

  def user_key(_algorithm, _options), do: {:error, :unsupported_algorithm}

  @doc false
  @impl true
  def sign(_public_key_blob, data, options) do
    private_key = options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:private_key)
    :public_key.sign(data, :none, private_key)
  end
end
