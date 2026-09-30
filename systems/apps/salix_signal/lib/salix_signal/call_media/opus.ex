defmodule SalixSignal.CallMedia.Opus do
  @moduledoc """
  Opus codec for Signal call media (CRS-13 section 7), through a small NIF
  over libopus (c_src/salix_signal_opus.c).

  The call core uses 16-bit little-endian mono PCM at 24 kHz, the GPT-Live
  format. libopus encodes from and decodes to 24 kHz directly, while the RTP
  timestamps stay on the 48 kHz Opus clock (RFC 7587), so no separate
  resampler is needed.

  The encoder follows the CRS-13 section 7 defaults: 60 ms packets, mono,
  32 kbit/s CBR, in-band FEC, DTX and complexity 9. The decoder accepts any
  valid Opus packet duration, conceals lost packets and uses the in-band FEC
  of the next packet when one arrived.

  Why a Comma-owned NIF, not `membrane_opus_plugin`: that plugin's public
  interface is a Membrane pipeline element (it brings `membrane_core`,
  `bundlex` and `unifex`), its direct codec functions are private, and they
  do not expose the FEC, DTX and CBR settings above.
  """

  @rate 24_000
  @frame_ms 60

  defmodule Native do
    @moduledoc false
    @on_load :load_nif

    def load_nif do
      :salix_signal
      |> :code.priv_dir()
      |> :filename.join(~c"salix_signal_opus")
      |> :erlang.load_nif(0)
    end

    def encoder_new(_rate, _bitrate, _complexity, _fec, _dtx, _cbr, _loss),
      do: :erlang.nif_error(:nif_not_loaded)

    def encode(_encoder, _pcm), do: :erlang.nif_error(:nif_not_loaded)
    def decoder_new(_rate), do: :erlang.nif_error(:nif_not_loaded)
    def decode(_decoder, _packet, _samples, _fec), do: :erlang.nif_error(:nif_not_loaded)
    def packet_samples(_packet, _rate), do: :erlang.nif_error(:nif_not_loaded)
  end

  @doc "Sample rate of the PCM this module takes and returns."
  def rate, do: @rate

  @doc "Duration of one sent packet in milliseconds."
  def frame_ms, do: @frame_ms

  @doc "Bytes of PCM in one sent packet."
  def frame_bytes, do: div(@rate * @frame_ms, 1000) * 2

  @doc "RTP timestamp advance for `samples` at the codec rate (48 kHz clock)."
  def rtp_ticks(samples), do: div(samples * 48_000, @rate)

  @doc """
  A new encoder. Options: `:bitrate` (32_000), `:complexity` (9), `:fec`
  (true), `:dtx` (true), `:cbr` (true), `:packet_loss_percent` (10, so the
  encoder spends bits on FEC).
  """
  @spec encoder(keyword()) :: {:ok, reference()} | {:error, atom()}
  def encoder(opts \\ []) do
    Native.encoder_new(
      @rate,
      Keyword.get(opts, :bitrate, 32_000),
      Keyword.get(opts, :complexity, 9),
      flag(Keyword.get(opts, :fec, true)),
      flag(Keyword.get(opts, :dtx, true)),
      flag(Keyword.get(opts, :cbr, true)),
      Keyword.get(opts, :packet_loss_percent, 10)
    )
  end

  @doc """
  Encodes one frame of PCM (a valid Opus duration: 2.5, 5, 10, 20, 40 or
  60 ms). A packet of 2 bytes or less is a DTX frame that need not be sent.
  """
  @spec encode(reference(), binary()) :: {:ok, binary()} | {:error, atom()}
  def encode(encoder, pcm), do: Native.encode(encoder, pcm)

  @doc "A new decoder."
  @spec decoder() :: {:ok, reference()} | {:error, atom()}
  def decoder, do: Native.decoder_new(@rate)

  @doc "Decodes one packet to PCM."
  @spec decode(reference(), binary()) :: {:ok, binary()} | {:error, atom()}
  def decode(decoder, packet) do
    with {:ok, samples} <- samples(packet), do: Native.decode(decoder, packet, samples, 0)
  end

  @doc """
  Rebuilds `samples` of lost audio: from the in-band FEC data of `next` (the
  packet after the loss) when given, else by concealment.
  """
  @spec conceal(reference(), binary() | nil, pos_integer()) :: {:ok, binary()} | {:error, atom()}
  def conceal(decoder, nil, samples), do: Native.decode(decoder, nil, samples, 0)
  def conceal(decoder, next, samples), do: Native.decode(decoder, next, samples, 1)

  @doc "Samples at the codec rate that `packet` decodes to."
  @spec samples(binary()) :: {:ok, pos_integer()} | {:error, atom()}
  def samples(packet) when is_binary(packet) and byte_size(packet) in 1..1500,
    do: Native.packet_samples(packet, @rate)

  def samples(_packet), do: {:error, :invalid_packet}

  defp flag(true), do: 1
  defp flag(false), do: 0
end
