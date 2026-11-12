defmodule SalixWeb.OAuthCustomProviderTest do
  @moduledoc """
  A secret typed into Salix's form and a Workspace's own OAuth provider both end
  as an ordinary connection and Group binding, with the requester as owner, or
  none for a secret a dashboard keeps for the whole group.
  """
  use SystemsClock.Case, async: false

  alias Salix.Control.{OAuthApps, OAuthBindings}
  alias SalixStore.OAuth, as: Connections
  alias SalixStore.OAuth.{Adapters, AuthState}
  alias SalixWeb.{OAuthCustomAdapter, OAuthFlow}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case start_supervised(SalixStore.S3.Fake) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
      SystemsRuntime.delete_env(:salix_web, :oauth_custom_http_fn)
    end)

    {:ok, tenant: "ten1_custom", group: "grp1_custom"}
  end

  defp pending(tenant, group, provider, more \\ %{}) do
    state = "state-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      AuthState.create(
        Map.merge(
          %{
            "state" => state,
            "tenant" => tenant,
            "group_id" => group,
            "provider" => provider,
            "alias" => "ann",
            "owner" => "comma_user|usr_ann",
            "origin" => "web"
          },
          more
        )
      )

    state
  end

  defp connected(group, provider) do
    [binding] = Enum.filter(OAuthBindings.list(group), &(&1["provider"] == provider))
    {:ok, connection} = Connections.get(binding["connection_id"])
    {binding, connection}
  end

  test "a secret's form connects what it posts, once", %{tenant: tenant, group: group} do
    state = pending(tenant, group, "secret")

    assert {:page, 200, form} = OAuthFlow.secret_form(%{"state" => state})
    assert form =~ ~s(type="password")
    assert form =~ state

    assert {:page, 200, done} =
             OAuthFlow.handle_callback("secret", %{"state" => state, "code" => " sk-live-1 "})

    # The page names the saved credential, not a provider called secret.
    assert done =~ "Saved ann"
    refute done =~ "Successfully connected"

    {binding, connection} = connected(group, "secret")
    assert binding["owner"] == "comma_user|usr_ann"
    assert connection["access_token"] == "sk-live-1"
    assert connection["expires_at"] == nil

    # The form is gone once its state is used.
    assert {:page, 400, _expired} = OAuthFlow.secret_form(%{"state" => state})
  end

  test "a dashboard starts a secret for the whole group with no OAuth app", %{
    tenant: tenant,
    group: group
  } do
    back = "https://dashboard.example/orgs/acme/projects/p1/connections"

    assert {:ok, %{"authorization_url" => url, "state" => state}} =
             OAuthFlow.start_authorization(tenant, group, "secret", %{
               "alias" => "expense-api",
               "redirect_after" => back
             })

    assert %URI{path: "/v1/oauth/secret/callback", query: query} = URI.parse(url)
    assert URI.decode_query(query) == %{"state" => state}
    assert {:page, 200, _form} = OAuthFlow.secret_form(%{"state" => state})

    assert {:redirect, ^back} =
             OAuthFlow.handle_callback("secret", %{"state" => state, "code" => "sk-expense"})

    {binding, connection} = connected(group, "secret")
    assert binding["alias"] == "expense-api"
    assert binding["owner"] == nil
    assert connection["access_token"] == "sk-expense"
  end

  test "an empty secret connects nothing", %{tenant: tenant, group: group} do
    state = pending(tenant, group, "secret")

    assert {:page, 400, _} =
             OAuthFlow.handle_callback("secret", %{"state" => state, "code" => " "})

    assert OAuthBindings.list(group) == []
  end

  @fields [
    %{"name" => "app_id", "label" => "App ID", "secret" => false},
    %{"name" => "app_secret", "label" => "App <Secret> & key"},
    %{"name" => "tenant", "secret" => false}
  ]

  defp start_fields(tenant, group, fields \\ @fields) do
    OAuthFlow.start_authorization(tenant, group, "secret", %{
      "alias" => "hly",
      "fields" => fields
    })
  end

  defp post_form(body) do
    Plug.Test.conn(:post, "/v1/oauth/secret/callback", body)
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> SalixWeb.Router.call(SalixWeb.Router.init([]))
  end

  test "a secret with fields asks for each on one form and keeps them in order", %{
    tenant: tenant,
    group: group
  } do
    assert {:ok, %{"state" => state}} = start_fields(tenant, group)

    assert {:page, 200, form} = OAuthFlow.secret_form(%{"state" => state})
    assert form =~ ~s(App ID<input type="text" name="fields[app_id]" required autofocus>)

    assert form =~
             ~s(App &lt;Secret&gt; &amp; key<input type="password" name="fields[app_secret]")

    assert form =~ ~s(tenant<input type="text" name="fields[tenant]" required>)
    refute form =~ ~s(name="value")

    posted =
      post_form(
        URI.encode_query(%{
          "state" => state,
          "fields[app_id]" => " cli_a1 ",
          "fields[app_secret]" => "s3cr3t-value",
          "fields[tenant]" => "1001"
        })
      )

    assert posted.status == 200

    {binding, connection} = connected(group, "secret")
    assert binding["alias"] == "hly"
    assert connection["access_token"] == nil

    assert connection["fields"] == [
             %{"name" => "app_id", "secret" => false, "value" => "cli_a1"},
             %{"name" => "app_secret", "secret" => true, "value" => "s3cr3t-value"},
             %{"name" => "tenant", "secret" => false, "value" => "1001"}
           ]

    # What read APIs return names the fields and holds none of their values.
    assert binding["fields"] == [
             %{"name" => "app_id", "secret" => false},
             %{"name" => "app_secret", "secret" => true},
             %{"name" => "tenant", "secret" => false}
           ]

    refute Jason.encode!(OAuthBindings.list(group)) =~ "s3cr3t-value"

    # Saving the alias again replaces the whole credential.
    {:ok, %{"authorization_url" => _, "state" => again}} =
      OAuthFlow.start_authorization(tenant, group, "secret", %{"alias" => "hly"})

    assert {:page, 200, _} =
             OAuthFlow.handle_callback("secret", %{"state" => again, "code" => "one-value"})

    {binding, connection} = connected(group, "secret")
    assert connection["access_token"] == "one-value"
    refute Map.has_key?(connection, "fields")
    refute Map.has_key?(binding, "fields")
  end

  test "a secret's callback takes exactly its fields, none empty or too long", %{
    tenant: tenant,
    group: group
  } do
    all = %{"app_id" => "a", "app_secret" => "b", "tenant" => "c"}
    long = String.duplicate("x", 64 * 1024 + 1)

    for code <- [
          Map.delete(all, "tenant"),
          Map.put(all, "extra", "d"),
          Map.put(all, "tenant", " "),
          Map.put(all, "app_secret", long),
          "one-value"
        ] do
      {:ok, %{"state" => state}} = start_fields(tenant, group)

      assert {:page, 400, _} =
               OAuthFlow.handle_callback("secret", %{"state" => state, "code" => code})
    end

    assert OAuthBindings.list(group) == []
  end

  test "a request's field names follow the rules", %{tenant: tenant, group: group} do
    many = for i <- 1..9, do: %{"name" => "f#{i}"}

    for fields <- [
          [%{"name" => "1st"}],
          [%{"name" => "has-dash"}],
          [%{"name" => String.duplicate("a", 33)}],
          [%{"name" => "access_token"}],
          [%{"name" => "Client_Id"}],
          [%{"name" => "user"}, %{"name" => "USER"}],
          many
        ] do
      assert {:error, {:bad_request, _}} = start_fields(tenant, group, fields)
    end

    assert {:ok, _} = start_fields(tenant, group, [%{"name" => String.duplicate("a", 32)}])
  end

  test "a provider definition needs a public-looking https token endpoint", %{tenant: tenant} do
    assert {:error, {:bad_request, _}} =
             OAuthApps.put_custom(tenant, "custom.acme", %{
               "client_id" => "cid",
               "token_url" => "http://acme.example/token",
               "authorize_url" => "https://acme.example/auth"
             })

    assert {:error, {:bad_request, _}} =
             OAuthApps.put_custom(tenant, "custom.ACME", %{
               "client_id" => "cid",
               "token_url" => "https://acme.example/token",
               "authorize_url" => "https://acme.example/auth"
             })

    assert {:ok, defined} =
             OAuthApps.put_custom(tenant, "custom.acme", %{
               "client_id" => "cid",
               "client_secret" => "sec",
               "token_url" => "https://acme.example/token",
               "authorize_url" => "https://acme.example/auth"
             })

    refute Map.has_key?(defined, "client_secret")
    assert {:ok, %{"client_secret" => "sec"}} = OAuthApps.get(tenant, "custom.acme")
    assert {:ok, OAuthCustomAdapter} = Adapters.for_provider("custom.acme")
    assert {:error, :unsupported_provider} = Adapters.for_provider("custom.a/b")
  end

  test "a custom provider's device flow stays pending, then connects", %{
    tenant: tenant,
    group: group
  } do
    {:ok, _} =
      OAuthApps.put_custom(tenant, "custom.acme", %{
        "client_id" => "cid",
        "token_url" => "https://acme.example/token",
        "device_authorization_url" => "https://acme.example/device"
      })

    state = pending(tenant, group, "custom.acme", %{"device_code" => "dc", "origin" => "agent"})
    {:ok, record} = AuthState.get(state)

    SystemsRuntime.put_env(:salix_web, :oauth_custom_http_fn, fn _url, _form, _headers ->
      {:ok, 400, %{"error" => "authorization_pending"}}
    end)

    assert {:ok, %{"status" => "pending"}} = OAuthFlow.poll_device(record)
    assert OAuthBindings.list(group) == []

    SystemsRuntime.put_env(:salix_web, :oauth_custom_http_fn, fn "https://acme.example/token",
                                                                 form,
                                                                 _headers ->
      assert {"device_code", "dc"} in form
      {:ok, 200, %{"access_token" => "at", "refresh_token" => "rt", "expires_in" => 3600}}
    end)

    assert {:ok, %{"status" => "completed"}} = OAuthFlow.poll_device(record)

    {binding, connection} = connected(group, "custom.acme")
    assert binding["owner"] == "comma_user|usr_ann"
    assert connection["refresh_token"] == "rt"
  end

  test "the adapter keeps a refresh token the provider did not rotate, and reads a refused one" do
    app = %{"client_id" => "cid", "client_secret" => "sec", "token_url" => "https://a.example/t"}

    SystemsRuntime.put_env(:salix_web, :oauth_custom_http_fn, fn _url, _form, _headers ->
      {:ok, 200, %{"access_token" => "new"}}
    end)

    assert {:ok, %{"access_token" => "new", "refresh_token" => "old"}} =
             OAuthCustomAdapter.refresh(app, %{"refresh_token" => "old"})

    SystemsRuntime.put_env(:salix_web, :oauth_custom_http_fn, fn _url, _form, _headers ->
      {:ok, 400, %{"error" => "invalid_grant"}}
    end)

    assert {:error, :reauthorization_required} =
             OAuthCustomAdapter.refresh(app, %{"refresh_token" => "old"})
  end

  test "the custom adapter sends no request to a private address" do
    assert {:error, message} =
             OAuthCustomAdapter.refresh(
               %{"client_id" => "cid", "token_url" => "https://127.0.0.1/token"},
               %{"refresh_token" => "old"}
             )

    assert message =~ "not a public address"
  end
end
