defmodule SalixSignalProto.GroupCall.Frame do
  @moduledoc """
  End-to-end frame encryption of group calls (CRS-14 section 8).

  Every audio frame and every device-to-device message sent through the
  SFU is encrypted before SRTP, so the SFU cannot read it.

  ## Key schedule (section 8.1)

  A send state is a 32-byte `secret` and an 8-bit ratchet counter. From a
  secret: `aes_key` and `hmac_key` are HKDF-SHA256 outputs with no salt and
  the infos `RingRTC AES Key` and `RingRTC HMAC Key`; the next secret uses
  `RingRTC Ratchet`, and the counter advances modulo 256.

  ## Frame layout (section 8.2)

  `IV = BE(f, 8) || 0x00 * 8`, where `f` is the frame counter. The
  ciphertext `C` is AES-256-CTR of the plaintext with `IV` as the initial
  counter block. The MAC is the first 16 bytes of
  `HMAC(hmac_key, IV || BE(len(C), 4) || C || 0x00 * 4)`. A frame is
  `C || n || BE(f, 4) || MAC`, a 21-byte footer.

  ## Sending and receiving

  `Sender` holds the device's send state and frame counter. The frame
  counter starts at 1, increases for every frame and data message across
  all streams, is never reset by a key change, and stops sending after
  `2^32 - 1`.

  `Receiver` holds the keys received from one sender device, at most 5
  (section 8.3). A frame is valid if some held key, advanced forward until
  its counter equals the frame's counter byte, verifies the MAC. Advanced
  secrets are cached per held key, so each ratchet step is computed once.
  """

  alias SalixSignalProto.Crypto.{Hkdf, Hmac}

  @aes_info "RingRTC AES Key"
  @hmac_info "RingRTC HMAC Key"
  @ratchet_info "RingRTC Ratchet"
  @footer_bytes 21
  @mac_bytes 16
  @max_frame_counter 0xFFFFFFFF

  @type secret :: <<_::256>>
  @type keys :: %{aes_key: <<_::256>>, hmac_key: <<_::256>>}

  # -- Key schedule ------------------------------------------------------------

  @doc "The AES and HMAC keys of `secret` (section 8.1)."
  @spec keys(secret()) :: keys()
  def keys(<<_::binary-32>> = secret) do
    %{aes_key: hkdf(secret, @aes_info), hmac_key: hkdf(secret, @hmac_info)}
  end

  @doc "The secret of the next ratchet state."
  @spec next_secret(secret()) :: secret()
  def next_secret(<<_::binary-32>> = secret), do: hkdf(secret, @ratchet_info)

  @doc "Advances `{counter, secret}` by `steps` ratchet steps; the counter wraps at 256."
  @spec advance({0..255, secret()}, non_neg_integer()) :: {0..255, secret()}
  def advance({counter, secret}, 0), do: {counter, secret}

  def advance({counter, secret}, steps) when steps > 0,
    do: advance({rem(counter + 1, 256), next_secret(secret)}, steps - 1)

  defp hkdf(secret, info), do: Hkdf.derive(secret, <<0::256>>, info, 32)

  # -- One frame ---------------------------------------------------------------

  @doc """
  Encrypts `plaintext` with the keys of ratchet counter `counter` and frame
  counter `frame_counter` (1 to `2^32 - 1`). Returns the frame.
  """
  @spec encrypt(binary(), keys(), 0..255, pos_integer()) :: binary()
  def encrypt(plaintext, %{aes_key: aes_key, hmac_key: hmac_key}, counter, frame_counter)
      when counter in 0..255 and frame_counter in 1..@max_frame_counter do
    iv = iv(frame_counter)
    cipher = :crypto.crypto_one_time(:aes_256_ctr, aes_key, iv, plaintext, true)
    <<cipher::binary, counter, frame_counter::32, mac(hmac_key, iv, cipher)::binary>>
  end

  @doc """
  Splits a frame into `{ciphertext, ratchet_counter, frame_counter, mac}`.
  A frame shorter than the 21-byte footer is malformed.
  """
  @spec split(binary()) :: {:ok, {binary(), 0..255, non_neg_integer(), binary()}} | :error
  def split(frame) when is_binary(frame) and byte_size(frame) >= @footer_bytes do
    size = byte_size(frame) - @footer_bytes
    <<cipher::binary-size(^size), counter, f::32, mac::binary-16>> = frame
    {:ok, {cipher, counter, f, mac}}
  end

  def split(_frame), do: :error

  @doc "Verifies and decrypts one split frame with `keys`. Constant-time MAC check."
  @spec open({binary(), 0..255, non_neg_integer(), binary()}, keys()) ::
          {:ok, binary()} | :error
  def open({cipher, _counter, f, mac}, %{aes_key: aes_key, hmac_key: hmac_key}) do
    iv = iv(f)

    if Hmac.equal?(mac(hmac_key, iv, cipher), mac),
      do: {:ok, :crypto.crypto_one_time(:aes_256_ctr, aes_key, iv, cipher, false)},
      else: :error
  end

  defp iv(f), do: <<f::64, 0::64>>

  defp mac(hmac_key, iv, cipher) do
    <<mac::binary-size(@mac_bytes), _::binary>> =
      Hmac.sha256(hmac_key, [iv, <<byte_size(cipher)::32>>, cipher, <<0::32>>])

    mac
  end

  # -- Sender ------------------------------------------------------------------

  defmodule Sender do
    @moduledoc """
    The send state of this device (CRS-14 sections 8.1, 8.2 and 9.3): the
    current key, the next frame counter, and the keys of the current state.
    """

    alias SalixSignalProto.GroupCall.Frame

    defstruct [:secret, :counter, :keys, frame_counter: 1]

    @type t :: %__MODULE__{}

    @doc "A send state with a fresh random secret and ratchet counter 0."
    @spec new(Frame.secret()) :: t()
    def new(secret \\ :crypto.strong_rand_bytes(32)), do: use_key(%__MODULE__{}, 0, secret)

    @doc "Advances the key one ratchet step (section 9.3, devices appeared)."
    @spec advance(t()) :: t()
    def advance(%__MODULE__{counter: counter, secret: secret} = sender) do
      {counter, secret} = Frame.advance({counter, secret}, 1)
      use_key(sender, counter, secret)
    end

    @doc "Switches to another key, keeping the frame counter."
    @spec use_key(t(), 0..255, Frame.secret()) :: t()
    def use_key(%__MODULE__{} = sender, counter, <<_::binary-32>> = secret),
      do: %{sender | counter: counter, secret: secret, keys: Frame.keys(secret)}

    @doc "The current key as `{ratchet_counter, secret}`."
    @spec key(t()) :: {0..255, Frame.secret()}
    def key(%__MODULE__{counter: counter, secret: secret}), do: {counter, secret}

    @doc """
    Encrypts one frame and advances the frame counter. After frame counter
    `2^32 - 1` nothing more is sent.
    """
    @spec encrypt(t(), binary()) :: {:ok, binary(), t()} | {:error, :exhausted}
    def encrypt(%__MODULE__{frame_counter: f}, _plaintext) when f > 0xFFFFFFFF,
      do: {:error, :exhausted}

    def encrypt(%__MODULE__{} = sender, plaintext) do
      frame = Frame.encrypt(plaintext, sender.keys, sender.counter, sender.frame_counter)
      {:ok, frame, %{sender | frame_counter: sender.frame_counter + 1}}
    end
  end

  # -- Receiver ----------------------------------------------------------------

  defmodule Receiver do
    @moduledoc """
    The keys received from one sender device (CRS-14 sections 8.3 and 9.4),
    newest first, at most `SalixSignalProto.GroupCall.max_receive_states/0`.
    Each held key caches the secrets it was advanced to and the keys of the
    last counter used.
    """

    alias SalixSignalProto.GroupCall
    alias SalixSignalProto.GroupCall.Frame

    defstruct states: []

    @type t :: %__MODULE__{}

    @doc "An empty receiver."
    @spec new() :: t()
    def new, do: %__MODULE__{}

    @doc "Adds a received key `{ratchet_counter, secret}` as the newest state."
    @spec add_key(t(), {0..255, Frame.secret()}) :: t()
    def add_key(%__MODULE__{states: states} = receiver, {counter, <<_::binary-32>> = secret})
        when counter in 0..255 do
      if Enum.any?(states, &(&1.base == {counter, secret})) do
        receiver
      else
        state = %{base: {counter, secret}, chain: %{0 => secret}, last: nil}
        %{receiver | states: Enum.take([state | states], GroupCall.max_receive_states())}
      end
    end

    @doc "True when no key was received yet."
    @spec empty?(t()) :: boolean()
    def empty?(%__MODULE__{states: states}), do: states == []

    @doc "Verifies and decrypts one frame. Returns the plaintext and the receiver with warmer caches."
    @spec decrypt(t(), binary()) :: {:ok, binary(), t()} | {:error, :malformed | :authentication}
    def decrypt(%__MODULE__{} = receiver, frame) do
      case Frame.split(frame) do
        {:ok, split} -> try_states(receiver.states, split, [], receiver)
        :error -> {:error, :malformed}
      end
    end

    defp try_states([], _split, _seen, _receiver), do: {:error, :authentication}

    defp try_states([state | rest], {_c, n, _f, _m} = split, seen, receiver) do
      {keys, state} = keys_at(state, n)

      case Frame.open(split, keys) do
        {:ok, plaintext} ->
          {:ok, plaintext, %{receiver | states: Enum.reverse(seen, [state | rest])}}

        :error ->
          try_states(rest, split, [state | seen], receiver)
      end
    end

    defp keys_at(%{last: {n, keys}} = state, n), do: {keys, state}

    defp keys_at(%{base: {base, _secret}} = state, n) do
      steps = Integer.mod(n - base, 256)
      {secret, chain} = secret_at(state.chain, steps)
      keys = Frame.keys(secret)
      {keys, %{state | chain: chain, last: {n, keys}}}
    end

    # The chain maps a step count to its secret; missing steps are derived
    # from the highest cached one below.
    defp secret_at(chain, steps) do
      case chain do
        %{^steps => secret} ->
          {secret, chain}

        _ ->
          from = chain |> Map.keys() |> Enum.filter(&(&1 < steps)) |> Enum.max()

          Enum.reduce((from + 1)..steps//1, {chain[from], chain}, fn step, {secret, chain} ->
            next = Frame.next_secret(secret)
            {next, Map.put(chain, step, next)}
          end)
      end
    end
  end
end
