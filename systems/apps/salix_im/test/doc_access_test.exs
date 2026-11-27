defmodule SalixIM.Provider.DocAccessTest do
  @moduledoc """
  The next step a Feishu or Lark refusal of a listing names. A member's own
  bot (the app a scan in Comma made) has no tenant admin in the developer
  console and no tenant OAuth app: its person reconnects the plugin in Comma.
  """
  use ExUnit.Case, async: true

  alias SalixIM.Provider.DocAccess

  @app_scope ": Access denied. One of the following scopes is required: [drive:drive:readonly, drive:drive]."

  test "a listing the app lacks a scope for names who fixes it, for a member's own bot and for a tenant's" do
    for {prefix, product} <- [{"feishu", "Feishu"}, {"lark", "Lark"}] do
      refused = {:error, "#{product} API error 99991672 (HTTP 400)" <> @app_scope}

      assert {:error, own} =
               DocAccess.next_step(refused, prefix <> ".list_drive_files", %{
                 "owner_only" => true
               })

      assert own =~ "reconnect the plugin in Comma (Plugins → #{product} → Connect)"
      assert own =~ "account="
      refute own =~ "tenant admin"
      refute own =~ "oauth.request_authorization"

      assert {:error, tenant} =
               DocAccess.next_step(refused, prefix <> ".list_wiki_spaces", %{})

      assert tenant =~ "Only a tenant admin can fix this"
      assert tenant =~ "oauth.request_authorization"
      refute tenant =~ "Comma"
    end
  end

  test "a member's own sign-in without a scope is renewed by reconnecting, not by oauth" do
    refused =
      {:error,
       "Feishu API error 99991679 (HTTP 400): Unauthorized. required one of these privileges under the user identity: [drive:drive:readonly]."}

    own = %{"owner_only" => true, "user_access_token" => "u-ann"}

    assert {:error, step} = DocAccess.next_step(refused, "feishu.list_drive_files", own)
    assert step =~ "reconnect the plugin in Comma"
    refute step =~ "oauth.request_authorization"
  end
end
