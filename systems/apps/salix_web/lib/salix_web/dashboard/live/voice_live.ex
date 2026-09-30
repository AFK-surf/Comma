defmodule SalixWeb.Dashboard.VoiceLive do
  @moduledoc """
  Operator page for the platform voice settings (`SalixVoice.Settings`,
  docs/messaging-voice.md): GPT-Live, Twilio lines and call limits. Secrets
  are write-only: the page shows configured flags, and a blank secret field
  keeps the stored value.
  """
  use SalixWeb.Dashboard, :live_view

  alias SalixVoice.Settings

  @integer_fields ~w(max_call_seconds max_calls_per_node pin_max_failures pin_lockout_seconds)
  @string_fields ~w(gpt_live_model gpt_live_url gpt_live_voice twilio_account_sid
    twilio_verify_service_sid public_base_url)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(active_nav: :voice, page_title: "Voice", breadcrumbs: [{"Voice", nil}])
     |> load()}
  end

  defp load(socket) do
    case Settings.get() do
      {:ok, effective} ->
        settings = Settings.redact(effective)

        assign(socket,
          settings: settings,
          load_error: nil,
          readiness: Salix.Control.VoiceNumbers.readiness(effective),
          webhook_url:
            SalixWeb.TwilioWebhook.public_base_url(settings) <> "/v1/voice/twilio/incoming",
          status_url:
            SalixWeb.TwilioWebhook.public_base_url(settings) <> "/v1/voice/twilio/status"
        )

      {:error, reason} ->
        assign(socket,
          settings: Settings.redact(Settings.defaults()),
          load_error: inspect(reason),
          readiness: %{"ready" => false, "reason" => "unavailable"},
          webhook_url: nil,
          status_url: nil
        )
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    with {:ok, attrs} <- attrs(params),
         {:ok, _settings} <- Settings.update(attrs) do
      {:noreply, socket |> put_flash(:info, "Voice settings saved.") |> load()}
    else
      {:error, {:bad_request, message}} -> {:noreply, put_flash(socket, :error, message)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  defp attrs(params) do
    base = %{
      "enabled" => params["enabled"] == "true",
      "openai_api_key" => params["openai_api_key"],
      "twilio_auth_token" => params["twilio_auth_token"],
      "twilio_numbers" =>
        (params["twilio_numbers"] || "")
        |> String.split([",", "\n", " "], trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    }

    base = Enum.reduce(@string_fields, base, &Map.put(&2, &1, params[&1]))

    Enum.reduce_while(@integer_fields, {:ok, base}, fn field, {:ok, acc} ->
      case String.trim(params[field] || "") do
        "" ->
          {:cont, {:ok, acc}}

        text ->
          case Integer.parse(text) do
            {value, ""} -> {:cont, {:ok, Map.put(acc, field, value)}}
            _ -> {:halt, {:error, {:bad_request, "#{field} must be an integer"}}}
          end
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-6">
      <div>
        <h1 class="text-xl font-semibold">Voice</h1>
        <p class="mt-1 text-sm text-neutral-500">
          Platform settings for voice calls: GPT-Live, the Twilio lines callers dial, and call limits.
          Secrets are write-only and never shown back.
        </p>
      </div>

      <p :if={@load_error} class="text-xs text-red-700">Settings are unavailable: {@load_error}</p>

      <.card>
        <:title>Status</:title>
        <:actions>
          <.badge color={if @readiness["ready"], do: "green", else: "neutral"}>
            {if @readiness["ready"], do: "ready", else: "not ready: #{@readiness["reason"]}"}
          </.badge>
        </:actions>
        <div :if={@webhook_url} class="space-y-1 text-xs text-neutral-600">
          <p>Twilio voice webhook (POST): <code id="voice-webhook-url">{@webhook_url}</code></p>
          <p>Twilio status callback (POST): <code>{@status_url}</code></p>
        </div>
      </.card>

      <form id="voice-settings" phx-submit="save" class="space-y-6">
        <.card>
          <:title>Calls</:title>
          <div class="space-y-3">
            <label class="flex items-center gap-2 text-sm">
              <input type="hidden" name="enabled" value="false" />
              <input
                type="checkbox"
                name="enabled"
                value="true"
                checked={@settings["enabled"] == true}
                class="h-4 w-4 rounded border-neutral-300"
              /> Enabled
            </label>
            <.input name="max_call_seconds" label="Maximum call length (seconds)" value={@settings["max_call_seconds"]} />
            <.input name="max_calls_per_node" label="Maximum calls per node" value={@settings["max_calls_per_node"]} />
            <.input name="public_base_url" label="Public base URL (optional override)" value={@settings["public_base_url"]} />
          </div>
        </.card>

        <.card>
          <:title>GPT-Live</:title>
          <:actions>
            <.badge color={if @settings["openai_api_key_configured"], do: "green", else: "neutral"}>
              {if @settings["openai_api_key_configured"], do: "key configured", else: "no key"}
            </.badge>
          </:actions>
          <div class="space-y-3">
            <.input
              type="password"
              name="openai_api_key"
              label="OpenAI API key"
              placeholder={if @settings["openai_api_key_configured"], do: "•••••• (leave blank to keep)", else: ""}
            />
            <.input name="gpt_live_model" label="Model" value={@settings["gpt_live_model"]} />
            <.input name="gpt_live_url" label="WebSocket URL" value={@settings["gpt_live_url"]} />
            <.input name="gpt_live_voice" label="Voice (optional)" value={@settings["gpt_live_voice"]} />
          </div>
        </.card>

        <.card>
          <:title>Twilio</:title>
          <:actions>
            <.badge color={if @settings["twilio_auth_token_configured"], do: "green", else: "neutral"}>
              {if @settings["twilio_auth_token_configured"], do: "token configured", else: "no token"}
            </.badge>
          </:actions>
          <div class="space-y-3">
            <.input name="twilio_account_sid" label="Account SID" value={@settings["twilio_account_sid"]} />
            <.input
              type="password"
              name="twilio_auth_token"
              label="Auth token"
              placeholder={if @settings["twilio_auth_token_configured"], do: "•••••• (leave blank to keep)", else: ""}
            />
            <.input
              name="twilio_verify_service_sid"
              label="Verify service SID"
              value={@settings["twilio_verify_service_sid"]}
            />
            <.input
              name="twilio_numbers"
              label="Platform lines (E.164, comma separated)"
              value={Enum.join(@settings["twilio_numbers"] || [], ", ")}
            />
            <.input name="pin_max_failures" label="PIN failures before lockout" value={@settings["pin_max_failures"]} />
            <.input name="pin_lockout_seconds" label="PIN lockout (seconds)" value={@settings["pin_lockout_seconds"]} />
          </div>
        </.card>

        <div class="flex justify-end">
          <.button type="submit" variant="primary" size="sm">Save</.button>
        </div>
      </form>
    </div>
    """
  end
end
