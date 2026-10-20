defmodule SalixMeetNative.MediaSession do
  @moduledoc false

  alias SalixMeetNative.Codec
  alias SalixMeetNative.Wire

  defmodule Candidate do
    @moduledoc false
    defstruct [:transport, :ip, :port, :priority]
  end

  defmodule Channel do
    @moduledoc false
    defstruct [:label, :id, ordered: false, max_packet_life_time: 0]
  end

  defmodule Answer do
    @moduledoc false
    defstruct [
      :session_id,
      :fingerprint,
      :setup_role,
      :ice_ufrag,
      :ice_pwd,
      candidates: [],
      channels: []
    ]
  end

  @spec build_offer(binary(), String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, atom()}
  def build_offer(template, fingerprint, ufrag, pwd) do
    with {:ok,
          %Wire.CreateMediaSessionRequest{wrapper: %Wire.CreateMediaSessionWrapper{} = wrapper} =
            req} <-
           decode_template(template),
         %Wire.MediaSessionOffer{
           dtls: %Wire.DTLSTransport{fingerprint: %Wire.Fingerprint{} = fp} = dtls,
           ice: %Wire.ICETransport{} = ice
         } = offer <-
           wrapper.offer || {:error, :offer_template_missing_offer} do
      bandwidth = %{
        (offer.bandwidth || %Wire.BandwidthSettings{})
        | start_bitrate_kbps: 4000
      }

      offer = %{
        offer
        | dtls: %{dtls | fingerprint: %{fp | digest: fingerprint}},
          ice: %{ice | username_fragment: ufrag, password: pwd},
          bandwidth: bandwidth
      }

      {:ok, Codec.encode(%{req | wrapper: %{wrapper | media_session: "", offer: offer}})}
    else
      {:error, _} = error -> error
      _ -> {:error, :offer_template_invalid}
    end
  end

  defp decode_template(template) do
    case Codec.decode(Wire.CreateMediaSessionRequest, template) do
      {:ok, req} -> {:ok, req}
      :error -> {:error, :offer_template_undecodable}
    end
  end

  @spec decode_answer(binary()) :: {:ok, %Answer{}} | :error
  def decode_answer(raw) do
    case Codec.decode_rpc_response(Wire.CreateMediaSessionResponse, raw) do
      {:ok, %Wire.CreateMediaSessionResponse{transport: %Wire.MediaSessionTransport{} = t} = resp} ->
        {:ok,
         %Answer{
           session_id: resp.session_id,
           fingerprint: t.dtls && t.dtls.fingerprint && t.dtls.fingerprint.digest,
           setup_role: t.dtls && t.dtls.setup_role,
           ice_ufrag: t.ice && t.ice.username_fragment,
           ice_pwd: t.ice && t.ice.password,
           candidates:
             for c <- t.candidates, c.ip != "", c.port != 0 do
               %Candidate{
                 transport: transport(c.transport_type),
                 ip: c.ip,
                 port: c.port,
                 priority: c.priority
               }
             end,
           channels:
             for d <- t.data_channels, d.label != "" do
               %Channel{
                 label: d.label,
                 id: d.id,
                 ordered: d.ordered == true,
                 max_packet_life_time: d.max_packet_life_time || 0
               }
             end
         }}

      _ ->
        :error
    end
  end

  @spec media_session_id(%Answer{}) :: String.t()
  def media_session_id(%Answer{session_id: id}),
    do: String.replace_prefix(id || "", "mediasessions/", "")

  @spec candidate_type(%Candidate{}) :: :host | :srflx
  def candidate_type(%Candidate{transport: :tcp}), do: :host
  def candidate_type(%Candidate{port: 19_305}), do: :srflx
  def candidate_type(%Candidate{}), do: :host

  @spec preferred_candidate(%Answer{}) :: %Candidate{} | nil
  def preferred_candidate(%Answer{candidates: candidates}) do
    v4? = fn ip -> not String.contains?(ip, ":") end

    [
      &(&1.transport == :udp and &1.port == 19_305 and v4?.(&1.ip)),
      &(&1.transport == :udp and &1.port == 19_305),
      &(&1.transport == :udp and v4?.(&1.ip)),
      fn _ -> true end
    ]
    |> Enum.find_value(fn want -> Enum.find(candidates, want) end)
  end

  @spec candidate_line(%Candidate{}) :: String.t()
  def candidate_line(%Candidate{} = c) do
    base = "candidate:1 1 #{c.transport} #{c.priority} #{c.ip} #{c.port} typ #{candidate_type(c)}"
    if c.transport == :tcp, do: base <> " tcptype passive", else: base
  end

  defp transport(:ICE_TRANSPORT_TYPE_TCP), do: :tcp
  defp transport(3), do: :tcp
  defp transport(_), do: :udp
end
