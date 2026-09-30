defmodule CommaWeb.PluginConnectionsTest do
  use Comma.DataCase, async: false

  alias CommaWeb.PluginConnections

  defmodule StubComposio do
    @moduledoc false

    def get(_tenant_id), do: {:ok, %{"api_key" => "ck_test"}}

    def list_connected_accounts(_settings, group_id) do
      accounts = Application.get_env(:comma_web, :plugin_connection_accounts, [])

      case Application.get_env(:comma_web, :plugin_connection_results, []) do
        [result | rest] ->
          Application.put_env(:comma_web, :plugin_connection_results, rest)
          result

        [] ->
          {:ok, Enum.filter(accounts, &(&1["user_id"] == group_id))}
      end
    end

    def list_connected_accounts_all(settings, group_id, _opts \\ []),
      do: list_connected_accounts(settings, group_id)

    def ensure_auth_config(_settings, toolkit), do: {:ok, "auth-#{toolkit}"}

    def create_connect_link(_settings, "auth-" <> toolkit, group_id, opts) do
      send(self(), {:connect_link, toolkit, group_id, opts})

      {:ok,
       %{
         "redirect_url" => "https://connect.composio.dev/link/#{toolkit}",
         "connected_account_id" =>
           Application.get_env(:comma_web, :plugin_connection_link_id, "ca_#{toolkit}")
       }}
    end

    def create_proxy_session(_settings, _group_id, id, _toolkit, _opts) do
      {:ok, "session-#{id}"}
    end

    def proxy_execute(
          _settings,
          "session-" <> id,
          %{"endpoint" => "https://www.googleapis.com/drive/v3/about?fields=user"},
          _opts
        ) do
      send(caller(), {:identity_checked, id})

      {:ok,
       %{
         "status" => 200,
         "data" => %{
           "user" => %{"permissionId" => "drive-user", "emailAddress" => "member@example.com"}
         }
       }}
    end

    def proxy_execute(
          _settings,
          "session-" <> id,
          %{"endpoint" => "https://www.googleapis.com/calendar/v3/calendars/primary"},
          _opts
        ) do
      send(caller(), {:identity_checked, id})
      {:ok, %{"status" => 200, "data" => %{"id" => "member@example.com"}}}
    end

    def proxy_execute(_settings, "session-" <> id, _request, _opts) do
      send(caller(), {:identity_checked, id})

      {:ok,
       %{
         "status" => 200,
         "data" =>
           Application.get_env(:comma_web, :plugin_connection_identity, %{
             "ok" => true,
             "user_id" => "U123456",
             "team_id" => "T123456",
             "user" => "member",
             "team" => "team"
           })
       }}
    end

    def delete_proxy_session(_settings, _session), do: :ok

    # Member requests run in a task; the test process started the chain.
    defp caller, do: List.last(Process.get(:"$callers", [self()]))

    def get_connected_account(_settings, id) do
      case Enum.find(
             Application.get_env(:comma_web, :plugin_connection_accounts, []),
             &(&1["id"] == id)
           ) do
        nil -> {:error, :not_found}
        account -> {:ok, account}
      end
    end

    def delete_connected_account(_settings, id) do
      accounts = Application.get_env(:comma_web, :plugin_connection_accounts, [])

      Application.put_env(
        :comma_web,
        :plugin_connection_accounts,
        Enum.reject(accounts, &(&1["id"] == id))
      )

      send(self(), {:deleted_connected_account, id})
      :ok
    end
  end

  setup do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    previous_settings = Application.get_env(:salix_web, :composio_settings_mod)
    previous_client = Application.get_env(:salix_web, :composio_client_mod)

    Application.put_env(:salix_web, :composio_settings_mod, StubComposio)
    Application.put_env(:salix_web, :composio_client_mod, StubComposio)
    Application.put_env(:comma_web, :plugin_connection_accounts, [])

    on_exit(fn ->
      restore_env(:salix_web, :composio_settings_mod, previous_settings)
      restore_env(:salix_web, :composio_client_mod, previous_client)
      Application.delete_env(:comma_web, :plugin_connection_accounts)
      Application.delete_env(:comma_web, :plugin_connection_results)
      Application.delete_env(:comma_web, :plugin_connection_link_id)
      Application.delete_env(:comma_web, :plugin_connection_identity)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)
  end

  test "Composio installation stays disabled until its group-scoped authorization completes" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "plugin-connection-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)

    assert {:ok, status} = PluginConnections.get(user, %{}, workspace["id"], composio_plugin_id())

    assert status == %{
             "pluginId" => composio_plugin_id(),
             "connection" => %{
               "id" => "slack-composio",
               "kind" => "composio",
               "label" => "Slack via Composio",
               "state" => "not_connected"
             },
             "configuration" => %{
               "provider" => "composio",
               "requiredFields" => ["apiKey"],
               "status" => "ready",
               "url" =>
                 String.trim_trailing(SalixWeb.Application.public_base_url(), "/") <>
                   "/dash/composio"
             }
           }

    assert {:ok, install} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id())

    assert install["plugin"]["installed"] == false

    assert install["authorization"]["authorizationUrl"] ==
             "https://connect.composio.dev/link/slack"

    initial_state = install["authorization"]["state"]
    assert {:ok, _uuid} = Ecto.UUID.cast(initial_state)

    assert_received {:connect_link, "slack", group_id, []}
    assert group_id == workspace["default_group_id"]

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_unrelated",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "gmail"},
        "status" => "INITIATED"
      }
    ])

    assert {:ok, unrelated_retry} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), %{
               "authorization_state" => "ca_unrelated",
               "verify_only" => true
             })

    assert unrelated_retry["plugin"]["installed"] == false
    assert unrelated_retry["authorization"] == nil

    assert {:error, :not_found} =
             Comma.Recommendations.get_runtime_profile(workspace["id"], user["id"])

    Application.put_env(:comma_web, :plugin_connection_accounts, [])

    assert {:ok, cancelled} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), %{
               "authorization_state" => initial_state,
               "verify_only" => true
             })

    assert cancelled["plugin"]["installed"] == false
    assert cancelled["authorization"] == nil
    refute_received {:connect_link, "slack", _, _}

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_slack",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, stale_cancelled_attempt} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), %{
               "authorization_state" => initial_state,
               "verify_only" => true
             })

    assert stale_cancelled_attempt["authorization"] == nil
    assert stale_cancelled_attempt["plugin"]["installed"] == false

    assert {:ok, restarted} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id())

    assert restarted["authorization"]["state"] != install["authorization"]["state"]

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_slack",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, completed} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), %{
               "authorization_state" => restarted["authorization"]["state"],
               "verify_only" => true
             })

    assert completed["authorization"] == nil
    assert completed["plugin"]["installed"] == true

    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "slack") ==
             "ca_slack"

    # Consent must not create a default-UTC Routine before its first client read.
    assert {:error, :not_found} =
             Comma.Recommendations.get_runtime_profile(workspace["id"], user["id"])

    assert Comma.Repo.get_by!(Comma.Data.PluginInstallAttempt,
             workspace_id: workspace["id"],
             plugin_id: composio_plugin_id()
           ).provider_state == nil

    assert {:ok, removed} =
             PluginConnections.uninstall(user, %{}, workspace["id"], composio_plugin_id())

    assert removed["installed"] == false
    assert_received {:deleted_connected_account, "ca_slack"}
    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "slack") == nil

    # A duplicate verification from the completed pre-uninstall attempt is
    # fenced by the persisted server attempt generation, even if provider
    # deletion remains stale and the old account becomes visible again.
    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_slack",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, delayed_retry} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), %{
               "authorization_state" => restarted["authorization"]["state"],
               "verify_only" => true
             })

    assert delayed_retry["plugin"]["installed"] == false
    assert delayed_retry["authorization"] == nil

    assert {:ok, plugins_after_delayed_retry} =
             Comma.Plugins.list(user, %{}, workspace["id"])

    assert Enum.find(plugins_after_delayed_retry, &(&1["id"] == composio_plugin_id()))[
             "installed"
           ] ==
             false

    # Provider deletion is not assumed to be immediately consistent. Even if
    # the old account remains visible, reinstall must issue a fresh link and
    # cannot use it as completion evidence for the new installation attempt.
    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_old_slack",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, reinstall} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id())

    assert reinstall["plugin"]["installed"] == false
    assert reinstall["authorization"]["authorizationUrl"] =~ "/slack"

    assert {:ok, not_completed_by_old_account} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), %{
               "authorization_state" => reinstall["authorization"]["state"],
               "verify_only" => true
             })

    assert not_completed_by_old_account["plugin"]["installed"] == false
  end

  test "pending verification preserves the connection and can complete the same attempt" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "pending-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)

    assert {:ok, install} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id())

    state = install["authorization"]["state"]

    account = %{
      "id" => "ca_slack",
      "user_id" => workspace["default_group_id"],
      "toolkit" => %{"slug" => "slack"},
      "status" => "INITIATED"
    }

    Application.put_env(:comma_web, :plugin_connection_accounts, [account])

    assert {:ok, pending} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), %{
               "authorization_state" => state,
               "verify_only" => true
             })

    assert pending["plugin"]["installed"] == false
    assert pending["authorization"]["state"] == state
    refute_received {:deleted_connected_account, "ca_slack"}

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      Map.put(account, "status", "ACTIVE")
    ])

    assert {:ok, completed} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), %{
               "authorization_state" => state,
               "verify_only" => true
             })

    assert completed["plugin"]["installed"] == true
    assert completed["authorization"] == nil
  end

  test "a transient provider read preserves verification state and does not delete the account" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "verify-read-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)

    assert {:ok, install} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id())

    account = %{
      "id" => "ca_slack",
      "user_id" => workspace["default_group_id"],
      "toolkit" => %{"slug" => "slack"},
      "status" => "INITIATED"
    }

    Application.put_env(:comma_web, :plugin_connection_accounts, [account])

    Application.put_env(:comma_web, :plugin_connection_results, [
      {:ok, [account]},
      {:error, :provider_unavailable}
    ])

    state = install["authorization"]["state"]

    assert {:ok, pending} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), %{
               "authorization_state" => state,
               "verify_only" => true
             })

    assert pending["authorization"]["state"] == state
    refute_received {:deleted_connected_account, "ca_slack"}
  end

  test "installation completion requests discovery even when a periodic discovery just completed" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "install-discovery-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)
    {:ok, _} = Comma.Recommendations.get(user, %{}, workspace["id"])
    {:ok, profile} = Comma.Recommendations.get_runtime_profile(workspace["id"], user["id"])
    {:ok, periodic} = Comma.Recommendations.enqueue_source_sync(profile.id)

    Comma.Repo.update!(
      Ecto.Changeset.change(periodic, state: "completed", completed_at: DateTime.utc_now())
    )

    assert {:ok, install} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id())

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_slack",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    opts = %{"authorization_state" => install["authorization"]["state"], "verify_only" => true}

    assert {:ok, _} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), opts)

    assert {:ok, _} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), opts)

    jobs =
      Comma.Repo.all(
        from(j in Oban.Job, where: j.worker == "Comma.Workers.RecommendationSourceSync")
      )

    assert length(jobs) == 2
    assert Enum.count(jobs, &(&1.state == "available")) == 1
  end

  test "starting a fresh authorization preserves existing active accounts" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "reconnect-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_existing",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, install} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id())

    assert install["plugin"]["installed"] == false
    assert install["authorization"]["authorizationUrl"] =~ "/slack"
    refute_received {:deleted_connected_account, "ca_existing"}
  end

  test "a completed fresh authorization retires the toolkit's other active accounts" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "retire-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)
    group_id = workspace["default_group_id"]

    older_slack = %{
      "id" => "ca_slack_older",
      "user_id" => group_id,
      "toolkit" => %{"slug" => "slack"},
      "status" => "ACTIVE",
      "created_at" => "2026-09-01T08:00:00.000Z"
    }

    abandoned_slack = %{
      "id" => "ca_slack_abandoned",
      "user_id" => group_id,
      "toolkit" => %{"slug" => "slack"},
      "status" => "INITIATED"
    }

    gmail = %{
      "id" => "ca_gmail",
      "user_id" => group_id,
      "toolkit" => %{"slug" => "gmail"},
      "status" => "ACTIVE"
    }

    # A Slack account that another completion minted after this one started
    # is not this completion's to retire.
    newer_slack = %{
      "id" => "ca_slack_newer",
      "user_id" => group_id,
      "toolkit" => %{"slug" => "slack"},
      "status" => "ACTIVE",
      "created_at" => "2026-09-11T09:00:00.000Z"
    }

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      older_slack,
      abandoned_slack,
      gmail
    ])

    # A fresh Add obtains fresh consent and preserves the older account. The
    # client holds the opaque attempt state; the attempt records the account.
    assert {:ok, install} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id())

    state = install["authorization"]["state"]
    assert is_binary(state)
    assert_received {:connect_link, "slack", ^group_id, _opts}
    refute_received {:deleted_connected_account, _}

    completed = %{
      "id" => "ca_slack",
      "user_id" => group_id,
      "toolkit" => %{"slug" => "slack"},
      "status" => "ACTIVE",
      "created_at" => "2026-09-11T08:00:00.000Z"
    }

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      newer_slack,
      completed,
      older_slack,
      abandoned_slack,
      gmail
    ])

    assert {:ok, result} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id(), %{
               "authorization_state" => state,
               "verify_only" => true
             })

    assert result["plugin"]["installed"] == true

    # Only the toolkit's older active account goes; the completed one, a newer
    # one, an abandoned attempt of the same toolkit, and other toolkits stay.
    assert_received {:deleted_connected_account, "ca_slack_older"}
    refute_received {:deleted_connected_account, "ca_slack"}
    refute_received {:deleted_connected_account, "ca_slack_newer"}
    refute_received {:deleted_connected_account, "ca_slack_abandoned"}
    refute_received {:deleted_connected_account, "ca_gmail"}

    remaining = Application.get_env(:comma_web, :plugin_connection_accounts)

    assert Enum.map(remaining, & &1["id"]) == [
             "ca_slack_newer",
             "ca_slack",
             "ca_slack_abandoned",
             "ca_gmail"
           ]
  end

  test "Composio account status uses the same group boundary as BFT/Admin" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "plugin-account-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)

    assert {:ok, _plugin} =
             Comma.Plugins.install(user, %{}, workspace["id"], composio_plugin_id())

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_slack",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      },
      %{
        "id" => "ca_foreign",
        "user_id" => "another-group",
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, status} = PluginConnections.get(user, %{}, workspace["id"], composio_plugin_id())
    assert status["connection"]["id"] == "slack-composio"
    assert status["connection"]["state"] == "connected"
  end

  test "Comma hides Feishu and rejects new installation without removing its definition" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "hidden-feishu-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)
    assert {:ok, plugins} = Comma.Plugins.list(user, %{}, workspace["id"])
    refute Enum.any?(plugins, &(&1["id"] == "feishu"))
    assert Enum.any?(plugins, &(&1["id"] == "google"))
    assert {:error, :not_found} = Comma.Plugins.install(user, %{}, workspace["id"], "feishu")
    assert {:error, :not_found} = PluginConnections.install(user, %{}, workspace["id"], "feishu")

    assert {:ok, %{"plugin_id" => "feishu"}} =
             Salix.Control.Plugins.get_definition(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               "feishu"
             )
  end

  test "public built-in plugins expose their connection setup" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "plugin-connections-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)

    expected = %{
      "slack" => {"slack-managed", "managed_oauth"},
      "google" => {"gmail-composio", "composio"},
      "notion" => {"notion-managed", "managed_oauth"},
      "github" => {"github-managed", "managed_oauth"},
      "linear" => {"linear-managed", "managed_oauth"}
    }

    for {plugin_id, {connection_id, kind}} <- expected do
      assert {:ok, _plugin} = Comma.Plugins.install(user, %{}, workspace["id"], plugin_id)
      assert {:ok, status} = PluginConnections.get(user, %{}, workspace["id"], plugin_id)
      assert status["connection"]["id"] == connection_id
      assert status["connection"]["kind"] == kind
    end
  end

  test "a plugin with multiple Composio toolkits connects each missing toolkit" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "plugin-google-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)

    assert {:ok, status} = PluginConnections.get(user, %{}, workspace["id"], "google")
    assert status["connection"]["label"] == "Google Workspace via Composio"
    assert status["connection"]["state"] == "not_connected"

    assert {:ok, first_install} =
             PluginConnections.install(user, %{}, workspace["id"], "google")

    assert first_install["plugin"]["installed"] == false
    assert first_install["authorization"]["authorizationUrl"] =~ "/gmail"
    assert_received {:connect_link, "gmail", _, _}

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_gmail",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "gmail"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, install} =
             PluginConnections.install(user, %{}, workspace["id"], "google", %{
               "authorization_state" => first_install["authorization"]["state"],
               "verify_only" => true
             })

    assert install["plugin"]["installed"] == false
    assert install["authorization"]["authorizationUrl"] =~ "/googlecalendar"
    assert_received {:connect_link, "googlecalendar", _, _}
  end

  test "Google Drive can be confirmed without changing Gmail and Calendar installation" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "google-drive-confirm-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)
    group = workspace["default_group_id"]

    Application.put_env(
      :comma_web,
      :plugin_connection_accounts,
      Enum.map(~w(gmail googlecalendar googledrive), fn toolkit ->
        %{
          "id" => "ca_#{toolkit}",
          "user_id" => group,
          "toolkit" => %{"slug" => toolkit},
          "status" => "ACTIVE"
        }
      end)
    )

    assert {:ok, _} = Comma.Plugins.install(user, %{}, workspace["id"], "google")

    assert {:ok, %{"connection" => %{"state" => "connected"}}} =
             PluginConnections.get(user, %{}, workspace["id"], "google")

    assert {:ok, %{"sources" => sources}} =
             PluginConnections.personal_sources(user, %{}, workspace["id"], "google")

    assert Enum.map(sources, & &1["toolkit"]) == ~w(gmail googlecalendar googledrive)

    assert {:ok, prepared} =
             PluginConnections.prepare_existing(
               user,
               %{},
               workspace["id"],
               "google",
               "googledrive",
               "ca_googledrive"
             )

    assert prepared["identity"] == "member@example.com"

    assert {:ok, _} =
             PluginConnections.confirm_existing(
               user,
               %{},
               workspace["id"],
               "google",
               prepared["state"]
             )

    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "googledrive") ==
             "ca_googledrive"

    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "gmail") == nil
  end

  test "an installed Slack account requires explicit owner confirmation before member use" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "legacy-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)
    assert {:ok, _} = Comma.Plugins.install(user, %{}, workspace["id"], composio_plugin_id())

    accounts = [
      %{
        "id" => "ca_old",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE",
        "created_at" => "2026-09-01T00:00:00Z"
      },
      %{
        "id" => "ca_new",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE",
        "created_at" => "2026-09-02T00:00:00Z"
      }
    ]

    Application.put_env(:comma_web, :plugin_connection_accounts, accounts)
    assert {:ok, _} = Comma.Recommendations.get(user, %{}, workspace["id"])
    assert {:ok, profile} = Comma.Recommendations.get_runtime_profile(workspace["id"], user["id"])

    assert {:ok, %{"sources" => [%{"state" => "needs_confirmation", "candidates" => candidates}]}} =
             PluginConnections.personal_sources(user, %{}, workspace["id"], composio_plugin_id())

    assert Enum.map(candidates, & &1["id"]) == ~w(ca_old ca_new)
    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "slack") == nil

    assert {:ok, prepared} =
             PluginConnections.prepare_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               "slack",
               "ca_old"
             )

    assert prepared["identity"] == "member · team"
    assert_received {:identity_checked, "ca_old"}

    assert {:ok, %{"state" => "ready"}} =
             PluginConnections.confirm_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               prepared["state"]
             )

    assert_received {:identity_checked, "ca_old"}

    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "slack") ==
             "ca_old"

    assert Enum.any?(Comma.Repo.all(Oban.Job), fn job ->
             job.worker == "Comma.Workers.RecommendationSourceSync" and
               job.args["profile_id"] == profile.id
           end)

    assert :ok = CommaWeb.RecommendationRuntime.sync_sources(profile.id)
    assert {:ok, updated} = Comma.Recommendations.get_runtime_profile(workspace["id"], user["id"])
    assert Enum.find(updated.sources, &(&1["toolkit"] == "slack"))["connectionId"] == "ca_old"

    assert {:error, _} =
             PluginConnections.confirm_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               prepared["state"]
             )

    assert {:ok, %{"sources" => [%{"state" => "ready", "selectedAccountId" => "ca_old"}]}} =
             PluginConnections.personal_sources(user, %{}, workspace["id"], composio_plugin_id())

    assert {:ok, discovered} =
             CommaWeb.RecommendationSources.discover(workspace, user["id"], "member")

    assert Enum.find(discovered, &(&1["toolkit"] == "slack"))["connectionId"] == "ca_old"

    Application.put_env(:comma_web, :plugin_connection_accounts, tl(accounts))

    assert {:ok, unavailable} =
             CommaWeb.RecommendationSources.discover(workspace, user["id"], "member")

    assert Enum.find(unavailable, &(&1["toolkit"] == "slack"))["connectionId"] == "ca_old"
  end

  test "confirming an already listed account refreshes Routine once" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "legacy-refresh-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)
    assert {:ok, _} = Comma.Plugins.install(user, %{}, workspace["id"], composio_plugin_id())

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_existing",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, _} = Comma.Recommendations.get(user, %{}, workspace["id"])
    assert {:ok, profile} = Comma.Recommendations.get_runtime_profile(workspace["id"], user["id"])
    assert :ok = CommaWeb.RecommendationRuntime.sync_sources(profile.id)
    assert {:ok, before} = Comma.Recommendations.get_runtime_profile(workspace["id"], user["id"])

    assert Enum.find(before.sources, &(&1["toolkit"] == "slack"))["connectionId"] ==
             "ca_existing"

    assert {:ok, prepared} =
             PluginConnections.prepare_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               "slack",
               "ca_existing"
             )

    assert {:ok, _} =
             PluginConnections.confirm_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               prepared["state"]
             )

    job =
      Comma.Repo.one!(
        from(j in Oban.Job,
          where:
            j.worker == "Comma.Workers.RecommendationSourceSync" and
              not is_nil(fragment("?->>'refresh_token'", j.args))
        )
      )

    token = job.args["refresh_token"]
    assert :ok = CommaWeb.RecommendationRuntime.sync_sources(profile.id, refresh_token: token)

    assert {:ok, after_sync} =
             Comma.Recommendations.get_runtime_profile(workspace["id"], user["id"])

    assert after_sync.source_revision == before.source_revision

    assert Comma.Repo.aggregate(
             from(r in Comma.Data.RecommendationRun,
               where: r.profile_id == ^profile.id and r.source_message_id == ^"confirmed:#{token}"
             ),
             :count,
             :id
           ) == 1

    assert :ok = CommaWeb.RecommendationRuntime.sync_sources(profile.id, refresh_token: token)

    assert Comma.Repo.aggregate(
             from(r in Comma.Data.RecommendationRun,
               where: r.profile_id == ^profile.id and r.source_message_id == ^"confirmed:#{token}"
             ),
             :count,
             :id
           ) == 1
  end

  test "confirmation rejects changed identity, foreign accounts and cancelled attempts" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "confirm-boundary-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)
    assert {:ok, _} = Comma.Plugins.install(user, %{}, workspace["id"], composio_plugin_id())

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_foreign",
        "user_id" => "other-group",
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      },
      %{
        "id" => "ca_owned",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:error, :not_found} =
             PluginConnections.prepare_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               "slack",
               "ca_foreign"
             )

    assert {:error, :not_found} =
             PluginConnections.prepare_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               "gmail",
               "ca_owned"
             )

    assert {:ok, prepared} =
             PluginConnections.prepare_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               "slack",
               "ca_owned"
             )

    Application.put_env(:comma_web, :plugin_connection_identity, %{
      "ok" => true,
      "user_id" => "U999999",
      "team_id" => "T123456"
    })

    assert {:error, {:conflict, _}} =
             PluginConnections.confirm_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               prepared["state"]
             )

    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "slack") == nil

    Application.delete_env(:comma_web, :plugin_connection_identity)

    assert {:ok, prepared_again} =
             PluginConnections.prepare_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               "slack",
               "ca_owned"
             )

    assert {:ok, :ok} =
             PluginConnections.cancel_operation(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               prepared_again["state"]
             )

    assert {:error, _} =
             PluginConnections.confirm_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               prepared_again["state"]
             )

    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "slack") == nil
  end

  test "a changed receipt blocks confirmation and preserves the pending operation" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "confirm-race-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)
    assert {:ok, _} = Comma.Plugins.install(user, %{}, workspace["id"], composio_plugin_id())

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      %{
        "id" => "ca_first",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      },
      %{
        "id" => "ca_second",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    assert {:ok, prepared} =
             PluginConnections.prepare_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               "slack",
               "ca_first"
             )

    assert {:ok, :ok} =
             Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "slack", "ca_second")

    assert {:error, {:conflict, _}} =
             PluginConnections.confirm_existing(
               user,
               %{},
               workspace["id"],
               composio_plugin_id(),
               prepared["state"]
             )

    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "slack") ==
             "ca_second"

    assert Comma.Repo.get_by!(Comma.Data.PluginInstallAttempt,
             workspace_id: workspace["id"],
             plugin_id: composio_plugin_id()
           ).authorization_state == prepared["state"]
  end

  test "targeted reauthorization preserves the old account until the new grant completes" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "reauthorize-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)
    group = workspace["default_group_id"]

    old = %{
      "id" => "ca_old",
      "user_id" => group,
      "toolkit" => %{"slug" => "slack"},
      "status" => "ACTIVE",
      "created_at" => "2026-09-01T00:00:00Z"
    }

    Application.put_env(:comma_web, :plugin_connection_accounts, [old])
    Application.put_env(:comma_web, :plugin_connection_link_id, "ca_new")
    assert {:ok, _} = Comma.Plugins.install(user, %{}, workspace["id"], composio_plugin_id())

    assert {:ok, :ok} =
             Comma.MemberSourceConsents.record(user, %{}, workspace["id"], "slack", "ca_old")

    assert {:ok, started} =
             PluginConnections.reauthorize(user, %{}, workspace["id"], composio_plugin_id(), %{
               "connection_id" => "slack-composio"
             })

    assert started["plugin"]["installed"] == true
    assert started["authorization"]["authorizationUrl"] =~ "/slack"

    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "slack") ==
             "ca_old"

    refute_received {:deleted_connected_account, "ca_old"}

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      old,
      %{
        "id" => "ca_new",
        "user_id" => group,
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE",
        "created_at" => "2026-09-02T00:00:00Z"
      }
    ])

    Application.put_env(:comma_web, :plugin_connection_identity, %{
      "ok" => true,
      "user_id" => "U123456",
      "team_id" => "T123456",
      "bot_id" => "B123456"
    })

    assert {:error, :member_account_not_personal} =
             PluginConnections.reauthorize(user, %{}, workspace["id"], composio_plugin_id(), %{
               "verify_only" => true,
               "authorization_state" => started["authorization"]["state"]
             })

    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "slack") ==
             "ca_old"

    refute_received {:deleted_connected_account, "ca_old"}
    Application.delete_env(:comma_web, :plugin_connection_identity)

    assert {:ok, finished} =
             PluginConnections.reauthorize(user, %{}, workspace["id"], composio_plugin_id(), %{
               "verify_only" => true,
               "authorization_state" => started["authorization"]["state"]
             })

    assert finished["plugin"]["installed"] == true
    assert finished["authorization"] == nil

    assert Comma.MemberSourceConsents.connection_id(workspace["id"], user["id"], "slack") ==
             "ca_new"

    assert_received {:deleted_connected_account, "ca_old"}
  end

  test "reconnecting a personal Calendar retires only the account it replaces" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "calendar-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)

    calendar = fn id, created_at ->
      %{
        "id" => id,
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "googlecalendar"},
        "status" => "ACTIVE",
        "created_at" => created_at
      }
    end

    # Meeting detection enrolls every active Calendar account in the group, so
    # the second account is not the personal source's to retire.
    personal = calendar.("ca_personal", "2026-09-01T00:00:00Z")
    meeting = calendar.("ca_meeting", "2026-09-02T00:00:00Z")
    Application.put_env(:comma_web, :plugin_connection_accounts, [personal, meeting])
    Application.put_env(:comma_web, :plugin_connection_link_id, "ca_reconnected")
    assert {:ok, _} = Comma.Plugins.install(user, %{}, workspace["id"], "google")

    assert {:ok, :ok} =
             Comma.MemberSourceConsents.record(
               user,
               %{},
               workspace["id"],
               "googlecalendar",
               "ca_personal"
             )

    assert {:ok, started} =
             PluginConnections.reauthorize(user, %{}, workspace["id"], "google", %{
               "connection_id" => "googlecalendar-composio"
             })

    Application.put_env(:comma_web, :plugin_connection_accounts, [
      personal,
      meeting,
      calendar.("ca_reconnected", "2026-09-03T00:00:00Z")
    ])

    assert {:ok, %{"authorization" => nil}} =
             PluginConnections.reauthorize(user, %{}, workspace["id"], "google", %{
               "verify_only" => true,
               "authorization_state" => started["authorization"]["state"]
             })

    assert Comma.MemberSourceConsents.connection_id(
             workspace["id"],
             user["id"],
             "googlecalendar"
           ) == "ca_reconnected"

    assert_received {:deleted_connected_account, "ca_personal"}
    refute_received {:deleted_connected_account, "ca_meeting"}

    assert ["ca_meeting", "ca_reconnected"] ==
             :comma_web
             |> Application.get_env(:plugin_connection_accounts)
             |> Enum.map(& &1["id"])
  end

  test "starting installation never enables an unconnected plugin" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" =>
          "plugin-connection-uninstalled-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_composio_workspace!(user)

    assert {:ok, install} =
             PluginConnections.install(user, %{}, workspace["id"], composio_plugin_id())

    assert install["plugin"]["installed"] == false
    assert install["authorization"]["authorizationUrl"] =~ "/slack"

    assert {:ok, plugins} = Comma.Plugins.list(user, %{}, workspace["id"])
    assert Enum.find(plugins, &(&1["id"] == composio_plugin_id()))["installed"] == false
  end

  # A product-owned Composio plugin exercises account consent and replacement.
  # The built-in Slack plugin uses managed OAuth.
  defp create_composio_workspace!(user) do
    workspace = create_ready_workspace!(user)

    {:ok, plugin} =
      Salix.Control.Plugins.create_definition(
        workspace["salix_tenant_id"],
        workspace["default_group_id"],
        %{
          "name" => "Test messaging",
          "owner_scope" => "group",
          "setup" => %{
            "type" => "integration",
            "default_connection" => "slack-composio",
            "connections" => [
              %{
                "id" => "slack-composio",
                "kind" => "composio",
                "label" => "Slack via Composio",
                "toolkit" => "slack"
              }
            ]
          }
        }
      )

    Process.put(:composio_test_plugin_id, plugin["plugin_id"])
    workspace
  end

  defp composio_plugin_id, do: Process.get(:composio_test_plugin_id)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
