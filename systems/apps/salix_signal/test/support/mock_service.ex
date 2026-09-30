defmodule SalixSignal.Test.MockService do
  @moduledoc false
  # A clean mock of the Signal message service for pipeline tests, written
  # from CRS-03 §9.5, CRS-05 §3, CRS-06 §3.6 and §4.2 and CRS-07 §3 to §7.
  # It runs in one Agent and answers requests through transport functions
  # with the signature SalixSignal.Messaging.Pipeline takes.
  #
  # Accounts have devices with a registration ID, published pre-keys and a
  # queue of envelopes. Sends check the device list (409 missing and extra,
  # 410 stale; 410 first) and the unidentified access key, then queue one
  # envelope per device with a fresh server GUID. Acknowledging an
  # identified envelope queues a server delivery receipt for its sender
  # (CRS-07 §5.3, §7.1). A send must list every device of the account, for
  # every envelope kind and content, retry requests and their answers
  # included (CRS-07 §4).
  #
  # Multi-recipient sends (CRS-06 §8.3, §8.4 and §10.2, CRS-07 §3.3) need a
  # Group-Send-Token that `group_send_verifier` accepts (a function of the
  # token bytes and the recipient service IDs; default: any token), check
  # every recipient's device list (409 before 410), and queue the
  # per-recipient delivery bytes as a sealed envelope for each device.

  use Agent

  alias SalixSignal.Service.Response
  alias SalixSignalProto.{Keys, SealedSender, ServiceId}
  alias SalixSignalProto.Message.Envelope
  alias SalixSignalProto.SealedSender.Certificate

  @max_payload 98_304

  def start_link(opts \\ []) do
    root = Keys.ec_keypair()
    server = Keys.ec_keypair()

    Agent.start_link(fn ->
      %{
        accounts: %{},
        clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end),
        certificate_lifetime_ms: Keyword.get(opts, :certificate_lifetime_ms, 7 * 86_400_000),
        group_send_verifier: Keyword.get(opts, :group_send_verifier, fn _token, _ids -> true end),
        root: root,
        server: server,
        server_certificate: Certificate.issue_server(1, server.public, root.private),
        requests: []
      }
    end)
  end

  def trust_root(service), do: Agent.get(service, & &1.root.public)
  def requests(service), do: Agent.get(service, &Enum.reverse(&1.requests))

  @doc false
  # Registers a device: `keys` is a pre-key upload body (CRS-03 §9.2).
  def register(service, aci, device_id, registration_id, identity_key, keys, opts \\ []) do
    Agent.update(service, fn s ->
      account =
        Map.get(s.accounts, aci, %{
          identity_key: identity_key,
          access_key: Keyword.get(opts, :access_key),
          unrestricted: Keyword.get(opts, :unrestricted, false),
          devices: %{}
        })

      device = %{
        registration_id: registration_id,
        signed: keys["signedPreKey"],
        one_time: Map.get(keys, "preKeys", []),
        kem: Map.get(keys, "pqPreKeys", []),
        last_resort: keys["pqLastResortPreKey"],
        queue: []
      }

      put_in(s, [:accounts, aci], %{
        account
        | devices: Map.put(account.devices, device_id, device)
      })
    end)
  end

  def remove_device(service, aci, device_id),
    do:
      Agent.update(
        service,
        &update_in(&1, [:accounts, aci, :devices], fn d -> Map.delete(d, device_id) end)
      )

  def set_registration_id(service, aci, device_id, registration_id),
    do:
      Agent.update(
        service,
        &put_in(&1, [:accounts, aci, :devices, device_id, :registration_id], registration_id)
      )

  @doc false
  # The envelopes queued for a device, oldest first, as {guid, bytes}.
  def queued(service, aci, device_id) do
    Agent.get(service, fn s ->
      for envelope <- s.accounts[aci].devices[device_id].queue,
          do: {envelope.server_guid, Envelope.encode(envelope)}
    end)
  end

  @doc false
  # Acknowledges an envelope: removes it, and queues a server delivery
  # receipt to the sender of an identified envelope that is not a receipt.
  def ack(service, aci, device_id, guid) do
    Agent.update(service, fn s ->
      queue = s.accounts[aci].devices[device_id].queue
      {acked, queue} = Enum.split_with(queue, &(&1.server_guid == guid))
      s = put_in(s, [:accounts, aci, :devices, device_id, :queue], queue)

      case acked do
        [%Envelope{kind: kind, source: {:aci, sender}} = envelope] when kind != 5 ->
          receipt = %Envelope{
            kind: 5,
            client_timestamp: envelope.client_timestamp,
            source: {:aci, aci_uuid(aci)},
            source_device: device_id,
            urgent: false,
            server_timestamp: s.clock.()
          }

          queue_all(s, ServiceId.uuid_string(sender), receipt)

        _ ->
          s
      end
    end)
  end

  @doc false
  # Transport function: `as` is {:identified, aci, device_id} or :unidentified.
  def transport(service, as),
    do: fn method, path, opts -> request(service, as, method, path, opts) end

  defp request(service, as, method, path, opts) do
    Agent.get_and_update(service, fn s ->
      s = %{s | requests: [{as, method, path, opts} | s.requests]}
      {response, s} = handle(s, as, method, URI.parse(path), opts)
      {{:ok, response}, s}
    end)
  end

  defp handle(s, :unidentified, "PUT", %URI{path: "/v1/messages/multi_recipient"} = uri, opts),
    do: send_multi(s, URI.decode_query(uri.query || ""), opts)

  defp handle(s, as, "PUT", %URI{path: "/v1/messages/" <> destination}, opts),
    do: send_message(s, as, destination, opts)

  defp handle(s, as, "GET", %URI{path: "/v2/keys/" <> rest}, opts) do
    [destination, device] = String.split(rest, "/")
    keys(s, as, destination, device, opts)
  end

  defp handle(
         s,
         {:identified, aci, device_id},
         "GET",
         %URI{path: "/v1/certificate/delivery"},
         _opts
       ) do
    account = s.accounts[aci]

    certificate =
      Certificate.issue_sender(
        %{
          device_id: device_id,
          expiration: s.clock.() + s.certificate_lifetime_ms,
          identity_key: account.identity_key,
          aci: aci_uuid(aci),
          signer: {:embedded, s.server_certificate}
        },
        s.server.private
      )

    {json(200, %{"certificate" => Base.encode64(certificate)}), s}
  end

  defp handle(s, _as, _method, _uri, _opts), do: {%Response{status: 404}, s}

  # CRS-07 §3.1, §3.2, §4.
  defp send_message(s, as, destination, opts) do
    body = Keyword.fetch!(opts, :json)
    account = s.accounts[destination]

    cond do
      as == :unidentified and not access_ok?(account, opts) ->
        {%Response{status: 401}, s}

      account == nil ->
        {%Response{status: 404}, s}

      true ->
        messages = body["messages"]
        listed = Enum.map(messages, & &1["destinationDeviceId"])
        current = Map.keys(account.devices)

        stale =
          for m <- messages,
              device = account.devices[m["destinationDeviceId"]],
              device != nil and device.registration_id != m["destinationRegistrationId"],
              do: m["destinationDeviceId"]

        missing = current -- listed
        extra = listed -- current
        payloads = Enum.map(messages, &Base.decode64!(&1["content"]))

        cond do
          messages == [] or length(Enum.uniq(listed)) != length(listed) ->
            {%Response{status: 422}, s}

          Enum.any?(messages, &(&1["type"] not in [1, 3, 6, 8])) ->
            {%Response{status: 422}, s}

          stale != [] ->
            {json(410, %{"staleDevices" => stale}), s}

          missing != [] or extra != [] ->
            {json(409, %{"missingDevices" => missing, "extraDevices" => extra}), s}

          Enum.any?(payloads, &(byte_size(&1) > @max_payload)) ->
            {%Response{status: 413}, s}

          true ->
            s =
              Enum.zip(messages, payloads)
              |> Enum.reduce(s, fn {m, payload}, s ->
                queue(
                  s,
                  destination,
                  m["destinationDeviceId"],
                  envelope(s, as, destination, m["type"], payload, body)
                )
              end)

            {json(200, %{"needsSync" => false}), s}
        end
    end
  end

  # CRS-06 §10.2, CRS-07 §3.3.
  defp send_multi(s, query, opts) do
    headers = Keyword.get(opts, :headers, [])

    with {_, value} <- List.keyfind(headers, "group-send-token", 0),
         {:ok, token} <- Base.decode64(value),
         {:ok, upload} <- SealedSender.parse_upload(Keyword.fetch!(opts, :body)),
         deliveries = SealedSender.deliveries(upload),
         true <- deliveries != [] || :empty,
         true <- s.group_send_verifier.(token, Enum.map(deliveries, & &1.service_id)) || :token do
      multi_deliver(s, deliveries, query)
    else
      :empty -> {%Response{status: 400}, s}
      {:error, _} -> {%Response{status: 400}, s}
      _ -> {%Response{status: 401}, s}
    end
  end

  defp multi_deliver(s, deliveries, query) do
    checks =
      for delivery <- deliveries,
          account = s.accounts[ServiceId.to_string(delivery.service_id)],
          account != nil do
        listed = Enum.map(delivery.devices, &elem(&1, 0))
        current = Map.keys(account.devices)

        stale =
          for {device, registration_id} <- delivery.devices,
              d = account.devices[device],
              d != nil and d.registration_id != registration_id,
              do: device

        %{
          uuid: ServiceId.to_string(delivery.service_id),
          missing: current -- listed,
          extra: listed -- current,
          stale: stale
        }
      end

    mismatched = Enum.filter(checks, &(&1.missing != [] or &1.extra != []))
    stale = Enum.filter(checks, &(&1.stale != []))

    cond do
      mismatched != [] ->
        {json(
           409,
           for c <- mismatched do
             %{
               "uuid" => c.uuid,
               "devices" => %{"missingDevices" => c.missing, "extraDevices" => c.extra}
             }
           end
         ), s}

      stale != [] ->
        {json(
           410,
           for(c <- stale, do: %{"uuid" => c.uuid, "devices" => %{"staleDevices" => c.stale}})
         ), s}

      true ->
        body = %{
          "timestamp" => String.to_integer(query["ts"]),
          "urgent" => query["urgent"] != "false"
        }

        {unregistered, s} =
          Enum.reduce(deliveries, {[], s}, fn delivery, {unregistered, s} ->
            destination = ServiceId.to_string(delivery.service_id)

            case s.accounts[destination] do
              nil ->
                {unregistered ++ [destination], s}

              _account ->
                s =
                  Enum.reduce(delivery.devices, s, fn {device, _registration_id}, s ->
                    queue(
                      s,
                      destination,
                      device,
                      envelope(s, :unidentified, destination, 6, delivery.delivery, body)
                    )
                  end)

                {unregistered, s}
            end
          end)

        {json(200, %{"uuids404" => unregistered}), s}
    end
  end

  defp envelope(s, as, destination, type, payload, body) do
    {source, source_device} =
      case {type, as} do
        {6, _} -> {nil, nil}
        {_, {:identified, aci, device}} -> {{:aci, aci_uuid(aci)}, device}
        {_, :unidentified} -> {nil, nil}
      end

    %Envelope{
      kind: type,
      client_timestamp: if(body["timestamp"] == 0, do: s.clock.(), else: body["timestamp"]),
      source: source,
      source_device: source_device,
      payload: payload,
      server_timestamp: s.clock.(),
      urgent: body["urgent"] != false,
      destination: elem(ServiceId.parse(destination), 1)
    }
  end

  # CRS-06 §4.2: any 16-byte key for unrestricted access, else the
  # registered key; a missing account is 401.
  defp access_ok?(nil, _opts), do: false

  defp access_ok?(account, opts) do
    with {_, value} <- List.keyfind(Keyword.get(opts, :headers, []), "unidentified-access-key", 0),
         {:ok, <<_::binary-size(16)>> = key} <- Base.decode64(value) do
      account.unrestricted or key == account.access_key
    else
      _ -> false
    end
  end

  # CRS-03 §9.5.
  defp keys(s, as, destination, device, opts) do
    account = s.accounts[destination]

    cond do
      as == :unidentified and not access_ok?(account, opts) ->
        {%Response{status: 401}, s}

      account == nil ->
        {%Response{status: 404}, s}

      true ->
        ids = if device == "*", do: Map.keys(account.devices), else: [String.to_integer(device)]
        ids = Enum.filter(ids, &Map.has_key?(account.devices, &1))

        if ids == [] do
          {%Response{status: 404}, s}
        else
          {devices, s} =
            Enum.map_reduce(ids, s, fn id, s ->
              d = account.devices[id]
              {one_time, rest} = pop(d.one_time)
              {kem, kem_rest} = pop(d.kem)
              s = put_in(s, [:accounts, destination, :devices, id, :one_time], rest)
              s = put_in(s, [:accounts, destination, :devices, id, :kem], kem_rest)

              entry =
                %{
                  "deviceId" => id,
                  "registrationId" => d.registration_id,
                  "signedPreKey" => d.signed,
                  "pqPreKey" => kem || d.last_resort
                }
                |> then(fn e -> if one_time, do: Map.put(e, "preKey", one_time), else: e end)

              {entry, s}
            end)

          {json(200, %{"identityKey" => Base.encode64(account.identity_key), "devices" => devices}),
           s}
        end
    end
  end

  defp pop([]), do: {nil, []}
  defp pop([first | rest]), do: {first, rest}

  defp queue(s, aci, device_id, envelope) do
    envelope = %{envelope | server_guid: :crypto.strong_rand_bytes(16)}
    update_in(s, [:accounts, aci, :devices, device_id, :queue], &(&1 ++ [envelope]))
  end

  defp queue_all(s, aci, envelope) do
    case s.accounts[aci] do
      nil ->
        s

      account ->
        Enum.reduce(
          Map.keys(account.devices),
          s,
          &queue(&2, aci, &1, %{envelope | destination: {:aci, aci_uuid(aci)}})
        )
    end
  end

  defp json(status, term), do: %Response{status: status, body: Jason.encode!(term)}

  defp aci_uuid(aci) do
    {:ok, uuid} = ServiceId.aci_from_string(aci)
    uuid
  end
end
