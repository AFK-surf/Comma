defmodule SalixAgent.SSH.KeyCallback do
  @moduledoc """
  OTP `:ssh_client_key_api` for Group SSH connections.

  Host keys are checked against the Group's trust database
  (`SalixAgent.SSH.KnownHosts`) under the host name the Agent typed, not the
  resolved address the connection uses. OTP calls `is_host_key/5` during key
  exchange, before user authentication, so a rejected host never receives a
  signature from the Group key. The outcome is sent to the connecting process,
  which reports it to the Agent.

  The user key is the Group's Ed25519 key (`SalixAgent.SSH.Identity`). No
  ambient `~/.ssh` file is read or written.
  """

  @behaviour :ssh_client_key_api

  alias SalixAgent.SSH.KnownHosts

  @impl true
  def is_host_key(key, _host, _port, _algorithm, options) do
    opts = Keyword.fetch!(options, :key_cb_private)

    # OTP terminates the SSH client on any linked process exit, including
    # :normal. Storage requests use linked tasks, so run them outside the SSH
    # process. S3 bounds its requests; SSH retains its negotiation timeout.
    result =
      Task.Supervisor.async_nolink(SalixAgent.TaskSup, fn ->
        KnownHosts.check(
          Keyword.fetch!(opts, :group_id),
          Keyword.fetch!(opts, :host),
          Keyword.fetch!(opts, :port),
          key,
          Keyword.get(opts, :agent_id)
        )
      end)
      |> Task.await(:infinity)

    send(Keyword.fetch!(opts, :owner), {Keyword.fetch!(opts, :ref), {:host_key, result}})
    match?({:ok, _status, _entry}, result)
  end

  @impl true
  def add_host_key(_host, _port, _key, _options), do: :ok

  @impl true
  def user_key(:"ssh-ed25519", options) do
    public_key = options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:public_key)
    {:ok, {:ssh2_pubkey, :ssh_file.encode(public_key, :ssh2_pubkey)}}
  end

  def user_key(_algorithm, _options), do: {:error, :unsupported_algorithm}

  # OTP's private-key signer also checks preferred_algorithms.public_key, which
  # pins the server's host-key type. Its signing callback (used by :ssh_agent)
  # keeps Ed25519 client authentication independent of that host-key restriction.
  @doc false
  @impl true
  def sign(_public_key_blob, data, options) do
    private_key = options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:private_key)
    :public_key.sign(data, :none, private_key)
  end
end
