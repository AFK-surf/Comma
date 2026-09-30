defmodule SalixWeb.Dashboard.VoiceLiveTest do
  @moduledoc """
  The Voice settings page and the group Voice tab (docs/messaging-voice.md):
  settings round-trip with write-only secrets, voice keys are shown once and
  managed, and verified caller numbers take a PIN and can be removed.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixIM.ProviderConnects

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    SalixStore.S3.Fake.reset()
    SalixStore.Repo.query!("DELETE FROM agent_group_api_keys")
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Voice Dash"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "VoiceGroup"}, tenant["tenant_id"])
    {:ok, tenant_id: tenant["tenant_id"], group_id: group["group_id"]}
  end

  defp authed_conn(tenant_id),
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id})

  test "the settings page saves and never shows secrets back", ctx do
    {:ok, view, html} = live(authed_conn(ctx.tenant_id), "/dash/voice")
    assert html =~ "not ready: disabled"
    assert html =~ "no key"

    html =
      view
      |> form("#voice-settings", %{
        "enabled" => "true",
        "openai_api_key" => "sk-dash-secret",
        "twilio_account_sid" => "AC1",
        "twilio_auth_token" => "tw-dash-secret",
        "twilio_numbers" => "+15550001111, +15550002222",
        "public_base_url" => "https://voice.example.test",
        "max_call_seconds" => "900"
      })
      |> render_submit()

    assert html =~ "Voice settings saved."
    assert html =~ "key configured"
    assert html =~ "https://voice.example.test/v1/voice/twilio/incoming"
    refute html =~ "sk-dash-secret"
    refute html =~ "tw-dash-secret"

    assert {:ok, settings} = SalixVoice.Settings.get()
    assert settings["enabled"] == true
    assert settings["twilio_auth_token"] == "tw-dash-secret"
    assert settings["twilio_numbers"] == ["+15550001111", "+15550002222"]
    assert settings["max_call_seconds"] == 900

    html = view |> form("#voice-settings", %{"max_call_seconds" => "5"}) |> render_submit()
    assert html =~ "max_call_seconds must be an integer from"
  end

  test "the group Voice tab manages voice keys and caller numbers", ctx do
    {:ok, _} =
      SalixVoice.Settings.update(%{
        "twilio_numbers" => ["+15550001111"],
        "public_base_url" => "https://voice.example.test"
      })

    {:ok, _} =
      ProviderConnects.confirm_voice_number(
        ctx.tenant_id,
        ctx.group_id,
        "twilio",
        "+15550001111",
        "+15551234567"
      )

    {:ok, view, html} = live(authed_conn(ctx.tenant_id), "/dash/groups/#{ctx.group_id}?tab=voice")
    assert html =~ "+15551234567"
    assert html =~ "No voice API keys"

    html = view |> form("#voice-key-form", %{"name" => "Kiosk"}) |> render_submit()
    assert html =~ "shown only once"
    assert html =~ "salix_vk_"
    assert html =~ "wss://voice.example.test/v1/agent-groups/#{ctx.group_id}/voice/sessions"

    assert {:ok, [%{"key_id" => key_id, "created_by" => "salix_admin"}]} =
             Salix.Control.GroupApiKeys.list(ctx.group_id, ctx.tenant_id, "voice")

    # Voice keys are not inbound keys.
    assert {:ok, []} = Salix.Control.GroupApiKeys.list(ctx.group_id, ctx.tenant_id)

    html = render_click(element(view, "button[phx-click=dismiss-voice-key]"))
    refute html =~ "shown only once"

    html = render_click(view, "update-voice-key", %{"key_id" => key_id, "status" => "disabled"})
    assert html =~ "Voice API key updated."

    html = render_click(view, "voice-set-pin", %{"e164" => "+15551234567", "pin" => "2468"})
    assert html =~ "PIN saved."
    assert {:ok, connect} = ProviderConnects.get_voice_im_connect(ctx.tenant_id, ctx.group_id)
    assert [%{"pin_configured" => true}] = connect["numbers"]

    html = render_click(view, "voice-remove-number", %{"e164" => "+15551234567"})
    assert html =~ "Caller number removed."
    assert html =~ "No verified caller numbers"

    html = render_click(view, "delete-voice-key", %{"key_id" => key_id})
    assert html =~ "Voice API key deleted."
    assert html =~ "No voice API keys"
  end
end
