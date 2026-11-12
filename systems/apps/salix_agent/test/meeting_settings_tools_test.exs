defmodule SalixAgent.MeetingSettingsToolsTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.Tools.MeetingSettings

  defmodule OAuthStore do
    def agent_oauth_context("router"), do: {:ok, %{tenant: "tenant", group_id: "group"}}
  end

  # The product: records what the tool handed over.
  defmodule Product do
    def get_destination(group_id, origin) do
      owner = SystemsRuntime.get_env(:salix_agent, :meeting_settings_test_owner)
      SystemsRuntime.Proc.send(owner, {:get_destination, group_id, origin})
      {:ok, %{"status" => "choice_needed", "options" => [%{"platform" => "lark"}]}}
    end

    def set_destination(_group_id, %{"provider_context" => %{"user_id" => "UMEMBER"}}, _, _, _),
      do: {:error, :admin_required}

    def set_destination(group_id, origin, platform, connect_id, chat_id) do
      owner = SystemsRuntime.get_env(:salix_agent, :meeting_settings_test_owner)

      SystemsRuntime.Proc.send(
        owner,
        {:set_destination, group_id, origin, platform, connect_id, chat_id}
      )

      {:ok, %{"status" => "confirmed", "current" => %{"platform" => platform}}}
    end
  end

  setup do
    for {key, value} <- [
          oauth_store_mod: OAuthStore,
          meeting_settings_mod: Product,
          meeting_settings_test_owner: SystemsRuntime.Proc.self()
        ] do
      previous = SystemsRuntime.get_env(:salix_agent, key)
      SystemsRuntime.put_env(:salix_agent, key, value)

      on_exit(fn ->
        if previous,
          do: SystemsRuntime.put_env(:salix_agent, key, previous),
          else: SystemsRuntime.delete_env(:salix_agent, key)
      end)
    end

    :ok
  end

  test "the Router reads and sets the destination with the signed origin" do
    origin = %{"provider" => "lark", "provider_context" => %{"sender_open_id" => "ou_admin"}}
    ctx = %{agent_id: "router", trusted_origin: origin}

    assert MeetingSettings.get_destination(%{}, ctx) =~ ~s("status":"choice_needed")
    assert_received {:get_destination, "group", ^origin}

    assert MeetingSettings.set_destination(%{"platform" => "lark"}, ctx) =~
             ~s("status":"confirmed")

    assert_received {:set_destination, "group", ^origin, "lark", nil, nil}
  end

  test "a person who is no admin is pointed to the dashboard" do
    origin = %{"provider" => "slack", "provider_context" => %{"user_id" => "UMEMBER"}}

    assert_raise RuntimeError, ~r/admin_required.*Meetings page/, fn ->
      MeetingSettings.set_destination(%{"platform" => "slack"}, %{
        agent_id: "router",
        trusted_origin: origin
      })
    end
  end

  test "a turn several people wrote in changes nothing" do
    alice = %{"provider" => "slack", "provider_context" => %{"user_id" => "UALICE"}}
    bob = %{"provider" => "lark", "provider_context" => %{"sender_open_id" => "ou_bob"}}

    assert_raise RuntimeError, ~r/requester_ambiguous/, fn ->
      MeetingSettings.set_destination(%{"platform" => "lark"}, %{
        agent_id: "router",
        trusted_origin: alice,
        trusted_origins: [bob, alice]
      })
    end

    refute_received {:set_destination, _, _, _, _, _}
  end
end
