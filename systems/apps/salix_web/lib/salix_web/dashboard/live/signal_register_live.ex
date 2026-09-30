defmodule SalixWeb.Dashboard.SignalRegisterLive do
  @moduledoc """
  Operator page that registers a Signal number as a new Comma account
  (docs/messaging-voice.md), linked from `/dash/signal`.

  The operator enters the number, the Signal environment and the owner (the
  platform, or an organization by its Salix tenant ID), then works through
  the verification session one step at a time: solve the captcha on the
  environment's captcha page and paste the `signalcaptcha://` link, request
  a code by SMS or voice call, and enter the code. A verified session
  registers the number at once. Every step shows the session state that the
  service returned, including when the next code request is allowed.

  A registration that failed after its keys were stored leaves the account
  `registering`. A new session for the same number and environment resumes
  that account with its stored keys; a failed registration can also be
  retried from the same verified session. An account that registers is
  `active` and its owner process is started, so it appears on the Signal
  page and can be chosen as the platform or a tenant number.

  The logic is in `Salix.Control.SignalRegistration`. Each service request
  runs in `start_async/3`, off this process, with a bounded response time.
  The page never renders or keeps the code, the captcha or any secret; the
  session ID stays server-side. Test builds may set
  `config :salix_web, :signal_registration` to options of that module
  (`:transport`, `:start`).
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.SignalRegistration, as: Registration

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       active_nav: :signal,
       page_title: "Register Signal number",
       breadcrumbs: [{"Signal", "/dash/signal"}, {"Register a number", nil}],
       options: Application.get_env(:salix_web, :signal_registration, []),
       form: %{
         "number" => "",
         "environment" => "production",
         "scope" => "platform",
         "tenant_id" => ""
       },
       flow: nil,
       busy: nil,
       error: nil
     )}
  end

  # ---- events ----

  @impl true
  def handle_event("reset", _params, socket) do
    socket = if busy = socket.assigns.busy, do: cancel_async(socket, busy), else: socket
    {:noreply, assign(socket, flow: nil, error: nil, busy: nil)}
  end

  def handle_event(_event, _params, %{assigns: %{busy: busy}} = socket) when busy != nil,
    do: {:noreply, socket}

  def handle_event("start", params, socket) do
    form = Map.take(params, ~w(number environment scope tenant_id))
    options = socket.assigns.options

    socket
    |> assign(form: Map.merge(socket.assigns.form, form))
    |> run(:start, fn -> Registration.start(form, options) end)
  end

  def handle_event(_event, _params, %{assigns: %{flow: nil}} = socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket) do
    %{flow: flow, options: options} = socket.assigns
    run(socket, :refresh, fn -> Registration.refresh(flow, options) end)
  end

  def handle_event("captcha", %{"captcha" => captcha}, socket) do
    %{flow: flow, options: options} = socket.assigns
    run(socket, :captcha, fn -> Registration.submit_captcha(flow, captcha, options) end)
  end

  def handle_event("request-code", %{"channel" => channel}, socket)
      when channel in ~w(sms voice) do
    %{flow: flow, options: options} = socket.assigns
    channel = String.to_existing_atom(channel)
    run(socket, :request_code, fn -> Registration.request_code(flow, channel, options) end)
  end

  def handle_event("code", %{"code" => code}, socket) do
    %{flow: flow, options: options} = socket.assigns
    run(socket, :code, fn -> Registration.submit_code(flow, code, options) end)
  end

  def handle_event("register", _params, socket), do: register(socket)

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp register(socket) do
    %{flow: flow, options: options} = socket.assigns
    run(socket, :register, fn -> Registration.register(flow, options) end)
  end

  # Every step runs off the LiveView process. A raise inside a step becomes
  # a generic error, so no exception carries a code or captcha into a log.
  defp run(socket, step, fun) do
    flow = socket.assigns.flow

    task = fn ->
      try do
        fun.()
      rescue
        _error -> {:error, :internal, flow}
      catch
        _kind, _reason -> {:error, :internal, flow}
      end
    end

    {:noreply, socket |> assign(busy: step, error: nil) |> start_async(step, task)}
  end

  @impl true
  def handle_async(:code, {:ok, {:ok, %{session: %{verified: true}} = flow}}, socket) do
    socket |> assign(flow: flow, busy: nil) |> register()
  end

  def handle_async(_step, {:ok, {:ok, flow}}, socket),
    do: {:noreply, assign(socket, flow: flow, busy: nil, error: nil)}

  def handle_async(_step, {:ok, {:error, reason, flow}}, socket) do
    {:noreply,
     assign(socket,
       flow: if(match?(%{session: %{}}, flow), do: flow, else: socket.assigns.flow),
       busy: nil,
       error: Registration.message(reason)
     )}
  end

  def handle_async(_step, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, busy: nil, error: Registration.message(:internal))}

  # ---- view helpers ----

  defp session(%{session: session}), do: session
  defp session(_flow), do: nil

  defp step(nil), do: :start
  defp step(%{account: %{}}), do: :done
  defp step(%{session: nil}), do: :start
  defp step(%{session: %{verified: true}}), do: :register

  defp step(%{session: session} = flow) do
    cond do
      :captcha in session.requested_information -> :captcha
      flow.code_requested? or session.next_verification_attempt != nil -> :code
      true -> :request_code
    end
  end

  defp requested([]), do: "nothing"

  defp requested(items),
    do:
      Enum.map_join(items, ", ", fn
        :captcha -> "captcha"
        :push_challenge -> "push challenge"
      end)

  # Seconds from the response, shown as a wait and a UTC time.
  defp next(nil, _fetched_at), do: "not allowed now"
  defp next(0, _fetched_at), do: "now"

  defp next(seconds, %DateTime{} = fetched_at) do
    at = fetched_at |> DateTime.add(seconds) |> Calendar.strftime("%H:%M:%S UTC")
    "in #{seconds} s, at #{at}"
  end

  defp next(seconds, _fetched_at), do: "in #{seconds} s"

  defp busy_label(:start), do: "Creating the verification session…"
  defp busy_label(:refresh), do: "Reading the session…"
  defp busy_label(:captcha), do: "Sending the captcha…"
  defp busy_label(:request_code), do: "Requesting a code…"
  defp busy_label(:code), do: "Checking the code…"
  defp busy_label(:register), do: "Registering the account…"

  defp owner(:started), do: "started"
  defp owner(_), do: "not started yet; the account keeper starts it within a minute"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, session: session(assigns.flow), step: step(assigns.flow))

    ~H"""
    <div class="max-w-3xl space-y-6">
      <div>
        <h1 class="text-xl font-semibold">Register a Signal number</h1>
        <p class="mt-1 text-sm text-neutral-500">
          Registers a phone number as a new Signal account that Comma owns. Registration signs out any
          other Signal device on the number. Then choose the number as the platform or a tenant number.
        </p>
      </div>

      <p :if={@error} id="signal-register-error" class="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
        {@error}
      </p>
      <p :if={@busy} id="signal-register-busy" class="text-sm text-neutral-500">{busy_label(@busy)}</p>

      <.card :if={@step == :start}>
        <:title>Number</:title>
        <form id="signal-register-start" phx-submit="start" class="space-y-3">
          <.input name="number" label="Phone number (E.164)" value={@form["number"]} placeholder="+15551234567" />
          <.select
            name="environment"
            label="Signal service"
            value={@form["environment"]}
            options={[{"Production", "production"}, {"Staging", "staging"}]}
          />
          <.select
            name="scope"
            label="Owner"
            value={@form["scope"]}
            options={[{"Platform", "platform"}, {"Organization (tenant)", "organization"}]}
          />
          <.input
            name="tenant_id"
            label="Tenant ID (organization owner only)"
            value={@form["tenant_id"]}
          />
          <.button type="submit" variant="primary" disabled={@busy != nil}>Start verification</.button>
        </form>
      </.card>

      <.card :if={@flow && @session}>
        <:title>Verification session</:title>
        <:actions>
          <.button size="sm" phx-click="refresh" disabled={@busy != nil}>Refresh</.button>
          <.button size="sm" variant="ghost" phx-click="reset">Start over</.button>
        </:actions>
        <p :if={@flow.resumed?} id="signal-register-resume" class="mb-3 text-sm text-amber-700">
          A failed registration of this number is stored (account {@flow.account_id}).
          Verifying the number resumes it with its stored keys.
        </p>
        <dl id="signal-register-session" class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
          <dt class="text-neutral-500">Number</dt>
          <dd class="font-mono">{@flow.number}</dd>
          <dt class="text-neutral-500">Service</dt>
          <dd>{@flow.environment}</dd>
          <dt class="text-neutral-500">Owner</dt>
          <dd>{Registration.scope_label(@flow.scope)}</dd>
          <dt class="text-neutral-500">Still required</dt>
          <dd>{requested(@session.requested_information)}</dd>
          <dt class="text-neutral-500">Code request allowed</dt>
          <dd>{if @session.allowed_to_request_code, do: "yes", else: "no"}</dd>
          <dt class="text-neutral-500">Next SMS</dt>
          <dd>{next(@session.next_sms, @flow.fetched_at)}</dd>
          <dt class="text-neutral-500">Next voice call</dt>
          <dd>{next(@session.next_call, @flow.fetched_at)}</dd>
          <dt class="text-neutral-500">Next code entry</dt>
          <dd>{next(@session.next_verification_attempt, @flow.fetched_at)}</dd>
          <dt class="text-neutral-500">Verified</dt>
          <dd>{if @session.verified, do: "yes", else: "no"}</dd>
        </dl>
      </.card>

      <.card :if={@step == :captcha}>
        <:title>1. Solve the captcha</:title>
        <p class="mb-3 text-sm text-neutral-600">
          Open the
          <a id="signal-captcha-page" href={Registration.captcha_page(@flow.environment)} target="_blank" rel="noopener noreferrer" class="text-brand-600 underline">
            registration captcha page
          </a>
          and solve it. When it finishes, copy the link that starts with <code>signalcaptcha://</code>
          (right-click "Open Signal" and copy the link) and paste it here.
        </p>
        <form id="signal-register-captcha" phx-submit="captcha" class="flex items-end gap-2">
          <.input name="captcha" label="Solved captcha link" class="flex-1" autocomplete="off" />
          <.button type="submit" variant="primary" disabled={@busy != nil}>Submit captcha</.button>
        </form>
      </.card>

      <.card :if={@step in [:request_code, :code]}>
        <:title>2. Request a code</:title>
        <div class="flex gap-2">
          <.button
            id="signal-request-sms"
            phx-click="request-code"
            phx-value-channel="sms"
            disabled={@busy != nil or is_nil(@session.next_sms)}
          >
            Send code by SMS ({next(@session.next_sms, @flow.fetched_at)})
          </.button>
          <.button
            id="signal-request-voice"
            phx-click="request-code"
            phx-value-channel="voice"
            disabled={@busy != nil or is_nil(@session.next_call)}
          >
            Send code by voice call ({next(@session.next_call, @flow.fetched_at)})
          </.button>
        </div>
      </.card>

      <.card :if={@step == :code}>
        <:title>3. Enter the code</:title>
        <form id="signal-register-code" phx-submit="code" class="flex items-end gap-2">
          <.input name="code" label="Code" class="w-48" autocomplete="one-time-code" />
          <.button type="submit" variant="primary" disabled={@busy != nil}>Verify and register</.button>
        </form>
      </.card>

      <.card :if={@step == :register}>
        <:title>4. Register</:title>
        <p class="mb-3 text-sm text-neutral-600">The number is verified.</p>
        <.button id="signal-register-submit" variant="primary" phx-click="register" disabled={@busy != nil}>
          {if @flow.account_id, do: "Retry registration", else: "Register"}
        </.button>
      </.card>

      <.card :if={@step == :done}>
        <:title>Registered</:title>
        <dl id="signal-register-result" class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
          <dt class="text-neutral-500">Account ID</dt>
          <dd class="font-mono">{@flow.account.id}</dd>
          <dt class="text-neutral-500">State</dt>
          <dd>{@flow.account.state}</dd>
          <dt class="text-neutral-500">Number</dt>
          <dd class="font-mono">{@flow.number}</dd>
          <dt class="text-neutral-500">Owner process</dt>
          <dd>{owner(@flow.owner)}</dd>
        </dl>
        <p class="mt-3 text-sm text-neutral-600">
          Choose the number on the <.link navigate="/dash/signal" class="text-brand-600 underline">Signal page</.link>
          (platform) or on a tenant page (tenant number).
        </p>
      </.card>
    </div>
    """
  end
end
