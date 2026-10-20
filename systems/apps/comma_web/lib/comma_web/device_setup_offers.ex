defmodule CommaWeb.DeviceSetupOffers do
  @moduledoc """
  Offers to set up a Comma device that a member's phone found nearby.

  The Android app reports unprovisioned Comma devices from a short BLE scan
  (`report/4`). Each new device gets one offer row and one Router Message in
  Home: fixed text from a template plus a `device_setup_offer` content block
  that clients render as a card with a Connect button. No model runs. The
  Router also receives the offer as context that does not wake it, so a text
  reply such as "yes" gets the answer that setup happens on the phone.

  The row owns the offer's status: `open`, then `started`, `dismissed`,
  `done` or `expired`. Each change takes the next `revision` and queues a
  hidden `device_setup_offer.updated` app event to Home with the whole card.
  Clients show the card with the highest revision, so a late or retried event
  cannot bring back an older status.

  Offers in `open`, `started` or `dismissed` suppress another offer for the same
  Workspace and short id for 30 minutes. `done` and `expired` offers do not.
  A device of the Workspace that is online and has that short
  id, by name or by the device id the app gave when setup started, gets no
  offer and closes an open one as `done` when it connects
  (`device_connected/1`). Device records hold no MAC address, so the name is
  the match. An offer that becomes `done` gets one more Router Message in
  Home, from a template, saying the device is connected.
  """

  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 8,
    unique: [period: :infinity, fields: [:worker, :args]]

  import Ecto.Query

  require Logger

  alias Comma.Data.DeviceSetupOffer
  alias Comma.Repo
  alias SalixIM.{ConversationServer, RouterConversationInput}

  @offer_window_s 30 * 60
  @max_devices 8
  @device_page 100
  @models ~w(t-circle-s3)
  @active ~w(open started)

  # ── reports ──────────────────────────────────────────────────────────────

  @doc """
  Records a phone's report of nearby devices. Returns one outcome per device:
  `offered` (a new offer; its Message follows), `duplicate` (offered in the
  last 30 minutes and still `open`, `started` or `dismissed`),
  `already_connected` or `ignored`.
  """
  def report(user, session, workspace_id, body) do
    with {:ok, workspace} <- authorize(user, session, workspace_id),
         {:ok, report} <- validate_report(body) do
      online = online_devices(workspace)

      outcomes =
        Enum.map(report.devices, fn device ->
          outcome(workspace, user, report, device, online)
        end)

      {:ok, %{"devices" => outcomes}}
    end
  end

  defp outcome(_workspace, _user, _report, %{"state" => state} = device, _online)
       when state != "unprovisioned",
       do: %{"short_id" => device["short_id"], "outcome" => "ignored"}

  defp outcome(workspace, user, report, device, online) do
    if Enum.any?(online, &matches?(&1, device["short_id"], device["name"], nil)) do
      %{"short_id" => device["short_id"], "outcome" => "already_connected"}
    else
      case offer(workspace, user, report, device) do
        {:offered, offer} ->
          %{"short_id" => offer.short_id, "outcome" => "offered", "offer_id" => offer.id}

        {:duplicate, offer} ->
          %{"short_id" => offer.short_id, "outcome" => "duplicate", "offer_id" => offer.id}
      end
    end
  end

  # Two phones, or one reopened app, may report the same device at once. The
  # lock serializes them per Workspace and short id.
  defp offer(workspace, user, report, device) do
    now = now()

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "device_setup_offer:" <> workspace["id"] <> ":" <> device["short_id"]
        ])

        since = DateTime.add(now, -@offer_window_s, :second)

        recent =
          Repo.one(
            from(o in DeviceSetupOffer,
              where:
                o.workspace_id == ^workspace["id"] and o.short_id == ^device["short_id"] and
                  o.inserted_at > ^since and o.status in ~w(open started dismissed),
              order_by: [desc: o.inserted_at],
              limit: 1
            )
          )

        case recent do
          %DeviceSetupOffer{} = offer ->
            {:duplicate, offer}

          nil ->
            offer =
              Repo.insert!(%DeviceSetupOffer{
                id:
                  "dso_" <>
                    Base.url_encode64(SystemsRuntime.Proc.random_bytes(12), padding: false),
                workspace_id: workspace["id"],
                salix_group_id: workspace["default_group_id"],
                short_id: device["short_id"],
                name: device["name"],
                model: device["model"],
                reporter_device_id: report.reporter_device_id,
                reporter_user_id: user["id"],
                request_id: report.request_id,
                status: "open",
                expires_at: DateTime.add(now, @offer_window_s, :second)
              })

            {:ok, _} = enqueue(%{"op" => "post", "offer_id" => offer.id})
            {:ok, _} = enqueue_expiry(offer)
            {:offered, offer}
        end
      end)

    result
  end

  defp validate_report(%{"request_id" => request, "reporter_device_id" => reporter} = body)
       when is_binary(request) and is_binary(reporter) do
    devices = body["devices"]

    with true <- text?(request, 128) and text?(reporter, 128),
         true <- is_list(devices) and length(devices) in 1..@max_devices,
         {:ok, devices} <- validate_devices(devices) do
      {:ok, %{request_id: request, reporter_device_id: reporter, devices: devices}}
    else
      {:error, _} = error -> error
      _ -> {:error, {:bad_request, "invalid nearby device report"}}
    end
  end

  defp validate_report(_body), do: {:error, {:bad_request, "invalid nearby device report"}}

  defp validate_devices(devices) do
    Enum.reduce_while(devices, {:ok, []}, fn device, {:ok, acc} ->
      case validate_device(device) do
        {:ok, device} -> {:cont, {:ok, [device | acc]}}
        :error -> {:halt, {:error, {:bad_request, "invalid nearby device"}}}
      end
    end)
    |> case do
      # One report names each device once.
      {:ok, devices} -> {:ok, devices |> Enum.reverse() |> Enum.uniq_by(& &1["short_id"])}
      error -> error
    end
  end

  defp validate_device(%{"name" => name, "model" => model, "state" => state, "short_id" => id})
       when is_binary(name) and is_binary(model) and is_binary(state) and is_binary(id) do
    short_id = String.upcase(id)

    if text?(name, 64) and model in @models and text?(state, 32) and
         String.match?(short_id, ~r/\A[0-9A-F]{4}\z/) do
      {:ok, %{"name" => name, "model" => model, "state" => state, "short_id" => short_id}}
    else
      :error
    end
  end

  defp validate_device(_device), do: :error

  defp text?(value, max),
    do: is_binary(value) and value != "" and String.length(value) <= max and String.valid?(value)

  # One bounded page of the Workspace's devices. A Workspace with more devices
  # than that may get an offer for a device it already has.
  defp online_devices(workspace) do
    case SalixEnv.Control.page_group_environments(
           workspace["default_group_id"],
           workspace["salix_tenant_id"],
           limit: @device_page
         ) do
      {:ok, %{records: records}} -> Enum.filter(records, &(&1["status"] == "connected"))
      _ -> []
    end
  end

  # ── offers ───────────────────────────────────────────────────────────────

  @doc "The current card of an offer."
  def get(user, session, workspace_id, offer_id) do
    with {:ok, workspace} <- authorize(user, session, workspace_id),
         {:ok, offer} <- fetch(workspace, offer_id) do
      {:ok, %{"offer" => card(offer)}}
    end
  end

  @doc """
  The member dismissed the offer, or started setup from it. `started` may name
  the device id that its connector token got, so its first connection closes
  the offer, and gives the setup another 30 minutes.
  """
  def resolve(user, session, workspace_id, offer_id, %{"action" => action} = attrs)
      when action in ["dismiss", "started"] do
    device_id = attrs["device_id"]

    with {:ok, workspace} <- authorize(user, session, workspace_id),
         true <- is_nil(device_id) or text?(device_id, 128),
         {:ok, offer} <- fetch(workspace, offer_id) do
      changes =
        case action do
          "dismiss" ->
            %{status: "dismissed"}

          "started" ->
            %{
              status: "started",
              device_id: device_id || offer.device_id,
              expires_at: DateTime.add(now(), @offer_window_s, :second)
            }
        end

      with {:ok, offer} <- transition(offer.id, @active, changes) do
        if offer.status == "started",
          do: {:ok, _} = enqueue_expiry(offer)

        {:ok, %{"offer" => card(offer)}}
      end
    else
      false -> {:error, {:bad_request, "invalid device_id"}}
      error -> error
    end
  end

  def resolve(_user, _session, _workspace_id, _offer_id, _attrs),
    do: {:error, {:bad_request, "action must be dismiss or started"}}

  defp fetch(workspace, offer_id) when is_binary(offer_id) do
    workspace_id = workspace["id"]

    case Repo.get(DeviceSetupOffer, offer_id) do
      %DeviceSetupOffer{workspace_id: ^workspace_id} = offer -> {:ok, offer}
      _ -> {:error, :not_found}
    end
  end

  # Moves an offer out of one of `from` and publishes the new card. An offer
  # in another status answers :conflict.
  defp transition(offer_id, from, changes) do
    result =
      Repo.transaction(fn ->
        offer =
          Repo.one(from(o in DeviceSetupOffer, where: o.id == ^offer_id, lock: "FOR UPDATE"))

        cond do
          is_nil(offer) ->
            Repo.rollback(:not_found)

          offer.status not in from ->
            Repo.rollback({:conflict, "offer is " <> offer.status})

          true ->
            changes = Map.merge(changes, %{revision: offer.revision + 1, updated_at: now()})

            offer
            |> Ecto.Changeset.change(changes)
            |> Repo.update!()
            |> tap(fn updated ->
              {:ok, _} =
                enqueue(%{"op" => "publish", "offer_id" => updated.id, "card" => card(updated)})

              # Only one transition reaches done, so each offer announces once.
              if updated.status == "done",
                do: {:ok, _} = enqueue(%{"op" => "connected", "offer_id" => updated.id})
            end)
        end
      end)

    result
  end

  @doc """
  The Salix device-connect observer. Closes the open or started offers of the
  device's Group that this device answers, including other active offers for
  the same Workspace and short id.
  """
  def device_connected(%{"group_id" => group} = device) when is_binary(group) do
    from(o in DeviceSetupOffer,
      where: o.salix_group_id == ^group and o.status in ^@active,
      limit: 16
    )
    |> Repo.all()
    |> Enum.filter(&matches?(device, &1.short_id, &1.name, &1.device_id))
    |> Enum.uniq_by(&{&1.workspace_id, &1.short_id})
    |> Enum.each(&complete_device_offers(&1.workspace_id, &1.short_id))
  rescue
    error ->
      Logger.warning("device_setup_offer_connect_failed #{inspect(error.__struct__)}")
      :ok
  end

  def device_connected(_device), do: :ok

  # Complete older cards too when only the latest offer knows the connected device id.
  # Each batch is bounded; transitions retain revision events and terminal-state guards.
  defp complete_device_offers(workspace_id, short_id) do
    offers =
      Repo.all(
        from(o in DeviceSetupOffer,
          where:
            o.workspace_id == ^workspace_id and o.short_id == ^short_id and
              o.status in ^@active,
          order_by: [asc: o.id],
          limit: 16
        )
      )

    Enum.each(offers, fn offer -> transition(offer.id, @active, %{status: "done"}) end)
    if offers != [], do: complete_device_offers(workspace_id, short_id)
  end

  @doc false
  def matches?(device, short_id, name, device_id) do
    names =
      [device["name"], device["alias"], device["display_name"]] ++
        [get_in(device, ["system_info", "hostname"])]

    (is_binary(device_id) and device["device_id"] == device_id) or
      Enum.any?(names, fn value ->
        is_binary(value) and
          (String.upcase(value) == String.upcase(name) or
             String.ends_with?(String.upcase(value), "-" <> short_id))
      end)
  end

  # ── Home ─────────────────────────────────────────────────────────────────

  @doc "The card that clients render, also inside each update event."
  def card(%DeviceSetupOffer{} = offer) do
    %{
      "type" => "device_setup_offer",
      "offer_id" => offer.id,
      "name" => offer.name,
      "model" => offer.model,
      "short_id" => offer.short_id,
      "reporter_device_id" => offer.reporter_device_id,
      "status" => offer.status,
      "revision" => offer.revision,
      "expires_at" => DateTime.to_unix(offer.expires_at, :millisecond)
    }
  end

  # Starting setup moves the deadline, and the new deadline gets its own job.
  defp enqueue_expiry(offer) do
    at = DateTime.to_unix(offer.expires_at, :millisecond)
    enqueue(%{"op" => "expire", "offer_id" => offer.id, "at" => at}, offer.expires_at)
  end

  defp enqueue(args, at \\ nil) do
    args
    |> new(if(at, do: [scheduled_at: at], else: []))
    |> then(&Oban.insert(Comma.Oban, &1))
  end

  @impl Oban.Worker
  def timeout(_job), do: 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => op, "offer_id" => id} = args}) do
    case Repo.get(DeviceSetupOffer, id) do
      nil -> :ok
      offer -> run(op, offer, args)
    end
  end

  defp run("post", offer, _args) do
    with {:ok, workspace} <- Comma.Workspaces.get(offer.workspace_id),
         {:ok, home} <- RouterConversationInput.ensure(offer.salix_group_id),
         locale =
           Comma.Accounts.agent_context(workspace["owner_user_id"], workspace["id"])["locale"],
         {:ok, message} <-
           ConversationServer.append_group_conversation_agent_message(
             offer.salix_group_id,
             home["conversation_id"],
             home["router_agent_id"],
             %{
               "content" => [%{"type" => "text", "text" => text(locale)}, card(offer)],
               "client_request_id" => "device-setup-offer:" <> offer.id,
               "metadata" => %{"message_type" => "device_setup_offer", "offer_id" => offer.id}
             }
           ),
         {:ok, _} <-
           RouterConversationInput.append_provider_input(
             offer.salix_group_id,
             "device-setup-offer:" <> offer.id,
             %{content: router_context(offer), name: "Comma", role: "user", no_wake: true},
             %{"provider" => "comma", "event_type" => "device_setup_offer"}
           ) do
      offer
      |> Ecto.Changeset.change(message_id: message["message_id"])
      |> Repo.update!()

      :ok
    end
  end

  defp run("connected", offer, _args) do
    with {:ok, workspace} <- Comma.Workspaces.get(offer.workspace_id),
         {:ok, home} <- RouterConversationInput.ensure(offer.salix_group_id),
         locale =
           Comma.Accounts.agent_context(workspace["owner_user_id"], workspace["id"])["locale"],
         {:ok, _message} <-
           ConversationServer.append_group_conversation_agent_message(
             offer.salix_group_id,
             home["conversation_id"],
             home["router_agent_id"],
             %{
               "content" => [%{"type" => "text", "text" => connected_text(offer, locale)}],
               "client_request_id" => "device-setup-offer-connected:" <> offer.id,
               "metadata" => %{
                 "message_type" => "device_setup_connected",
                 "offer_id" => offer.id
               }
             }
           ) do
      :ok
    end
  end

  defp run("expire", %DeviceSetupOffer{status: status} = offer, _args) when status in @active do
    if DateTime.compare(now(), offer.expires_at) == :lt do
      # Setup started later and moved the deadline; that job expires it.
      :ok
    else
      case transition(offer.id, @active, %{status: "expired"}) do
        {:ok, _} -> :ok
        {:error, {:conflict, _}} -> :ok
        error -> error
      end
    end
  end

  defp run("expire", _offer, _args), do: :ok

  # A job publishes the card of its revision. A newer revision has its own
  # job, so an older one that has not appended yet stops here; one that
  # appends late still loses, because clients show the highest revision.
  defp run("publish", offer, %{"card" => %{"revision" => revision} = card}) do
    if offer.revision > revision do
      :ok
    else
      with {:ok, home} <- RouterConversationInput.ensure(offer.salix_group_id),
           {:ok, _} <-
             ConversationServer.append_product_event(
               offer.salix_group_id,
               home["conversation_id"],
               "device_setup_offer.updated",
               %{"offer" => card},
               "device-setup-offer:" <> offer.id <> ":" <> Integer.to_string(revision)
             ) do
        :ok
      end
    end
  end

  # The card under the text names the device.
  defp text("zh-CN"), do: "附近发现一台新的 Comma，要现在设置吗？"
  defp text(_locale), do: "Found a new Comma nearby. Want to set it up?"

  defp connected_text(offer, "zh-CN"),
    do: "#{offer.name} 已连接。点一下它就能打电话。要让我通过它控制家里的设备，请在 设置 › 设备 里把它的「访问权限」设为「完全」。"

  defp connected_text(offer, _locale),
    do:
      "#{offer.name} is connected. Tap it to start a call. To let me control devices on your " <>
        "network through it, set its Access to Full in Settings › Devices."

  defp router_context(offer) do
    "Comma posted this in Home for the user: a phone found an unprovisioned Comma device nearby " <>
      "(#{offer.name}, model #{offer.model}) and offered to set it up. Setup happens only in the Comma " <>
      "app on that phone: the user taps Connect on the offer card, or opens Settings > Devices > Add device. " <>
      "You have no Bluetooth tool and cannot set up the device yourself. If the user agrees or asks you " <>
      "to set it up, tell them to tap Connect on the phone near the device. This is context only, not a request."
  end

  # ── access ───────────────────────────────────────────────────────────────

  # The same admission as minting a connector token: a full session of a
  # member who may add devices to the Workspace.
  defp authorize(_user, %{"restricted" => true}, _workspace_id), do: {:error, :forbidden}

  defp authorize(user, session, workspace_id),
    do: Comma.Workspaces.authorize(user, session, workspace_id)

  defp now, do: SystemsClock.utc_now()
end
