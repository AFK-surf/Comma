# Recreates the standard dev tenants against the RUNNING dev node (comma@<host>).
# Invoked by the reset-dev-db skill:
#
#   elixir --sname resetup_$RANDOM --cookie comma-dev-cookie .claude/skills/reset-dev-db/resetup.exs
#
# All work happens via :erpc on the dev node; this script needs no mix deps.
# The LLM template credentials are read from ~/.pi/agent/models.json (volces-ark
# provider) at runtime — never hardcode them here, this file is committed.

{:ok, host} = :inet.gethostname()
node = String.to_atom("comma@" <> to_string(host))
call = fn mod, fun, args -> :erpc.call(node, mod, fun, args, 60_000) end

%{"providers" => %{"volces-ark" => prov}} =
  :json.decode(File.read!(Path.expand("~/.pi/agent/models.json")))

[model | _] = prov["models"]

# ---- 1. Templates first (create-once: tenant bootstrap must land on these) ----
base_tpl = %{
  "name" => model["name"],
  "model" => model["id"],
  "provider" => "openai",
  "max_tokens" => 16384,
  "provider_config" => %{
    "protocol" => "chat_completions",
    "base_url" => prov["baseUrl"],
    "api_key" => prov["apiKey"]
  }
}

for tpl_id <- ["default", "seed-2-1"] do
  case call.(SalixAgent.Templates, :create, [Map.put(base_tpl, "template_id", tpl_id)]) do
    {:ok, _} -> IO.puts("template #{tpl_id}: created")
    {:error, :exists} ->
      {:ok, _} = call.(SalixAgent.Templates, :update, [tpl_id, base_tpl])
      IO.puts("template #{tpl_id}: updated")
    other -> IO.puts("template #{tpl_id}: FAILED #{inspect(other)}")
  end
end

# ---- 2. Billing catalog ----
for {version, credits, policy} <- [
      {"2026-06", 800, %{}},
      {"2026-07-unlimited", 0, %{"usage_credits" => %{"mode" => "unlimited_metered"}}}
    ] do
  case call.(BillingCommerce.PackageCatalog, :create_package, [
         %{code: "bridge_contract_phase8", surface: "bridge", name: "bridge_contract_phase8"}
       ]) do
    {:ok, _} -> :ok
    {:error, _} -> :ok
  end

  case call.(BillingCommerce.PackageCatalog, :create_package_version, [
         %{
           package_code: "bridge_contract_phase8", version: version, surface: "bridge",
           kind: "manual", billing_period: "month", grant_credits: credits,
           grant_period: "current_period", currency: "usd", amount_minor: 0,
           usage_policy: policy, effective_at: ~U[2026-06-01 00:00:00Z], status: "active"
         }
       ]) do
    {:ok, _} -> IO.puts("package version #{version}: created")
    {:error, reason} -> IO.puts("package version #{version}: #{inspect(reason)}")
  end
end

# ---- 3. Orgs via invite redemption (user + org + owner membership) ----
orgs =
  for {slug, name, email, user_name} <- [
        {"afk-ai", "AFK AI", "owner@example.com", "Heyang Zhou"},
        {"test-1", "Test 1", "member@example.com", "zanweiguo"},
        {"board-demo", "Board Demo", "demo@comma.local", "Demo"}
      ] do
    {:ok, %{code: code}} =
      call.(BridgeForTeams.OrgCreationInvites, :create_invite_code, [
        %{org_name: name, org_slug: slug, note: "dev re-setup"}
      ])

    {:ok, %{org: org, user: user}} =
      call.(BridgeForTeams.OrgCreationInvites, :redeem_invite_code, [
        code,
        %{email: email, name: user_name},
        []
      ])

    IO.puts("org #{slug}: created, owner #{email}")
    {slug, org, user}
  end

# ---- 4. Org template settings (before swarm creation so routers snapshot it) ----
for {slug, _org, _user} <- orgs, slug in ["afk-ai", "test-1"] do
  {:ok, _} =
    call.(BridgeForTeams.Orgs, :update_org, [
      call.(BridgeForTeams.Repo, :get_by!, [BridgeForTeams.Schema.Organization, [slug: slug]]),
      %{"allowed_template_ids" => ["seed-2-1"], "default_template_id" => "seed-2-1"}
    ])

  IO.puts("org #{slug}: template seed-2-1 allowed + default")
end

# ---- 5. Billing grants ----
month = Calendar.strftime(Date.utc_today(), "%Y-%m")

for {slug, org, _user} <- orgs do
  {:ok, _} =
    call.(BridgeForTeams.Billing, :issue_manual_contract_grant, [
      org.id,
      %{
        package_code: "bridge_contract_phase8", package_version: "2026-06",
        valid_from: DateTime.utc_now(), expires_at: DateTime.add(DateTime.utc_now(), 90, :day),
        source_id: "dev_resetup", source_event_id: "dev_resetup_#{slug}_#{month}",
        idempotency_key: "dev-resetup:#{org.id}:#{month}",
        operator: %{id: "local_dev", reason: "dev re-setup credits"}
      }
    ])

  IO.puts("org #{slug}: 800-credit grant")
end

for {slug, org, _user} <- orgs, slug in ["afk-ai", "test-1"] do
  {:ok, _} =
    call.(BridgeForTeams.Billing, :issue_manual_contract_grant, [
      org.id,
      %{
        package_code: "bridge_contract_phase8", package_version: "2026-07-unlimited",
        valid_from: DateTime.utc_now(), expires_at: DateTime.add(DateTime.utc_now(), 365, :day),
        source_id: "dev_unlimited", source_event_id: "dev_unlimited_#{slug}",
        idempotency_key: "dev-unlimited:#{org.id}",
        operator: %{id: "local_dev", reason: "dev unlimited credits"}
      }
    ])

  IO.puts("org #{slug}: unlimited grant")
end

# ---- 6. Swarms (creator = owner, so owner-first default binding resolves) ----
projects =
  for {slug, org, user, pname, pslug} <- [
        {"afk-ai", elem(Enum.at(orgs, 0), 1), elem(Enum.at(orgs, 0), 2), "AFK AI", "afk-ai"},
        {"test-1", elem(Enum.at(orgs, 1), 1), elem(Enum.at(orgs, 1), 2), "zanweibotbot", "zanweibotbot"},
        {"board-demo", elem(Enum.at(orgs, 2), 1), elem(Enum.at(orgs, 2), 2), "Demo Swarm", "demo-swarm"}
      ] do
    {:ok, project} =
      call.(BridgeForTeams.Projects, :create_project, [
        org.id,
        %{"name" => pname, "slug" => pslug},
        [creator_user_id: user.id]
      ])

    IO.puts("swarm #{slug}/#{pname}: created (#{project.salix_group_id})")
    {slug, project}
  end

# ---- 7. Wait for router provisioning, then verify ----
for {slug, project} <- projects do
  agent =
    Enum.reduce_while(1..30, nil, fn _i, _acc ->
      agents = call.(BridgeForTeams.Agents, :list_agents, [project.id])

      case Enum.find(agents, &is_binary(&1.salix_agent_id)) do
        nil -> Process.sleep(2_000) && {:cont, nil}
        found -> {:halt, found}
      end
    end)

  case agent do
    %{salix_agent_id: sid} -> IO.puts("router #{slug}: #{sid} template=#{agent.template_id}")
    nil -> IO.puts("router #{slug}: NOT provisioned after 60s")
  end
end

# ---- 8. Fee-control verification ----
for {slug, _org, _user} <- orgs do
  fresh = call.(BridgeForTeams.Repo, :get_by!, [BridgeForTeams.Schema.Organization, [slug: slug]])

  {:ok, decision} =
    call.(BillingCore.FeeControl, :authorize, [
      %{
        billing_account_id: fresh.billing_account_id, mode: :enforce,
        resource_kind: :storage, action: :write, provider: "salix_store",
        sku: "storage_write", estimated_credits: 1_000_000,
        policy_cache_version: System.unique_integer([:positive])
      }
    ])

  IO.puts("fee-control #{slug}: allowed=#{decision.allowed?} reason=#{decision.reason}")
end

IO.puts("re-setup complete")
