defmodule SalixSignalProto.SenderKey.Record do
  @moduledoc """
  Sender key state for one sender key identity: (sender service ID, sender
  device ID, distribution ID) (CRS-09c sections 1, 4 and 5).

  A record holds at most 5 chains, most recent first. Each chain has its
  chain ID, signing public key, message version, current chain key and
  iteration, and at most 2000 retained message seeds of skipped iterations.
  A chain that this device created also holds the signing private key; the
  device sends with the most recent chain.

  Key derivation (section 4): `CK_{i+1} = HMAC(CK_i, 0x02)`,
  `MS_i = HMAC(CK_i, 0x01)`, and `HKDF(no salt, MS_i, "WhisperGroup", 48)`
  gives the IV (bytes 0-15) and the AES-256-CBC key (bytes 16-47).

  `encode/1` and `decode/1` give a storage form that is local to Comma.
  """

  alias SalixSignalProto.Crypto.AesCbc
  alias SalixSignalProto.Crypto.Hkdf
  alias SalixSignalProto.Crypto.Hmac
  alias SalixSignalProto.Keys
  alias SalixSignalProto.SenderKey.Message

  @max_chains 5
  @max_skipped 2000
  @max_jump 25_000
  @max_iteration 0xFFFFFFFF
  @version 3
  @format_version 1

  defmodule Chain do
    @moduledoc false
    # skipped: [{iteration, message_seed}], oldest first.
    @enforce_keys [:chain_id, :signing_public, :iteration, :chain_key]
    defstruct [
      :chain_id,
      :signing_public,
      :iteration,
      :chain_key,
      signing_private: nil,
      version: 3,
      skipped: []
    ]
  end

  defstruct chains: []

  @type t :: %__MODULE__{chains: [%Chain{}]}

  @doc "An empty record."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates this device's sender key for `distribution_id` (section 6.1): a
  random 31-bit chain ID, a random chain key at iteration 0 and a new
  signing key pair. The new chain becomes the most recent.
  """
  @spec create(t(), keyword()) :: t()
  def create(%__MODULE__{} = record, opts \\ []) do
    <<_::1, random_chain_id::31>> = :crypto.strong_rand_bytes(4)
    signing = Keys.ec_keypair(Keyword.get(opts, :signing_private, :crypto.strong_rand_bytes(32)))

    chain = %Chain{
      chain_id: Keyword.get(opts, :chain_id, random_chain_id),
      signing_public: signing.public,
      signing_private: signing.private,
      iteration: Keyword.get(opts, :iteration, 0),
      chain_key: Keyword.get(opts, :chain_key, :crypto.strong_rand_bytes(32))
    }

    add_chain(record, chain)
  end

  @doc """
  The distribution message for the most recent chain: it carries the
  current chain key and iteration, so receivers decrypt from that
  iteration onward.
  """
  @spec distribution_message(t(), <<_::128>>) :: {:ok, binary()} | {:error, :no_sender_key}
  def distribution_message(
        %__MODULE__{chains: [chain | _]},
        <<_::binary-size(16)>> = distribution_id
      ) do
    {:ok,
     Message.encode_distribution(%{
       distribution_id: distribution_id,
       chain_id: chain.chain_id,
       iteration: chain.iteration,
       chain_key: chain.chain_key,
       signing_key: chain.signing_public
     })}
  end

  def distribution_message(%__MODULE__{chains: []}, _distribution_id),
    do: {:error, :no_sender_key}

  @doc """
  Processes a received distribution message (section 5). A message whose
  chain ID and signing key match a held chain only makes that chain the most
  recent. Any other replaces the chain with the same chain ID or adds one.
  """
  @spec process_distribution(t(), binary()) :: {:ok, t(), <<_::128>>} | {:error, atom()}
  def process_distribution(%__MODULE__{chains: chains} = record, bytes) do
    with {:ok, d} <- Message.decode_distribution(bytes) do
      case Enum.split_with(chains, &(&1.chain_id == d.chain_id)) do
        {[%Chain{signing_public: key} = held], others} when key == d.signing_key ->
          {:ok, %{record | chains: [held | others]}, d.distribution_id}

        {_replaced, others} ->
          chain = %Chain{
            chain_id: d.chain_id,
            signing_public: d.signing_key,
            iteration: d.iteration,
            chain_key: d.chain_key
          }

          {:ok, add_chain(%{record | chains: others}, chain), d.distribution_id}
      end
    end
  end

  defp add_chain(%__MODULE__{chains: chains} = record, chain),
    do: %{record | chains: Enum.take([chain | chains], @max_chains)}

  @doc """
  Encrypts padded content with this device's most recent chain (section
  4) and returns the signed sender key message. The chain moves to the next
  iteration.
  """
  @spec encrypt(t(), <<_::128>>, binary(), keyword()) :: {:ok, binary(), t()} | {:error, atom()}
  def encrypt(record, distribution_id, plaintext, opts \\ [])

  def encrypt(
        %__MODULE__{chains: [%Chain{signing_private: private} = chain | rest]} = record,
        <<_::binary-size(16)>> = distribution_id,
        plaintext,
        opts
      )
      when is_binary(private) and is_binary(plaintext) do
    if chain.iteration >= @max_iteration do
      {:error, :iteration_overflow}
    else
      {iv, key} = message_keys(message_seed(chain.chain_key))

      message =
        Message.encode_message(
          %{
            distribution_id: distribution_id,
            chain_id: chain.chain_id,
            iteration: chain.iteration,
            ciphertext: AesCbc.encrypt(key, iv, plaintext)
          },
          private,
          Keyword.get(opts, :random, :crypto.strong_rand_bytes(64))
        )

      next = %{chain | iteration: chain.iteration + 1, chain_key: next_chain_key(chain.chain_key)}
      {:ok, message, %{record | chains: [next | rest]}}
    end
  end

  def encrypt(%__MODULE__{}, _distribution_id, _plaintext, _opts), do: {:error, :no_sender_key}

  @doc """
  Decrypts a sender key message (section 5). Errors: `:no_sender_key`,
  `:invalid_version`, `:bad_signature`, `:duplicate`, `:too_far_ahead`,
  `:invalid_ciphertext`, and the decode errors of
  `SalixSignalProto.SenderKey.Message.decode_message/1`.
  """
  @spec decrypt(t(), binary()) :: {:ok, binary(), t()} | {:error, atom()}
  def decrypt(%__MODULE__{chains: chains} = record, bytes) do
    with {:ok, message} <- Message.decode_message(bytes),
         {:ok, chain} <- find_chain(chains, message.chain_id),
         :ok <- if(chain.version == @version, do: :ok, else: {:error, :invalid_version}),
         :ok <-
           if(Message.verify(message, chain.signing_public),
             do: :ok,
             else: {:error, :bad_signature}
           ),
         {:ok, seed, chain} <- take_seed(chain, message.iteration),
         {iv, key} = message_keys(seed),
         {:ok, plaintext} <- cbc_decrypt(key, iv, message.ciphertext) do
      updated = Enum.map(chains, &if(&1.chain_id == chain.chain_id, do: chain, else: &1))
      {:ok, plaintext, %{record | chains: updated}}
    end
  end

  defp find_chain(chains, chain_id) do
    case Enum.find(chains, &(&1.chain_id == chain_id)) do
      nil -> {:error, :no_sender_key}
      chain -> {:ok, chain}
    end
  end

  defp cbc_decrypt(key, iv, ciphertext) do
    case AesCbc.decrypt(key, iv, ciphertext) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, :invalid} -> {:error, :invalid_ciphertext}
    end
  end

  # The message seed for iteration n, and the chain after using it.
  defp take_seed(%Chain{iteration: j} = chain, n) when n < j do
    case List.keytake(chain.skipped, n, 0) do
      {{^n, seed}, skipped} -> {:ok, seed, %{chain | skipped: skipped}}
      nil -> {:error, :duplicate}
    end
  end

  defp take_seed(%Chain{iteration: j}, n) when n - j > @max_jump, do: {:error, :too_far_ahead}

  defp take_seed(%Chain{iteration: j, chain_key: ck} = chain, n) do
    # Retain the seeds of j .. n-1, keeping only the newest 2000 overall.
    keep_from = max(j, n - @max_skipped)
    {ck, new_skipped} = advance(ck, j, n, keep_from, [])
    skipped = Enum.take(chain.skipped ++ Enum.reverse(new_skipped), -@max_skipped)

    {:ok, message_seed(ck),
     %{chain | iteration: n + 1, chain_key: next_chain_key(ck), skipped: skipped}}
  end

  defp advance(ck, i, n, _keep_from, acc) when i == n, do: {ck, acc}

  defp advance(ck, i, n, keep_from, acc) do
    acc = if i >= keep_from, do: [{i, message_seed(ck)} | acc], else: acc
    advance(next_chain_key(ck), i + 1, n, keep_from, acc)
  end

  @doc false
  def next_chain_key(chain_key), do: Hmac.sha256(chain_key, <<0x02>>)

  @doc false
  def message_seed(chain_key), do: Hmac.sha256(chain_key, <<0x01>>)

  @doc false
  def message_keys(seed) do
    <<iv::binary-size(16), key::binary-size(32)>> = Hkdf.derive(seed, "", "WhisperGroup", 48)
    {iv, key}
  end

  @doc "Encodes the record for storage."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = record),
    do: :erlang.term_to_binary({__MODULE__, @format_version, record}, [:deterministic])

  @doc "Decodes a stored record."
  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_record}
  def decode(bytes) when is_binary(bytes) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      {__MODULE__, @format_version, %__MODULE__{chains: chains} = record} when is_list(chains) ->
        if Enum.all?(chains, &is_struct(&1, Chain)),
          do: {:ok, record},
          else: {:error, :invalid_record}

      _ ->
        {:error, :invalid_record}
    end
  rescue
    ArgumentError -> {:error, :invalid_record}
  end
end
