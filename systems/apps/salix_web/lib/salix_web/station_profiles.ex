defmodule SalixWeb.StationProfiles do
  @moduledoc """
  The workspace's accounts a station runs Claude and Codex with, and, for a
  Workload's station, the platform's `worker` model (`SalixWeb.StationLLM`).

  Two stations are lent the accounts: a Workload's station, and a member's
  device station (a Connector run that proved a station with
  `relay_register`, such as the desktop app's station for one workspace).
  A device station is lent them while its owner may enroll a station in the
  Group (`SalixStore.StationMembers.enroller?/3`: any role but a read-only
  one). Otherwise it is sent no profiles and refused every `share.*`.
  A coding Task that selected an account receives only that account.

  Salix lends them as another station lends its shares (the station's share
  protocol, `systems/station/src/share`): it sends their profiles when the
  station connects (`station_profiles`), and the station asks it, over the
  same connection, for what it lends: `share.lend` (a subscription's
  short-lived token, for each process it starts), `share.get`,
  `share.version` and `share.status`. An API key's profile carries its key.
  A subscription's login stays with Salix, which renews it. The platform
  model's profile carries a key of the station's connection, never the
  platform's own.
  """

  alias SalixAgent.{AccountPool, SubscriptionStore}

  @doc """
  The profiles the station of `connection` (its `tenant_id`, `group_id`,
  `device_id` and `connector_run_id`) uses, as the share protocol has them:
  the workspace's accounts, and the platform's `worker` model when it is
  configured for Codex (`SalixWeb.StationLLM`). A connection with an
  `owner_user_id` is a member's device station: it gets the accounts only,
  and none when its owner is not lent them.
  """
  def profiles(%{tenant_id: tenant} = connection) do
    case authorized(connection) do
      {:ok, owner} ->
        with {:ok, accounts} <- accounts(tenant, owner),
             do: {:ok, Enum.map(accounts, &share(tenant, &1)) ++ platform(connection)}

      {:error, _} ->
        {:ok, []}
    end
  end

  # The authorization snapshot owns the account restriction. Never re-read a
  # stable Device here: a later generation may have a different account.
  defp accounts(tenant, owner) do
    with {:ok, accounts} <- SubscriptionStore.station_accounts(tenant) do
      case owner do
        %{"owner" => "coding_task", "account_id" => id} when is_binary(id) ->
          {:ok, Enum.filter(accounts, &(&1["id"] == id))}

        _ ->
          {:ok, accounts}
      end
    end
  end

  @doc "Sends the station of `connection` the profiles it uses."
  def push(%{connector_run_id: run} = connection) do
    with {:ok, profiles} <- profiles(connection),
         {:ok, _} <-
           SalixEnv.Connector.Live.request(run, "station_profiles", %{"profiles" => profiles},
             timeout: 20_000
           ),
         do: :ok
  end

  @doc "What the station of `connection` asks of a profile it uses (`share.*`)."
  def handle(%{} = connection, "share." <> _ = method, %{"id" => id} = params)
      when is_binary(id) do
    with {:ok, owner} <- authorized(connection), do: handle(connection, owner, method, params)
  end

  def handle(_connection, _method, _params), do: {:error, "bad share request"}

  @doc false
  def handle(%{tenant_id: tenant} = connection, owner, method, %{"id" => id}) do
    if id == platform_id(tenant),
      do: handle_platform(connection, method),
      else: handle_account(connection, owner, method, id)
  end

  defp authorized(%{owner_user_id: owner, tenant_id: tenant, group_id: group} = connection) do
    if SalixStore.StationMembers.enroller?(tenant, group, owner),
      do: SalixEnv.StationConnection.authorize(connection),
      else: {:error, "this station is not lent the workspace's accounts"}
  end

  defp authorized(connection) do
    case SalixEnv.StationConnection.authorize(connection) do
      {:ok, record} -> {:ok, record}
      _ -> {:error, "this station is not lent the workspace's accounts"}
    end
  end

  defp handle_platform(connection, method) do
    case platform(connection) do
      [shared] -> answer_platform(method, shared)
      [] -> {:error, "this station does not share that"}
    end
  end

  defp handle_account(connection, owner, method, id) do
    tenant = connection.tenant_id

    with {:ok, accounts} <- accounts(tenant, owner),
         %{} = account <-
           Enum.find(accounts, &(share_id(tenant, &1["id"]) == id)) ||
             {:error, "this station does not share that"} do
      answer(tenant, method, account)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "the accounts are unavailable"}
    end
  end

  # The platform's model, lent as a profile of an endpoint here whose key is a
  # token of this connection: a new connection is a new key, so a new version.
  # Only a Workload's station is lent it.
  defp platform(%{owner_user_id: _member}), do: []

  defp platform(%{tenant_id: tenant} = connection) do
    with {:ok, template} <- SalixWeb.StationLLM.tier(),
         {:ok, token} <-
           SalixWeb.StationLLM.token(
             tenant,
             connection.group_id,
             connection.device_id,
             connection.connector_run_id
           ) do
      name = template["name"]

      [
        %{
          "id" => platform_id(tenant),
          "version" => :erlang.phash2({template["model"], connection.connector_run_id}),
          "name" => name,
          "profile" => %{
            "name" => name,
            "runtime" => "codex",
            "credential" => "api_key",
            "source" => "custom",
            "endpoint" =>
              String.trim_trailing(SalixWeb.Application.public_base_url(), "/") <>
                SalixWeb.StationLLM.base_path(),
            "protocol" => "responses",
            "model" => template["model"],
            "models" => [template["model"]],
            "key" => token
          }
        }
      ]
    else
      _ -> []
    end
  end

  defp platform_id(tenant), do: share_id(tenant, "platform:worker")

  defp answer_platform("share.get", shared),
    do: {:ok, Map.merge(Map.take(shared, ~w(version profile)), %{"allow" => nil})}

  defp answer_platform("share.version", shared), do: {:ok, %{"version" => shared["version"]}}
  defp answer_platform("share.status", _shared), do: {:ok, %{"check" => nil, "quota" => nil}}
  defp answer_platform("share.lend", _shared), do: {:error, "only a subscription is lent"}
  defp answer_platform(method, _shared), do: {:error, "unknown share request #{method}"}

  defp answer(tenant, "share.get", account) do
    shared = share(tenant, account)
    {:ok, Map.merge(Map.take(shared, ~w(version profile email)), %{"allow" => nil})}
  end

  defp answer(_tenant, "share.version", account), do: {:ok, %{"version" => version(account)}}
  defp answer(_tenant, "share.status", _account), do: {:ok, %{"check" => nil, "quota" => nil}}

  defp answer(tenant, "share.lend", %{"credential" => "subscription"} = account) do
    runtime = runtime(account)

    case AccountPool.runtime_access(tenant, account["id"], runtime) do
      {:ok, access} -> {:ok, lent(tenant, runtime, account["id"], access)}
      {:error, _} -> {:error, "the account cannot be lent now"}
    end
  end

  defp answer(_tenant, "share.lend", _account), do: {:error, "only a subscription is lent"}
  defp answer(_tenant, method, _account), do: {:error, "unknown share request #{method}"}

  defp lent(_tenant, "claude", _id, access),
    do: %{
      "runtime" => "claude",
      "token" => access["access_token"],
      "expiresAt" => access["expires_at"] * 1_000
    }

  # Codex reads its plan from the ID token beside the access token.
  defp lent(tenant, "codex", id, access) do
    id_token =
      with {:ok, record} <- SubscriptionStore.get(tenant, id),
           {:ok, credentials} <- SubscriptionStore.open(tenant, id, record["credentials"]) do
        credentials["id_token"]
      else
        _ -> nil
      end

    %{
      "runtime" => "codex",
      "tokens" => %{
        "id_token" => id_token,
        "access_token" => access["access_token"],
        "account_id" => access["chatgpt_account_id"]
      },
      "expiresAt" => access["expires_at"] * 1_000
    }
  end

  defp share(tenant, account) do
    %{
      "id" => share_id(tenant, account["id"]),
      "version" => version(account),
      "name" => account["name"] || account["email"] || account["source"],
      "profile" => profile(tenant, account),
      "email" => account["email"]
    }
  end

  defp profile(tenant, account) do
    %{
      "name" => account["name"] || account["email"] || account["source"],
      "runtime" => runtime(account),
      "credential" => account["credential"],
      "source" => account["source"],
      "endpoint" => account["endpoint"],
      "protocol" => account["protocol"],
      "model" => account["model"],
      # What the station may run on it (its Tasks' `task_models`).
      "models" => SalixAgent.AccountPool.profile_models(account),
      "disabled_models" => account["disabled_models"],
      "key" => key(tenant, account)
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp key(tenant, %{"credential" => "api_key"} = account) do
    case SubscriptionStore.open(tenant, account["id"], account["credentials"]) do
      {:ok, %{"api_key" => key}} when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp key(_tenant, _account), do: nil

  defp runtime(%{"credential" => "subscription", "source" => source}), do: source
  defp runtime(_api_key), do: "claude"

  # The share's id: of this account, in this tenant, as the share protocol spells one.
  defp share_id(tenant, account_id) do
    digest =
      :crypto.hash(:sha256, tenant <> ":" <> account_id)
      |> Base.encode32(case: :lower, padding: false)

    "sh-" <> binary_part(digest, 0, 24)
  end

  # A station takes a profile again when this changes: the account's version does on each edit.
  defp version(account), do: :erlang.phash2(account["version"])
end
