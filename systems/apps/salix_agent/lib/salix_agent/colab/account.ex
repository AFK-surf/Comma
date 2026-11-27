defmodule SalixAgent.Colab.Account do
  @moduledoc """
  Single-authority PostgreSQL lifecycle management for Google Colab Plugin accounts,
  group install convergence state, lock-outside-HTTP two-step OAuth attempts,
  cross-node token refresh, disconnect draining, and scope retirement.

  Tables owned:
  - `colab_accounts`
  - `colab_group_install_states`
  - `colab_oauth_attempts`
  - `colab_retired_scopes`

  Lock hierarchy (strictly ordered to prevent deadlocks under Read Committed):
  1. Tenant lock (`pg_advisory_xact_lock_shared` for group ops; `pg_advisory_xact_lock`
     for `retire_tenant`) on `hashtextextended('colab_tenant:' || tenant_id, 0)`.
  2. Group lock (`pg_advisory_xact_lock`) on
     `hashtextextended('colab_group:' || tenant_id || ':' || group_id, 0)`.

  Google `/revoke` is NEVER called on disconnect or reconnect because Colab uses
  Google's shared Colab CLI OAuth client (`764086051850-...`).
  """

  alias SalixAgent.CapabilityRequests
  alias SalixAgent.Colab.{Auth, Client, Leases, Reaper}
  alias SalixStore.Repo

  @default_alias "google-colab"
  @attempt_ttl_seconds 600
  @exchanging_lease_seconds 60
  @refresh_lead_seconds 120
  @refresh_claim_ttl_seconds 30
  @reconnect_refresh_wait_attempts 20
  @reconnect_refresh_wait_ms 50
  @ccu_probe_timeout_ms 5_000
  @attempt_delete_grace_seconds 3_600
  @draining_stale_seconds 15 * 60
  @max_inline_drain_leases 6
  @stopping_reap_seconds 60

  @credential_key "GOOGLE_COLAB_AUTH_CODE"
  @credential_label "Authorization code"
  @credential_format "oauth_code"

  @account_columns """
  binding_id, tenant_id, group_id, alias, google_sub, email,
  credentials_ciphertext, credential_revision, refresh_claim_id,
  refresh_claim_expires_at, status, state, delete_token, delete_started_at,
  ccu_balance, ccu_rate_hourly, eligible_gpus, ccu_observed_at,
  created_at, updated_at, reconnect_revision
  """

  @attempt_columns """
  attempt_id, tenant_id, group_id, initiator_user_id, operation,
  target_binding_id, target_alias, expected_revision, state_token,
  code_verifier, redirect_uri, status, exchange_claim_id,
  exchanging_started_at, exchanged_ciphertext, result_binding_id,
  result_generation, expires_at, created_at, updated_at,
  expected_reconnect_revision
  """

  # ============================================================================
  # §1.1 OAuth Two-Step Attempt API (Lock-Outside-HTTP)
  # ============================================================================

  @doc """
  Start a two-step PKCE S256 OAuth attempt (`:install` or `:reconnect`) for
  `(tenant_id, group_id)` with 600s TTL.
  """
  @spec start_oauth_attempt(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_oauth_attempt(tenant_id, group_id, initiator_user_id, opts \\ [])

  def start_oauth_attempt(tenant_id, group_id, initiator_user_id, opts)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" and
             is_binary(initiator_user_id) and initiator_user_id != "" and is_list(opts) do
    operation = normalize_operation(Keyword.get(opts, :operation, :install))
    target_alias = clean_string(Keyword.get(opts, :alias)) || @default_alias
    mode = clean_string(Keyword.get(opts, :mode))
    requested_binding_id = clean_string(Keyword.get(opts, :binding_id))
    now = SystemsClock.utc_now()

    with :ok <- ensure_scope_not_retired(tenant_id, group_id),
         {:ok, target_info} <-
           resolve_attempt_target(
             tenant_id,
             group_id,
             operation,
             requested_binding_id,
             mode,
             target_alias,
             now
           ),
         {:ok, %{url: url, state: state, code_verifier: verifier}} <-
           Auth.begin(login_hint: target_info.login_hint) do
      attempt_id = "colab_att_" <> random_id()
      redirect_uri = Auth.redirect_uri()
      expires_at = DateTime.add(now, @attempt_ttl_seconds, :second)

      case query(
             """
             INSERT INTO colab_oauth_attempts (
               attempt_id, tenant_id, group_id, initiator_user_id, operation,
               target_binding_id, target_alias, expected_revision, state_token,
               code_verifier, redirect_uri, status, expires_at, created_at, updated_at,
               expected_reconnect_revision
             ) VALUES (
               $1, $2, $3, $4, $5,
               $6, $7, $8, $9,
               $10, $11, 'pending', $12, $13, $13,
               $14
             )
             """,
             [
               attempt_id,
               tenant_id,
               group_id,
               initiator_user_id,
               operation,
               target_info.binding_id,
               target_info.alias,
               target_info.expected_revision,
               state,
               verifier,
               redirect_uri,
               expires_at,
               now,
               target_info.expected_reconnect_revision
             ]
           ) do
        {:ok, _} ->
          {:ok,
           %{
             attempt_id: attempt_id,
             authorize_url: url,
             key: @credential_key,
             label: @credential_label,
             format: @credential_format,
             binding_id: target_info.binding_id
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def start_oauth_attempt(_, _, _, _), do: {:error, :invalid_input}

  @doc """
  Complete a two-step PKCE OAuth attempt.

  - Pre-validates pasted input before claiming the attempt (malformed input or
    mismatched `state` returns `{:error, :plugin_credential_rejected}` without
    burning the attempt).
  - Claims the attempt with a unique `exchange_claim_id` (60s lease) before
    calling Google's token endpoint outside any DB transaction.
  - Immediately stages exchanged credentials via a claim-fenced CAS before
    probing `/tun/m/ccu-info`.
  - Commits atomically under `tenant SHARED -> group EXCLUSIVE`, re-reading the
    attempt `FOR UPDATE`.
  - `sync_plugin_state: false` (Bridge for Teams) records the install generation as
    already plugin-synced, so `ColabInstallReconciler` does not queue the group.
  """
  @spec complete_oauth_attempt(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()}
          | {:retry_with_fresh_attempt, map(), atom()}
          | {:error, term()}
  def complete_oauth_attempt(
        tenant_id,
        group_id,
        initiator_user_id,
        attempt_id,
        pasted_input,
        opts \\ []
      )

  def complete_oauth_attempt(
        tenant_id,
        group_id,
        initiator_user_id,
        attempt_id,
        pasted_input,
        opts
      )
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" and
             is_binary(initiator_user_id) and initiator_user_id != "" and is_binary(attempt_id) and
             is_list(opts) do
    operation = normalize_operation(Keyword.get(opts, :operation, :install))
    requested_binding_id = clean_string(Keyword.get(opts, :binding_id))
    now = SystemsClock.utc_now()

    case fetch_attempt(attempt_id) do
      {:ok, nil} ->
        retry_fresh(tenant_id, group_id, initiator_user_id, opts, :attempt_expired)

      {:ok, attempt} ->
        cond do
          not attempt_matches_caller?(
            attempt,
            tenant_id,
            group_id,
            initiator_user_id,
            operation,
            requested_binding_id
          ) ->
            retry_fresh(tenant_id, group_id, initiator_user_id, opts, :attempt_expired)

          attempt.status == "completed" ->
            {:ok, completed_receipt(tenant_id, group_id, attempt, true)}

          attempt.status == "exchanged" ->
            resume_exchanged_attempt(tenant_id, group_id, initiator_user_id, attempt, opts, now)

          attempt.status == "exchanging" ->
            handle_exchanging_attempt(tenant_id, group_id, initiator_user_id, attempt, opts, now)

          attempt.status == "failed" or expired_at?(attempt.expires_at, now) ->
            retry_fresh(tenant_id, group_id, initiator_user_id, opts, :attempt_expired)

          attempt.status == "pending" ->
            run_pending_attempt(
              tenant_id,
              group_id,
              initiator_user_id,
              attempt,
              pasted_input,
              opts,
              now
            )

          true ->
            retry_fresh(tenant_id, group_id, initiator_user_id, opts, :attempt_expired)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def complete_oauth_attempt(_, _, _, _, _, _), do: {:error, :plugin_credential_rejected}

  # ---- Attempt step helpers ----

  defp resolve_attempt_target(
         tenant_id,
         group_id,
         "install",
         _binding_id,
         mode,
         target_alias,
         _now
       ) do
    if mode == "add_account" do
      case count_non_retired_accounts(tenant_id, group_id) do
        {:ok, count} when count > 0 ->
          {:error, :single_account_limit_reached}

        {:ok, 0} ->
          {:ok,
           %{
             binding_id: nil,
             alias: target_alias,
             expected_revision: nil,
             expected_reconnect_revision: nil,
             login_hint: nil
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok,
       %{
         binding_id: nil,
         alias: target_alias,
         expected_revision: nil,
         expected_reconnect_revision: nil,
         login_hint: nil
       }}
    end
  end

  defp resolve_attempt_target(tenant_id, group_id, "reconnect", binding_id, _mode, _alias, _now) do
    lookup =
      if is_binary(binding_id) do
        get_non_retired_account(tenant_id, group_id, binding_id)
      else
        get_sole_non_retired_account(tenant_id, group_id)
      end

    case lookup do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, %{state: "draining"}} ->
        {:error, :colab_account_draining}

      {:ok, %{state: "active"} = account} ->
        {:ok,
         %{
           binding_id: account.binding_id,
           alias: account.alias,
           expected_revision: account.credential_revision,
           expected_reconnect_revision: account.reconnect_revision,
           login_hint: account.email
         }}

      {:ok, _} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_exchanging_attempt(tenant_id, group_id, initiator_user_id, attempt, opts, now) do
    stale_cutoff = DateTime.add(now, -@exchanging_lease_seconds, :second)

    if is_struct(attempt.exchanging_started_at, DateTime) and
         DateTime.compare(attempt.exchanging_started_at, stale_cutoff) == :gt do
      {:error, :oauth_exchange_in_progress}
    else
      # Atomically fail ONLY the matching stale exchanging claim.
      _ =
        query(
          """
          UPDATE colab_oauth_attempts
          SET status = 'failed',
              exchange_claim_id = NULL,
              exchanged_ciphertext = NULL,
              updated_at = $2
          WHERE attempt_id = $1
            AND status = 'exchanging'
            AND (exchanging_started_at IS NULL OR exchanging_started_at <= $3)
          """,
          [attempt.attempt_id, now, stale_cutoff]
        )

      retry_fresh(tenant_id, group_id, initiator_user_id, opts, :exchange_timed_out)
    end
  end

  defp run_pending_attempt(
         tenant_id,
         group_id,
         initiator_user_id,
         attempt,
         pasted_input,
         opts,
         now
       ) do
    # Step 2: Pre-claim validation (no DB write, attempt stays 'pending')
    case Auth.parse_authorization_input(pasted_input, expected_state: attempt.state_token) do
      {:error, _reason} ->
        {:error, :plugin_credential_rejected}

      {:ok, %{code: code}} ->
        # Step 3: Short DB tx — claim attempt with unique exchange_claim_id
        claim_id = random_id()

        case query(
               """
               UPDATE colab_oauth_attempts
               SET status = 'exchanging',
                   exchange_claim_id = $2,
                   exchanging_started_at = $3,
                   updated_at = $3
               WHERE attempt_id = $1
                 AND status = 'pending'
                 AND expires_at > $3
               RETURNING attempt_id
               """,
               [attempt.attempt_id, claim_id, now]
             ) do
          {:ok, %{rows: [[_]]}} ->
            exchange_and_stage(
              tenant_id,
              group_id,
              initiator_user_id,
              attempt,
              claim_id,
              code,
              opts
            )

          {:ok, %{rows: []}} ->
            # Lost CAS race: re-read and handle per Step 1
            rehandle_after_claim_miss(
              tenant_id,
              group_id,
              initiator_user_id,
              attempt.attempt_id,
              opts
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp rehandle_after_claim_miss(tenant_id, group_id, initiator_user_id, attempt_id, opts) do
    now = SystemsClock.utc_now()

    case fetch_attempt(attempt_id) do
      {:ok, %{status: "completed"} = attempt} ->
        {:ok, completed_receipt(tenant_id, group_id, attempt, true)}

      {:ok, %{status: "exchanged"} = attempt} ->
        resume_exchanged_attempt(tenant_id, group_id, initiator_user_id, attempt, opts, now)

      {:ok, %{status: "exchanging"} = attempt} ->
        handle_exchanging_attempt(tenant_id, group_id, initiator_user_id, attempt, opts, now)

      {:ok, _} ->
        retry_fresh(tenant_id, group_id, initiator_user_id, opts, :attempt_expired)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exchange_and_stage(
         tenant_id,
         group_id,
         initiator_user_id,
         attempt,
         claim_id,
         code,
         opts
       ) do
    # Step 4: Outside DB tx — exchange code with Google
    case Auth.exchange_code(code, attempt.code_verifier, redirect_uri: attempt.redirect_uri) do
      {:ok, token_data} ->
        with :ok <- validate_exchanged_token_data(tenant_id, group_id, attempt, token_data),
             {:ok, staged_ct} <-
               seal_payload(tenant_id, group_id, attempt.attempt_id, token_data) do
          # Claim-fenced IMMEDIATE stage tx BEFORE /tun/m/ccu-info
          stage_now = SystemsClock.utc_now()

          case query(
                 """
                 UPDATE colab_oauth_attempts
                 SET status = 'exchanged',
                     exchanged_ciphertext = $3,
                     exchange_claim_id = NULL,
                     updated_at = $4
                 WHERE attempt_id = $1
                   AND status = 'exchanging'
                   AND exchange_claim_id = $2
                   AND expires_at > $4
                 RETURNING attempt_id
                 """,
                 [attempt.attempt_id, claim_id, staged_ct, stage_now]
               ) do
            {:ok, %{rows: [[_]]}} ->
              # Proceed to Step 5 (/tun/m/ccu-info) -> Step 6 commit
              step5_ccu_and_commit(
                tenant_id,
                group_id,
                initiator_user_id,
                attempt,
                token_data,
                opts
              )

            {:ok, %{rows: []}} ->
              # Attempt was invalidated/cancelled/timed out while Google HTTP was in flight
              {:error, :attempt_invalidated}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, {:wrong_google_account, expected_email}} ->
            fail_exchanging_claim(attempt.attempt_id, claim_id)
            {:error, {:wrong_google_account, expected_email}}

          {:error, :missing_refresh_token} ->
            fail_exchanging_claim(attempt.attempt_id, claim_id)
            retry_fresh(tenant_id, group_id, initiator_user_id, opts, :missing_refresh_token)

          {:error, reason} ->
            fail_exchanging_claim(attempt.attempt_id, claim_id)
            {:error, reason}
        end

      {:error, :platform_unavailable} ->
        fail_exchanging_claim(attempt.attempt_id, claim_id)
        {:error, :platform_unavailable}

      {:error, reason} ->
        fail_exchanging_claim(attempt.attempt_id, claim_id)
        retry_fresh(tenant_id, group_id, initiator_user_id, opts, reason)
    end
  end

  defp validate_exchanged_token_data(_tenant_id, _group_id, %{operation: "install"}, token_data) do
    case clean_string(token_data["refresh_token"]) do
      nil -> {:error, :missing_refresh_token}
      _ -> :ok
    end
  end

  defp validate_exchanged_token_data(
         tenant_id,
         group_id,
         %{operation: "reconnect", target_binding_id: binding_id},
         token_data
       ) do
    incoming_sub = clean_string(token_data["google_sub"])

    case get_non_retired_account(tenant_id, group_id, binding_id) do
      {:ok, %{google_sub: expected_sub, email: expected_email}} ->
        if is_binary(incoming_sub) and incoming_sub == expected_sub do
          :ok
        else
          {:error, {:wrong_google_account, expected_email}}
        end

      {:ok, nil} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_exchanged_attempt(tenant_id, group_id, initiator_user_id, attempt, opts, now) do
    if expired_at?(attempt.expires_at, now) or not is_binary(attempt.exchanged_ciphertext) do
      _ =
        query(
          """
          UPDATE colab_oauth_attempts
          SET status = 'failed', exchanged_ciphertext = NULL, updated_at = $2
          WHERE attempt_id = $1 AND status = 'exchanged'
          """,
          [attempt.attempt_id, now]
        )

      retry_fresh(tenant_id, group_id, initiator_user_id, opts, :attempt_expired)
    else
      case open_payload(tenant_id, group_id, attempt.attempt_id, attempt.exchanged_ciphertext) do
        {:ok, token_data} ->
          step5_ccu_and_commit(
            tenant_id,
            group_id,
            initiator_user_id,
            attempt,
            token_data,
            opts
          )

        {:error, _} ->
          retry_fresh(tenant_id, group_id, initiator_user_id, opts, :attempt_expired)
      end
    end
  end

  defp step5_ccu_and_commit(tenant_id, group_id, initiator_user_id, attempt, token_data, opts) do
    # Step 5: Outside DB tx — probe /tun/m/ccu-info
    observed_at = SystemsClock.utc_now()

    case Client.ccu_info(token_data["access_token"], receive_timeout: @ccu_probe_timeout_ms) do
      {:ok, %{} = info} ->
        ccu = extract_ccu(info, observed_at)
        step6_commit_attempt(tenant_id, group_id, attempt, token_data, ccu, opts)

      {:error, {:http_error, status, _}} when status in [401, 403] ->
        fail_now = SystemsClock.utc_now()

        case query(
               """
               UPDATE colab_oauth_attempts
               SET status = 'failed',
                   exchanged_ciphertext = NULL,
                   updated_at = $2
               WHERE attempt_id = $1 AND status = 'exchanged'
               RETURNING attempt_id
               """,
               [attempt.attempt_id, fail_now]
             ) do
          {:ok, %{rows: [[_]]}} ->
            retry_fresh(tenant_id, group_id, initiator_user_id, opts, :colab_not_eligible)

          {:ok, %{rows: []}} ->
            # 0-row re-read: another concurrent recovery worker may have moved it to 'completed'
            case fetch_attempt(attempt.attempt_id) do
              {:ok, %{status: "completed"} = winning} ->
                {:ok, completed_receipt(tenant_id, group_id, winning, true)}

              _ ->
                {:error, :attempt_invalidated}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _transient_error ->
        # 5xx / timeout / transport error -> proceed with ccu_balance: nil
        ccu = %{ccu_balance: nil, ccu_rate_hourly: nil, eligible_gpus: nil, ccu_observed_at: nil}
        step6_commit_attempt(tenant_id, group_id, attempt, token_data, ccu, opts)
    end
  end

  defp step6_commit_attempt(
         tenant_id,
         group_id,
         attempt,
         token_data,
         ccu,
         opts,
         wait_attempts \\ @reconnect_refresh_wait_attempts
       ) do
    now = SystemsClock.utc_now()

    tx_result =
      Repo.transaction(fn ->
        with :ok <- set_lock_timeout(),
             :ok <- lock_tenant_shared(tenant_id),
             :ok <- lock_group_exclusive(tenant_id, group_id),
             {:ok, locked_attempt} <- lock_attempt_for_update(attempt.attempt_id) do
          cond do
            is_nil(locked_attempt) ->
              {:error, :attempt_invalidated}

            locked_attempt.status == "completed" ->
              {:ok, completed_receipt(tenant_id, group_id, locked_attempt, true)}

            locked_attempt.status != "exchanged" or expired_at?(locked_attempt.expires_at, now) ->
              _ = fail_attempt_in_tx(locked_attempt.attempt_id, now)
              {:error, :attempt_invalidated}

            scope_retired_in_tx?(tenant_id, group_id) ->
              _ = fail_attempt_in_tx(locked_attempt.attempt_id, now)
              {:error, :scope_retired}

            locked_attempt.operation == "install" ->
              commit_install_in_tx(
                tenant_id,
                group_id,
                locked_attempt,
                token_data,
                ccu,
                now,
                sync_plugin_state?(opts)
              )

            locked_attempt.operation == "reconnect" ->
              commit_reconnect_in_tx(
                tenant_id,
                group_id,
                locked_attempt,
                token_data,
                ccu,
                now,
                wait_attempts
              )

            true ->
              _ = fail_attempt_in_tx(locked_attempt.attempt_id, now)
              {:error, :attempt_invalidated}
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case tx_result do
      {:ok, :wait_refresh_claim} ->
        SystemsClock.sleep(@reconnect_refresh_wait_ms)

        step6_commit_attempt(
          tenant_id,
          group_id,
          attempt,
          token_data,
          ccu,
          opts,
          wait_attempts - 1
        )

      {:ok, {:ok, receipt}} ->
        # Step 7: Post-commit outside tx — kick Reaper on reconnect
        if attempt.operation == "reconnect" do
          kick_reaper_async()
        end

        {:ok, receipt}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit_install_in_tx(tenant_id, group_id, attempt, token_data, ccu, now, sync?) do
    google_sub = clean_string(token_data["google_sub"])
    email = clean_string(token_data["email"])

    with {:ok, count} <- count_non_retired_accounts(tenant_id, group_id) do
      if count > 0 do
        _ = fail_attempt_in_tx(attempt.attempt_id, now)
        {:error, :already_connected}
      else
        binding_id = "colab_acc_" <> random_id()
        creds = reject_nil_values(token_data) |> Map.put("google_sub", google_sub)

        with {:ok, ciphertext} <- seal_payload(tenant_id, group_id, binding_id, creds),
             {:ok, _} <-
               query(
                 """
                 INSERT INTO colab_accounts (
                   binding_id, tenant_id, group_id, alias, google_sub, email,
                   credentials_ciphertext, credential_revision, status, state,
                   ccu_balance, ccu_rate_hourly, eligible_gpus, ccu_observed_at,
                   created_at, updated_at
                 ) VALUES (
                   $1, $2, $3, $4, $5, $6,
                   $7, 1, 'ok', 'active',
                   $8, $9, $10, $11,
                   $12, $12
                 )
                 """,
                 [
                   binding_id,
                   tenant_id,
                   group_id,
                   attempt.target_alias,
                   google_sub,
                   email,
                   ciphertext,
                   ccu.ccu_balance,
                   ccu.ccu_rate_hourly,
                   ccu.eligible_gpus,
                   ccu.ccu_observed_at,
                   now
                 ]
               ),
             {:ok, gen} <-
               upsert_group_install_state_in_tx(
                 tenant_id,
                 group_id,
                 "installed",
                 binding_id,
                 now,
                 sync?
               ),
             {:ok, _} <-
               complete_attempt_in_tx(attempt.attempt_id, binding_id, gen, now) do
          {:ok,
           %{
             binding_id: binding_id,
             generation: gen,
             email: email,
             already_completed: false
           }}
        else
          {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
            _ = fail_attempt_in_tx(attempt.attempt_id, now)
            {:error, :already_connected}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end
    end
  end

  defp commit_reconnect_in_tx(
         tenant_id,
         group_id,
         attempt,
         token_data,
         ccu,
         now,
         wait_attempts
       ) do
    binding_id = attempt.target_binding_id
    incoming_sub = clean_string(token_data["google_sub"])
    incoming_refresh_token = clean_string(token_data["refresh_token"])

    case query(
           """
           SELECT #{@account_columns}
           FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND binding_id = $3
           FOR UPDATE
           """,
           [tenant_id, group_id, binding_id]
         ) do
      {:ok, %{rows: [row]}} ->
        account = decode_account(row)

        cond do
          account.state != "active" ->
            _ = fail_attempt_in_tx(attempt.attempt_id, now)
            {:error, :conflict}

          account.google_sub != incoming_sub ->
            _ = fail_attempt_in_tx(attempt.attempt_id, now)
            {:error, {:wrong_google_account, account.email}}

          is_nil(incoming_refresh_token) and refresh_claim_active?(account, now) ->
            if wait_attempts > 0 do
              :wait_refresh_claim
            else
              _ = fail_attempt_in_tx(attempt.attempt_id, now)
              {:error, :conflict}
            end

          true ->
            existing_creds =
              case open_payload(tenant_id, group_id, binding_id, account.credentials_ciphertext) do
                {:ok, %{} = c} -> c
                _ -> %{}
              end

            refresh_token =
              incoming_refresh_token || clean_string(existing_creds["refresh_token"])

            if is_nil(refresh_token) do
              _ = fail_attempt_in_tx(attempt.attempt_id, now)
              {:error, :invalid_input}
            else
              merged_creds =
                existing_creds
                |> Map.merge(reject_nil_values(token_data))
                |> Map.put("refresh_token", refresh_token)
                |> Map.put("google_sub", incoming_sub)

              new_email = clean_string(merged_creds["email"]) || account.email

              with {:ok, ciphertext} <-
                     seal_payload(tenant_id, group_id, binding_id, merged_creds),
                   {:ok, %{rows: [[_]]}} <-
                     update_reconnected_account_in_tx(
                       tenant_id,
                       group_id,
                       binding_id,
                       incoming_sub,
                       attempt,
                       is_binary(incoming_refresh_token),
                       ciphertext,
                       new_email,
                       ccu,
                       now
                     ),
                   {:ok, install_state} <- get_group_install_state(tenant_id, group_id),
                   gen = if(install_state, do: install_state.generation, else: nil),
                   {:ok, _} <- complete_attempt_in_tx(attempt.attempt_id, binding_id, gen, now) do
                {:ok,
                 %{
                   binding_id: binding_id,
                   generation: gen,
                   email: new_email,
                   already_completed: false
                 }}
              else
                {:ok, %{rows: []}} ->
                  _ = fail_attempt_in_tx(attempt.attempt_id, now)
                  {:error, :conflict}

                {:error, reason} ->
                  Repo.rollback(reason)
              end
            end
        end

      {:ok, %{rows: []}} ->
        _ = fail_attempt_in_tx(attempt.attempt_id, now)
        {:error, :conflict}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Reconnect concurrency: `reconnect_revision` advances only on a committed user
  # reconnect, `credential_revision` on every credential write (reconnect or
  # background refresh). A reconnect with a new refresh_token fences only on
  # `reconnect_revision`, so concurrent user reconnects are mutually exclusive while
  # a background refresh cannot reject it. A reconnect without a new refresh_token
  # reuses the stored one, so it also fences on `credential_revision` and must not
  # overwrite a rotation that happened after the attempt started.
  defp update_reconnected_account_in_tx(
         tenant_id,
         group_id,
         binding_id,
         incoming_sub,
         attempt,
         true,
         ciphertext,
         new_email,
         ccu,
         now
       ) do
    query(
      """
      UPDATE colab_accounts
      SET credentials_ciphertext = $5,
          credential_revision = credential_revision + 1,
          reconnect_revision = reconnect_revision + 1,
          status = 'ok',
          email = COALESCE($6, email),
          refresh_claim_id = NULL,
          refresh_claim_expires_at = NULL,
          ccu_balance = COALESCE($7, ccu_balance),
          ccu_rate_hourly = COALESCE($8, ccu_rate_hourly),
          eligible_gpus = COALESCE($9, eligible_gpus),
          ccu_observed_at = COALESCE($10, ccu_observed_at),
          updated_at = $11
      WHERE tenant_id = $1
        AND group_id = $2
        AND binding_id = $3
        AND state = 'active'
        AND google_sub = $4
        AND reconnect_revision = $12
      RETURNING binding_id
      """,
      [
        tenant_id,
        group_id,
        binding_id,
        incoming_sub,
        ciphertext,
        new_email,
        ccu.ccu_balance,
        ccu.ccu_rate_hourly,
        ccu.eligible_gpus,
        ccu.ccu_observed_at,
        now,
        attempt.expected_reconnect_revision
      ]
    )
  end

  defp update_reconnected_account_in_tx(
         tenant_id,
         group_id,
         binding_id,
         incoming_sub,
         attempt,
         false,
         ciphertext,
         new_email,
         ccu,
         now
       ) do
    query(
      """
      UPDATE colab_accounts
      SET credentials_ciphertext = $6,
          credential_revision = credential_revision + 1,
          reconnect_revision = reconnect_revision + 1,
          status = 'ok',
          email = COALESCE($7, email),
          refresh_claim_id = NULL,
          refresh_claim_expires_at = NULL,
          ccu_balance = COALESCE($8, ccu_balance),
          ccu_rate_hourly = COALESCE($9, ccu_rate_hourly),
          eligible_gpus = COALESCE($10, eligible_gpus),
          ccu_observed_at = COALESCE($11, ccu_observed_at),
          updated_at = $12
      WHERE tenant_id = $1
        AND group_id = $2
        AND binding_id = $3
        AND state = 'active'
        AND google_sub = $4
        AND credential_revision = $5
        AND reconnect_revision = $13
        AND (refresh_claim_id IS NULL OR refresh_claim_expires_at <= $12)
      RETURNING binding_id
      """,
      [
        tenant_id,
        group_id,
        binding_id,
        incoming_sub,
        attempt.expected_revision,
        ciphertext,
        new_email,
        ccu.ccu_balance,
        ccu.ccu_rate_hourly,
        ccu.eligible_gpus,
        ccu.ccu_observed_at,
        now,
        attempt.expected_reconnect_revision
      ]
    )
  end

  defp retry_fresh(tenant_id, group_id, initiator_user_id, opts, reason) do
    case start_oauth_attempt(tenant_id, group_id, initiator_user_id, opts) do
      {:ok, fresh_config} -> {:retry_with_fresh_attempt, fresh_config, reason}
      {:error, err} -> {:error, err}
    end
  end

  defp fail_exchanging_claim(attempt_id, claim_id) do
    now = SystemsClock.utc_now()

    _ =
      query(
        """
        UPDATE colab_oauth_attempts
        SET status = 'failed',
            exchange_claim_id = NULL,
            exchanged_ciphertext = NULL,
            updated_at = $3
        WHERE attempt_id = $1
          AND status = 'exchanging'
          AND exchange_claim_id = $2
        """,
        [attempt_id, claim_id, now]
      )

    :ok
  end

  defp fail_attempt_in_tx(attempt_id, now) do
    query(
      """
      UPDATE colab_oauth_attempts
      SET status = 'failed',
          exchange_claim_id = NULL,
          exchanged_ciphertext = NULL,
          updated_at = $2
      WHERE attempt_id = $1
      """,
      [attempt_id, now]
    )
  end

  defp complete_attempt_in_tx(attempt_id, binding_id, generation, now) do
    query(
      """
      UPDATE colab_oauth_attempts
      SET status = 'completed',
          exchange_claim_id = NULL,
          exchanged_ciphertext = NULL,
          result_binding_id = $2,
          result_generation = $3,
          updated_at = $4
      WHERE attempt_id = $1
      """,
      [attempt_id, binding_id, generation, now]
    )
  end

  defp completed_receipt(tenant_id, group_id, attempt, already_completed?) do
    email =
      case get_account(tenant_id, group_id, attempt.result_binding_id) do
        {:ok, %{email: e}} -> e
        _ -> nil
      end

    %{
      binding_id: attempt.result_binding_id,
      generation: attempt.result_generation,
      email: email,
      already_completed: already_completed?
    }
  end

  # ============================================================================
  # §4.3 Token Refresh: Decoupled Credential Persistence vs Caller Execution Check
  # ============================================================================

  @doc """
  Obtain a fresh Colab access token for `(tenant_id, group_id, binding_id)`.

  Options:
  - `mode: :execute | :cleanup` (default `:execute`)
  - `rejected_revision: integer()` — forces a refresh when `credential_revision <= rejected_revision`
  - `deadline_ms: integer()` — monotonic millisecond deadline bounding HTTP receive_timeout
  - `receive_timeout: pos_integer()` — explicit timeout cap

  Persisting a rotated token is decoupled from caller execution checks:
  if an `:execute` refresh completes right as the account transitions to
  `'draining'` or `'retired'`, the rotated token is still persisted (preserving
  `state` untouched) while `{:error, :account_not_active}` is returned to the caller.
  """
  @spec get_access_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             access_token: String.t(),
             credential_revision: pos_integer(),
             account: map(),
             credentials: map()
           }}
          | {:error, atom()}
  def get_access_token(tenant_id, group_id, binding_id, opts \\ [])
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(binding_id) and
             is_list(opts) do
    mode = Keyword.get(opts, :mode, :execute)
    rejected_revision = Keyword.get(opts, :rejected_revision)
    deadline_ms = Keyword.get(opts, :deadline_ms)

    with :ok <- check_deadline(deadline_ms),
         {:ok, account} <- load_account_for_mode(tenant_id, group_id, binding_id, mode),
         {:ok, creds} <-
           open_payload(tenant_id, group_id, binding_id, account.credentials_ciphertext) do
      now = SystemsClock.utc_now()
      now_unix = DateTime.to_unix(now)
      force? = rejected_revision?(account.credential_revision, rejected_revision)

      cond do
        token_fresh?(creds, now_unix, @refresh_lead_seconds) and not force? ->
          {:ok, token_reply(account, creds)}

        refresh_claim_active?(account, now) ->
          if token_unexpired?(creds, now_unix) and not force? do
            {:ok, token_reply(account, creds)}
          else
            {:error, :refresh_in_progress}
          end

        true ->
          claim_and_refresh_token(tenant_id, group_id, account, creds, mode, opts, now)
      end
    end
  end

  @doc """
  Classify a Colab HTTP error response (`401` vs `403` vs other).
  Non-revocation/quota/rate `403` returns `:forbidden_non_auth` and must NEVER
  poison stored credentials.
  """
  @spec classify_colab_http_error(integer(), term()) ::
          :unauthorized | :auth_revoked | :forbidden_non_auth | :other
  def classify_colab_http_error(401, _body), do: :unauthorized

  def classify_colab_http_error(403, body) do
    text = error_body_text(body) |> String.downcase()

    if String.contains?(text, "access_token_scope_insufficient") or
         String.contains?(text, "insufficientpermissions") or
         String.contains?(text, "insufficient_scope") or
         String.contains?(text, "invalid_grant") or
         String.contains?(text, "token has been expired or revoked") do
      :auth_revoked
    else
      :forbidden_non_auth
    end
  end

  def classify_colab_http_error(_, _), do: :other

  @doc """
  Mark an account `status = 'reauthorization_required'` fenced on
  `(binding_id, credential_revision)` (e.g. after explicit scope revocation 403).
  """
  @spec mark_reauthorization_required(String.t(), String.t(), String.t(), integer()) :: :ok
  def mark_reauthorization_required(tenant_id, group_id, binding_id, expected_revision)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(binding_id) and
             is_integer(expected_revision) do
    now = SystemsClock.utc_now()

    _ =
      query(
        """
        UPDATE colab_accounts
        SET status = 'reauthorization_required',
            updated_at = $5
        WHERE tenant_id = $1
          AND group_id = $2
          AND binding_id = $3
          AND credential_revision = $4
        """,
        [tenant_id, group_id, binding_id, expected_revision, now]
      )

    :ok
  end

  defp claim_and_refresh_token(tenant_id, group_id, account, creds, mode, opts, now) do
    claim_id = random_id()
    claim_expires = DateTime.add(now, @refresh_claim_ttl_seconds, :second)
    allowed_states = allowed_states_for_mode(mode)

    case query(
           """
           UPDATE colab_accounts
           SET refresh_claim_id = $4,
               refresh_claim_expires_at = $5,
               updated_at = $6
           WHERE tenant_id = $1
             AND group_id = $2
             AND binding_id = $3
             AND credential_revision = $7
             AND status = 'ok'
             AND state = ANY($8::text[])
             AND (refresh_claim_expires_at IS NULL OR refresh_claim_expires_at <= $6)
           RETURNING credential_revision
           """,
           [
             tenant_id,
             group_id,
             account.binding_id,
             claim_id,
             claim_expires,
             now,
             account.credential_revision,
             allowed_states
           ]
         ) do
      {:ok, %{rows: [[_]]}} ->
        execute_claimed_refresh(tenant_id, group_id, account, creds, claim_id, mode, opts)

      {:ok, %{rows: []}} ->
        recheck_after_refresh_claim_miss(tenant_id, group_id, account.binding_id, mode, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recheck_after_refresh_claim_miss(tenant_id, group_id, binding_id, mode, opts) do
    rejected_revision = Keyword.get(opts, :rejected_revision)

    with {:ok, current} <- load_account_for_mode(tenant_id, group_id, binding_id, mode),
         {:ok, creds} <-
           open_payload(tenant_id, group_id, binding_id, current.credentials_ciphertext) do
      now = SystemsClock.utc_now()
      now_unix = DateTime.to_unix(now)
      force? = rejected_revision?(current.credential_revision, rejected_revision)

      cond do
        token_fresh?(creds, now_unix, @refresh_lead_seconds) and not force? ->
          {:ok, token_reply(current, creds)}

        refresh_claim_active?(current, now) and token_unexpired?(creds, now_unix) and not force? ->
          {:ok, token_reply(current, creds)}

        true ->
          {:error, :refresh_in_progress}
      end
    end
  end

  defp execute_claimed_refresh(tenant_id, group_id, account, creds, claim_id, mode, opts) do
    refresh_token = clean_string(creds["refresh_token"])
    deadline_ms = Keyword.get(opts, :deadline_ms)

    if is_nil(refresh_token) do
      settle_invalid_grant(
        tenant_id,
        group_id,
        account.binding_id,
        account.credential_revision,
        claim_id
      )

      {:error, :invalid_grant}
    else
      case compute_http_timeout(deadline_ms, Keyword.get(opts, :receive_timeout)) do
        :exhausted ->
          release_refresh_claim(
            tenant_id,
            group_id,
            account.binding_id,
            account.credential_revision,
            claim_id
          )

          {:error, :budget_exhausted}

        {:ok, req_opts} ->
          case Auth.refresh_token(refresh_token, req_opts) do
            {:ok, refreshed} ->
              merged =
                creds
                |> Map.merge(refreshed)
                |> Map.put(
                  "refresh_token",
                  clean_string(refreshed["refresh_token"]) || refresh_token
                )

              persist_rotated_token(
                tenant_id,
                group_id,
                account,
                merged,
                claim_id,
                mode,
                deadline_ms
              )

            {:error, :invalid_grant} ->
              settle_invalid_grant(
                tenant_id,
                group_id,
                account.binding_id,
                account.credential_revision,
                claim_id
              )

              {:error, :invalid_grant}

            {:error, :platform_unavailable} ->
              release_refresh_claim(
                tenant_id,
                group_id,
                account.binding_id,
                account.credential_revision,
                claim_id
              )

              {:error, :platform_unavailable}

            {:error, _transient} ->
              release_refresh_claim(
                tenant_id,
                group_id,
                account.binding_id,
                account.credential_revision,
                claim_id
              )

              {:error, :token_refresh_failed}
          end
      end
    end
  end

  defp persist_rotated_token(tenant_id, group_id, account, merged, claim_id, mode, deadline_ms) do
    now = SystemsClock.utc_now()

    with {:ok, ciphertext} <- seal_payload(tenant_id, group_id, account.binding_id, merged),
         # Step 1 (BOTH :execute and :cleanup): persist rotated token preserving `state` untouched!
         {:ok, %{rows: [[returned_state, new_revision]]}} <-
           query(
             """
             UPDATE colab_accounts
             SET credentials_ciphertext = $4,
                 credential_revision = credential_revision + 1,
                 refresh_claim_id = NULL,
                 refresh_claim_expires_at = NULL,
                 updated_at = $5
             WHERE tenant_id = $1
               AND group_id = $2
               AND binding_id = $3
               AND credential_revision = $6
               AND refresh_claim_id = $7
               AND state IN ('active', 'draining', 'retired')
             RETURNING state, credential_revision
             """,
             [
               tenant_id,
               group_id,
               account.binding_id,
               ciphertext,
               now,
               account.credential_revision,
               claim_id
             ]
           ) do
      # Step 2: Post-persist caller authorization check
      updated_account = %{
        account
        | state: returned_state,
          credential_revision: new_revision,
          credentials_ciphertext: ciphertext,
          refresh_claim_id: nil,
          refresh_claim_expires_at: nil
      }

      cond do
        mode == :execute and returned_state != "active" ->
          {:error, :account_not_active}

        check_deadline(deadline_ms) != :ok ->
          {:error, :budget_exhausted}

        true ->
          {:ok, token_reply(updated_account, merged)}
      end
    else
      {:ok, %{rows: []}} ->
        # Concurrent reconnect or state change superseded our claim
        {:error, :refresh_in_progress}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle_invalid_grant(tenant_id, group_id, binding_id, expected_revision, claim_id) do
    now = SystemsClock.utc_now()

    _ =
      query(
        """
        UPDATE colab_accounts
        SET status = 'reauthorization_required',
            refresh_claim_id = NULL,
            refresh_claim_expires_at = NULL,
            updated_at = $4
        WHERE tenant_id = $1
          AND group_id = $2
          AND binding_id = $3
          AND credential_revision = $5
          AND refresh_claim_id = $6
        """,
        [tenant_id, group_id, binding_id, now, expected_revision, claim_id]
      )

    :ok
  end

  defp release_refresh_claim(tenant_id, group_id, binding_id, expected_revision, claim_id) do
    now = SystemsClock.utc_now()

    _ =
      query(
        """
        UPDATE colab_accounts
        SET refresh_claim_id = NULL,
            refresh_claim_expires_at = NULL,
            updated_at = $4
        WHERE tenant_id = $1
          AND group_id = $2
          AND binding_id = $3
          AND credential_revision = $5
          AND refresh_claim_id = $6
        """,
        [tenant_id, group_id, binding_id, now, expected_revision, claim_id]
      )

    :ok
  end

  defp load_account_for_mode(tenant_id, group_id, binding_id, mode) do
    case get_account(tenant_id, group_id, binding_id) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, %{status: "reauthorization_required"}} ->
        {:error, :authorization_unavailable}

      {:ok, %{state: state} = account} ->
        if state in allowed_states_for_mode(mode) do
          {:ok, account}
        else
          {:error, :account_not_active}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp allowed_states_for_mode(:execute), do: ["active"]
  defp allowed_states_for_mode(:cleanup), do: ["active", "draining", "retired"]

  defp token_reply(account, creds) do
    %{
      access_token: creds["access_token"],
      credential_revision: account.credential_revision,
      account: account,
      credentials: creds
    }
  end

  # ============================================================================
  # §1.2 Group Connection & Listing Queries
  # ============================================================================

  @doc """
  Return `"connected" | "reauthorization_required" | "not_connected"` for
  `(tenant_id, group_id)`.
  """
  @spec connection_state(String.t(), String.t()) :: String.t()
  def connection_state(tenant_id, group_id)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" do
    case query(
           """
           SELECT state, status
           FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND state IN ('active', 'draining')
           """,
           [tenant_id, group_id]
         ) do
      {:ok, %{rows: []}} ->
        "not_connected"

      {:ok, %{rows: rows}} ->
        cond do
          Enum.any?(rows, fn [state, status] -> state == "active" and status == "ok" end) ->
            "connected"

          Enum.any?(rows, fn [_state, status] -> status == "reauthorization_required" end) ->
            "reauthorization_required"

          true ->
            "connected"
        end

      {:error, _} ->
        "not_connected"
    end
  end

  def connection_state(_, _), do: "not_connected"

  @doc "True if `(tenant_id, group_id)` has at least one `state = 'active'` Colab account."
  @spec has_active_account?(String.t(), String.t()) :: boolean()
  def has_active_account?(tenant_id, group_id)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" do
    case query(
           """
           SELECT 1 FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND state = 'active'
           LIMIT 1
           """,
           [tenant_id, group_id]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  def has_active_account?(_, _), do: false

  @doc """
  List non-retired Colab accounts in `(tenant_id, group_id)` with per-binding
  active VM counts.
  """
  @spec list_group_accounts_with_stats(String.t(), String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def list_group_accounts_with_stats(tenant_id, group_id)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" do
    case query(
           """
           SELECT
             a.binding_id,
             a.alias,
             a.email,
             a.google_sub,
             a.status,
             a.state,
             a.ccu_balance,
             a.ccu_rate_hourly,
             a.eligible_gpus,
             COALESCE(l.active_vm_count, 0)::bigint
           FROM colab_accounts a
           LEFT JOIN (
             SELECT account_id, COUNT(*) AS active_vm_count
             FROM colab_vm_leases
             WHERE tenant_id = $1
               AND group_id = $2
               AND state IN ('assigning', 'active')
             GROUP BY account_id
           ) l ON l.account_id = a.binding_id
           WHERE a.tenant_id = $1
             AND a.group_id = $2
             AND a.state IN ('active', 'draining')
           ORDER BY a.created_at ASC, a.binding_id ASC
           """,
           [tenant_id, group_id]
         ) do
      {:ok, %{rows: rows}} ->
        accounts =
          Enum.map(rows, fn [
                              binding_id,
                              alias_name,
                              email,
                              google_sub,
                              status,
                              state,
                              ccu_balance,
                              ccu_rate_hourly,
                              eligible_gpus,
                              active_vm_count
                            ] ->
            %{
              "binding_id" => binding_id,
              "alias" => alias_name,
              "email" => email,
              "google_sub" => google_sub,
              "status" => status,
              "state" => state,
              "ccu_balance" => ccu_balance,
              "ccu_rate_hourly" => ccu_rate_hourly,
              "eligible_gpus" => normalize_eligible_gpus(eligible_gpus),
              "active_vm_count" => active_vm_count || 0
            }
          end)

        {:ok, accounts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_group_accounts_with_stats(_, _), do: {:ok, []}

  @doc "List active `status = 'ok'` Colab accounts in `(tenant_id, group_id)` for Pool admission."
  @spec list_usable_accounts(String.t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def list_usable_accounts(tenant_id, group_id, limit \\ 50)
      when is_binary(tenant_id) and is_binary(group_id) and is_integer(limit) and limit > 0 do
    case query(
           """
           SELECT #{@account_columns}
           FROM colab_accounts
           WHERE tenant_id = $1
             AND group_id = $2
             AND state = 'active'
             AND status = 'ok'
           ORDER BY created_at ASC, binding_id ASC
           LIMIT $3
           """,
           [tenant_id, group_id, limit]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &decode_account/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetch a single Colab account by `(tenant_id, group_id, binding_id)`."
  @spec get_account(String.t(), String.t(), String.t() | nil) ::
          {:ok, map() | nil} | {:error, term()}
  def get_account(tenant_id, group_id, binding_id)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(binding_id) do
    case query(
           """
           SELECT #{@account_columns}
           FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND binding_id = $3
           """,
           [tenant_id, group_id, binding_id]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_account(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_account(_, _, _), do: {:ok, nil}

  @doc "Find a cleanup-eligible account in `(tenant_id, group_id)` matching `google_sub`."
  @spec find_cleanup_account_by_sub(String.t(), String.t(), String.t() | nil) ::
          {:ok, map() | nil} | {:error, term()}
  def find_cleanup_account_by_sub(tenant_id, group_id, google_sub)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(google_sub) and
             google_sub != "" do
    case query(
           """
           SELECT #{@account_columns}
           FROM colab_accounts
           WHERE tenant_id = $1
             AND group_id = $2
             AND google_sub = $3
             AND state IN ('active', 'draining', 'retired')
             AND status = 'ok'
           ORDER BY CASE state WHEN 'active' THEN 0 WHEN 'draining' THEN 1 ELSE 2 END ASC,
                    updated_at DESC
           LIMIT 1
           """,
           [tenant_id, group_id, google_sub]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_account(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def find_cleanup_account_by_sub(_, _, _), do: {:ok, nil}

  @doc """
  Hard-delete a `'retired'` `colab_accounts` row once 0 leases remain for
  `(tenant_id, group_id, binding_id)`.
  """
  @spec prune_retired_account_if_empty(String.t(), String.t(), String.t()) :: :ok
  def prune_retired_account_if_empty(tenant_id, group_id, binding_id)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(binding_id) do
    _ =
      query(
        """
        DELETE FROM colab_accounts a
        WHERE a.tenant_id = $1
          AND a.group_id = $2
          AND a.binding_id = $3
          AND a.state = 'retired'
          AND NOT EXISTS (
            SELECT 1 FROM colab_vm_leases l
            WHERE l.tenant_id = a.tenant_id
              AND l.group_id = a.group_id
              AND l.account_id = a.binding_id
          )
        """,
        [tenant_id, group_id, binding_id]
      )

    :ok
  end

  def prune_retired_account_if_empty(_, _, _), do: :ok

  # ============================================================================
  # §1.3 Disconnect & Retirement API
  # ============================================================================

  @doc """
  Disconnect all Colab accounts for `(tenant_id, group_id)` outside any outer
  plugin lock.

  1. Short DB tx (`tenant SHARED -> group EXCLUSIVE`): fail all open OAuth
     attempts, verify no fresh draining and no `assigning` leases, switch
     accounts to `'draining'`, transition `active` leases to `'stopping'`.
  2. Outside DB tx: inline unassign up to #{@max_inline_drain_leases} `stopping`
     leases (`mode: :cleanup`), refreshing `delete_started_at` heartbeat.
  3. Short DB tx (`tenant SHARED -> group EXCLUSIVE`): count ALL remaining
     leases across every state. If 0 -> hard-delete accounts and advance
     `colab_group_install_states` to `'uninstalled'`. If > 0 -> restore
     `state = 'active'` (preserving `reauthorization_required`) and return
     `{:error, :colab_account_in_use}`.
  """
  @spec disconnect_all_for_group(String.t(), String.t(), keyword()) ::
          {:ok, %{generation: integer()}} | {:error, :colab_account_in_use | term()}
  def disconnect_all_for_group(tenant_id, group_id, opts \\ [])

  def disconnect_all_for_group(tenant_id, group_id, opts)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" and
             is_list(opts) do
    case disconnect_bindings(tenant_id, group_id, :all, sync_plugin_state?(opts)) do
      {:ok, %{generation: gen}} -> {:ok, %{generation: gen}}
      {:error, reason} -> {:error, reason}
    end
  end

  def disconnect_all_for_group(_, _, _), do: {:error, :invalid_input}

  @doc """
  Disconnect a single Colab binding in `(tenant_id, group_id)` with the same
  3-step drain-and-finalize guarantees as `disconnect_all_for_group/2`.
  """
  @spec disconnect_binding(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{generation: integer(), remaining_accounts: non_neg_integer()}}
          | {:error, :colab_account_in_use | :not_found | term()}
  def disconnect_binding(tenant_id, group_id, binding_id, opts \\ [])

  def disconnect_binding(tenant_id, group_id, binding_id, opts)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" and
             is_binary(binding_id) and binding_id != "" and is_list(opts) do
    disconnect_bindings(tenant_id, group_id, {:one, binding_id}, sync_plugin_state?(opts))
  end

  def disconnect_binding(_, _, _, _), do: {:error, :not_found}

  # `sync_plugin_state: false` is for callers without a Comma workspace plugin row
  # (Bridge for Teams). Their install-state writes are recorded as already synced so
  # `ColabInstallReconciler` never queues them.
  defp sync_plugin_state?(opts), do: Keyword.get(opts, :sync_plugin_state, true) != false

  defp disconnect_bindings(tenant_id, group_id, target_spec, sync?) do
    delete_token = random_id()
    now = SystemsClock.utc_now()
    next_reap = DateTime.add(now, @stopping_reap_seconds, :second)

    phase1 =
      Repo.transaction(fn ->
        with :ok <- set_lock_timeout(),
             :ok <- lock_tenant_shared(tenant_id),
             :ok <- lock_group_exclusive(tenant_id, group_id),
             :ok <- fail_open_attempts_for_group_in_tx(tenant_id, group_id, now),
             {:ok, accounts} <-
               lock_target_accounts_for_disconnect(tenant_id, group_id, target_spec) do
          cond do
            accounts == [] and target_spec == :all ->
              case upsert_group_install_state_in_tx(
                     tenant_id,
                     group_id,
                     "uninstalled",
                     nil,
                     now,
                     sync?
                   ) do
                {:ok, gen} -> {:already_empty, gen, 0}
                {:error, reason} -> Repo.rollback(reason)
              end

            accounts == [] ->
              Repo.rollback(:not_found)

            Enum.any?(accounts, &fresh_draining?(&1, now)) ->
              Repo.rollback(:colab_account_in_use)

            true ->
              binding_ids = Enum.map(accounts, & &1.binding_id)

              if has_assigning_leases_in_tx?(tenant_id, group_id, binding_ids) do
                Repo.rollback(:colab_account_in_use)
              else
                with {:ok, _} <-
                       query(
                         """
                         UPDATE colab_accounts
                         SET state = 'draining',
                             delete_token = $4,
                             delete_started_at = $5,
                             updated_at = $5
                         WHERE tenant_id = $1
                           AND group_id = $2
                           AND binding_id = ANY($3::text[])
                         """,
                         [tenant_id, group_id, binding_ids, delete_token, now]
                       ),
                     {:ok, stopping_leases} <-
                       claim_leases_for_disconnect_in_tx(
                         tenant_id,
                         group_id,
                         binding_ids,
                         next_reap
                       ) do
                  {:drain, binding_ids, stopping_leases}
                else
                  {:error, reason} -> Repo.rollback(reason)
                end
              end
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case phase1 do
      {:ok, {:already_empty, gen, remaining}} ->
        {:ok, %{generation: gen, remaining_accounts: remaining}}

      {:ok, {:drain, binding_ids, stopping_leases}} ->
        # Step 2: Outside DB tx — inline unassign up to 6 leases
        inline_leases = Enum.take(stopping_leases, @max_inline_drain_leases)

        Enum.each(inline_leases, fn lease ->
          _ = Reaper.unassign_claimed(lease)
          _ = touch_draining_heartbeat(tenant_id, group_id, binding_ids, delete_token)
        end)

        # Step 3: Short DB tx — finalize delete or restore active
        finalize_disconnect(tenant_id, group_id, binding_ids, delete_token, sync?)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_disconnect(tenant_id, group_id, binding_ids, delete_token, sync?) do
    now = SystemsClock.utc_now()

    tx_result =
      Repo.transaction(fn ->
        with :ok <- set_lock_timeout(),
             :ok <- lock_tenant_shared(tenant_id),
             :ok <- lock_group_exclusive(tenant_id, group_id),
             {:ok, locked} <-
               lock_bindings_with_token_in_tx(tenant_id, group_id, binding_ids, delete_token),
             {:ok, lease_count} <-
               count_all_leases_for_bindings_in_tx(tenant_id, group_id, binding_ids) do
          cond do
            locked == [] ->
              {:error, :colab_account_in_use}

            lease_count == 0 ->
              with {:ok, _} <-
                     query(
                       """
                       DELETE FROM colab_accounts
                       WHERE tenant_id = $1
                         AND group_id = $2
                         AND binding_id = ANY($3::text[])
                         AND delete_token = $4
                       """,
                       [tenant_id, group_id, binding_ids, delete_token]
                     ),
                   {:ok, remaining} <- list_remaining_non_retired_ids(tenant_id, group_id) do
                {desired_state, next_binding_id} =
                  case remaining do
                    [] -> {"uninstalled", nil}
                    [first | _] -> {"installed", first}
                  end

                case upsert_group_install_state_in_tx(
                       tenant_id,
                       group_id,
                       desired_state,
                       next_binding_id,
                       now,
                       sync?
                     ) do
                  {:ok, gen} ->
                    {:ok, %{generation: gen, remaining_accounts: length(remaining)}}

                  {:error, reason} ->
                    Repo.rollback(reason)
                end
              else
                {:error, reason} -> Repo.rollback(reason)
              end

            true ->
              # Remaining leases exist (active/stopping/assigning/unassign_unconfirmed):
              # restore state='active' (preserving status='reauthorization_required'!)
              case query(
                     """
                     UPDATE colab_accounts
                     SET state = 'active',
                         delete_token = NULL,
                         delete_started_at = NULL,
                         updated_at = $5
                     WHERE tenant_id = $1
                       AND group_id = $2
                       AND binding_id = ANY($3::text[])
                       AND delete_token = $4
                       AND state = 'draining'
                     """,
                     [tenant_id, group_id, binding_ids, delete_token, now]
                   ) do
                {:ok, _} -> {:error, :colab_account_in_use}
                {:error, reason} -> Repo.rollback(reason)
              end
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case tx_result do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp touch_draining_heartbeat(tenant_id, group_id, binding_ids, delete_token) do
    now = SystemsClock.utc_now()

    _ =
      query(
        """
        UPDATE colab_accounts
        SET delete_started_at = $5, updated_at = $5
        WHERE tenant_id = $1
          AND group_id = $2
          AND binding_id = ANY($3::text[])
          AND state = 'draining'
          AND delete_token = $4
        """,
        [tenant_id, group_id, binding_ids, delete_token, now]
      )

    :ok
  end

  @doc """
  Pure-PostgreSQL group retirement (ZERO HTTP!).
  Safe to call inside `Salix.Control.Groups.delete`'s outer transaction.
  """
  @spec retire_group_in_tx(String.t(), String.t()) :: :ok | {:error, term()}
  def retire_group_in_tx(tenant_id, group_id)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" do
    if Repo.in_transaction?() do
      do_retire_group_in_tx(tenant_id, group_id)
    else
      case Repo.transaction(fn ->
             case do_retire_group_in_tx(tenant_id, group_id) do
               :ok -> :ok
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def retire_group_in_tx(_, _), do: :ok

  defp do_retire_group_in_tx(tenant_id, group_id) do
    now = SystemsClock.utc_now()

    with :ok <- set_lock_timeout(),
         :ok <- lock_tenant_shared(tenant_id),
         :ok <- lock_group_exclusive(tenant_id, group_id),
         {:ok, _} <-
           query(
             """
             INSERT INTO colab_retired_scopes (scope_key, retired_at)
             VALUES ($1, $2)
             ON CONFLICT (scope_key) DO NOTHING
             """,
             ["group:" <> group_id, now]
           ),
         :ok <- fail_open_attempts_for_group_in_tx(tenant_id, group_id, now),
         {:ok, _} <-
           query(
             """
             UPDATE colab_accounts
             SET state = 'retired',
                 delete_token = NULL,
                 delete_started_at = NULL,
                 updated_at = $3
             WHERE tenant_id = $1 AND group_id = $2 AND state != 'retired'
             """,
             [tenant_id, group_id, now]
           ),
         {:ok, _} <-
           query(
             """
             UPDATE colab_vm_leases
             SET state = 'stopping',
                 generation = generation + 1,
                 reap_after = $3
             WHERE tenant_id = $1 AND group_id = $2 AND state = 'active'
             """,
             [tenant_id, group_id, now]
           ),
         {:ok, _gen} <-
           upsert_group_install_state_in_tx(tenant_id, group_id, "uninstalled", nil, now),
         {:ok, _} <-
           query(
             """
             DELETE FROM colab_accounts a
             WHERE a.tenant_id = $1
               AND a.group_id = $2
               AND a.state = 'retired'
               AND NOT EXISTS (
                 SELECT 1 FROM colab_vm_leases l
                 WHERE l.tenant_id = a.tenant_id
                   AND l.group_id = a.group_id
                   AND l.account_id = a.binding_id
               )
             """,
             [tenant_id, group_id]
           ) do
      :ok
    end
  end

  @doc """
  Retire a group's Colab accounts and leases, then asynchronously kick `Reaper`
  outside the transaction. Used by BFT `archive_project` Outbox.
  """
  @spec retire_group(String.t(), String.t()) :: :ok | {:error, term()}
  def retire_group(tenant_id, group_id)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" do
    with :ok <- retire_group_in_tx(tenant_id, group_id) do
      kick_reaper_async()
      :ok
    end
  end

  def retire_group(_, _), do: :ok

  @doc """
  Retire all Colab accounts and leases for `tenant_id` under `tenant EXCLUSIVE`
  lock, then asynchronously kick `Reaper` outside the transaction.
  """
  @spec retire_tenant(String.t() | nil) :: :ok | {:error, term()}
  def retire_tenant(tenant_id) when is_binary(tenant_id) and tenant_id != "" do
    now = SystemsClock.utc_now()

    tx_result =
      Repo.transaction(fn ->
        with :ok <- set_lock_timeout(),
             :ok <- lock_tenant_exclusive(tenant_id),
             {:ok, _} <-
               query(
                 """
                 INSERT INTO colab_retired_scopes (scope_key, retired_at)
                 VALUES ($1, $2)
                 ON CONFLICT (scope_key) DO NOTHING
                 """,
                 ["tenant:" <> tenant_id, now]
               ),
             {:ok, _} <-
               query(
                 """
                 UPDATE colab_oauth_attempts
                 SET status = 'failed',
                     exchange_claim_id = NULL,
                     exchanged_ciphertext = NULL,
                     updated_at = $2
                 WHERE tenant_id = $1
                   AND status IN ('pending', 'exchanging', 'exchanged')
                 """,
                 [tenant_id, now]
               ),
             {:ok, _} <-
               query(
                 """
                 UPDATE colab_accounts
                 SET state = 'retired',
                     delete_token = NULL,
                     delete_started_at = NULL,
                     updated_at = $2
                 WHERE tenant_id = $1 AND state != 'retired'
                 """,
                 [tenant_id, now]
               ),
             {:ok, _} <-
               query(
                 """
                 UPDATE colab_vm_leases
                 SET state = 'stopping',
                     generation = generation + 1,
                     reap_after = $2
                 WHERE tenant_id = $1 AND state = 'active'
                 """,
                 [tenant_id, now]
               ),
             {:ok, _} <-
               query(
                 """
                 UPDATE colab_group_install_states
                 SET generation = generation + 1,
                     desired_state = 'uninstalled',
                     binding_id = NULL,
                     updated_at = $2
                 WHERE tenant_id = $1 AND desired_state != 'uninstalled'
                 """,
                 [tenant_id, now]
               ),
             {:ok, _} <-
               query(
                 """
                 DELETE FROM colab_accounts a
                 WHERE a.tenant_id = $1
                   AND a.state = 'retired'
                   AND NOT EXISTS (
                     SELECT 1 FROM colab_vm_leases l
                     WHERE l.tenant_id = a.tenant_id
                       AND l.group_id = a.group_id
                       AND l.account_id = a.binding_id
                   )
                 """,
                 [tenant_id]
               ) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case tx_result do
      {:ok, :ok} ->
        kick_reaper_async()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def retire_tenant(_), do: :ok

  # ============================================================================
  # §1.4 Two-Phase Commit-Ordered Plugin Convergence Helpers
  # ============================================================================

  @doc "Read the durable `colab_group_install_states` row for `(tenant_id, group_id)`."
  @spec get_group_install_state(String.t(), String.t()) ::
          {:ok,
           %{
             generation: integer(),
             desired_state: String.t(),
             binding_id: String.t() | nil,
             plugin_synced_generation: integer()
           }
           | nil}
          | {:error, term()}
  def get_group_install_state(tenant_id, group_id)
      when is_binary(tenant_id) and is_binary(group_id) do
    case query(
           """
           SELECT generation, desired_state, binding_id, plugin_synced_generation
           FROM colab_group_install_states
           WHERE tenant_id = $1 AND group_id = $2
           """,
           [tenant_id, group_id]
         ) do
      {:ok, %{rows: [[generation, desired_state, binding_id, plugin_synced_generation]]}} ->
        {:ok,
         %{
           generation: generation,
           desired_state: desired_state,
           binding_id: binding_id,
           plugin_synced_generation: plugin_synced_generation
         }}

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_group_install_state(_, _), do: {:ok, nil}

  @doc """
  Phase B card settlement fenced on `(tenant SHARED -> group EXCLUSIVE)`:
  verifies `colab_group_install_states` STILL has `desired_state == "installed"`
  and `generation == ^generation`. Performs only DB updates inside the
  transaction and delivers notifications / async tool completions strictly
  AFTER the transaction commits. If superseded by a concurrent uninstall,
  returns `:ok` without settling cards.
  """
  @spec settle_install_cards_if_generation_current(String.t(), String.t(), integer()) ::
          :ok | {:error, term()}
  def settle_install_cards_if_generation_current(tenant_id, group_id, generation)
      when is_binary(tenant_id) and is_binary(group_id) and is_integer(generation) do
    tx_result =
      Repo.transaction(fn ->
        with :ok <- set_lock_timeout(),
             :ok <- lock_tenant_shared(tenant_id),
             :ok <- lock_group_exclusive(tenant_id, group_id),
             {:ok, state} <- get_group_install_state(tenant_id, group_id) do
          if is_map(state) and state.desired_state == "installed" and
               state.generation == generation do
            case CapabilityRequests.complete_plugin_install_in_tx(
                   group_id,
                   tenant_id,
                   "google-colab"
                 ) do
              {:ok, settled} -> settled
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            []
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case tx_result do
      {:ok, settled} ->
        CapabilityRequests.deliver_settled_plugin_installs(settled)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Bounded two-step cleanup of expired `colab_oauth_attempts` rows:
  1. Scrub `exchanged_ciphertext`, `code_verifier`, and `exchange_claim_id` on
     expired open attempts (`expires_at <= now`) and mark them `'expired'`.
  2. Delete expired/finished attempts older than 3600s past `expires_at`.
  """
  @spec cleanup_expired_oauth_attempts(pos_integer()) ::
          {:ok, %{scrubbed: non_neg_integer(), deleted: non_neg_integer()}} | {:error, term()}
  def cleanup_expired_oauth_attempts(limit \\ 32)
      when is_integer(limit) and limit > 0 do
    now = SystemsClock.utc_now()
    delete_cutoff = DateTime.add(now, -@attempt_delete_grace_seconds, :second)

    with {:ok, %{num_rows: scrubbed}} <-
           query(
             """
             WITH target AS (
               SELECT attempt_id
               FROM colab_oauth_attempts
               WHERE expires_at <= $1
                 AND status IN ('pending', 'exchanging', 'exchanged')
                 AND (exchanged_ciphertext IS NOT NULL OR code_verifier IS NOT NULL)
               ORDER BY expires_at ASC
               LIMIT $2
               FOR UPDATE SKIP LOCKED
             )
             UPDATE colab_oauth_attempts a
             SET exchanged_ciphertext = NULL,
                 code_verifier = NULL,
                 exchange_claim_id = NULL,
                 status = 'expired',
                 updated_at = $1
             FROM target
             WHERE a.attempt_id = target.attempt_id
             """,
             [now, limit]
           ),
         {:ok, %{num_rows: deleted}} <-
           query(
             """
             WITH target AS (
               SELECT attempt_id
               FROM colab_oauth_attempts
               WHERE expires_at <= $1
               ORDER BY expires_at ASC
               LIMIT $2
               FOR UPDATE SKIP LOCKED
             )
             DELETE FROM colab_oauth_attempts a
             USING target
             WHERE a.attempt_id = target.attempt_id
             """,
             [delete_cutoff, limit]
           ) do
      {:ok, %{scrubbed: scrubbed || 0, deleted: deleted || 0}}
    end
  end

  @doc """
  List groups whose `colab_group_install_states.plugin_synced_generation < generation`
  so startup/periodic convergence can reconcile `Comma.Repo` and `PluginStore`.

  Rows come in `(updated_at, tenant_id, group_id)` order; `after:` takes such a
  keyset cursor and returns only rows after it.
  """
  @spec list_unsynced_group_install_states(pos_integer(), keyword()) ::
          {:ok,
           [
             %{
               tenant_id: String.t(),
               group_id: String.t(),
               desired_state: String.t(),
               generation: integer(),
               plugin_synced_generation: integer(),
               updated_at: DateTime.t()
             }
           ]}
          | {:error, term()}
  def list_unsynced_group_install_states(limit \\ 16, opts \\ [])
      when is_integer(limit) and limit > 0 and is_list(opts) do
    {cursor_sql, params} =
      case Keyword.get(opts, :after) do
        {%DateTime{} = updated_at, tenant_id, group_id}
        when is_binary(tenant_id) and is_binary(group_id) ->
          {"AND (updated_at, tenant_id, group_id) > ($2, $3, $4)",
           [limit, updated_at, tenant_id, group_id]}

        _ ->
          {"", [limit]}
      end

    case query(
           """
           SELECT tenant_id, group_id, desired_state, generation, plugin_synced_generation,
                  updated_at
           FROM colab_group_install_states
           WHERE plugin_synced_generation < generation
           #{cursor_sql}
           ORDER BY updated_at ASC, tenant_id ASC, group_id ASC
           LIMIT $1
           """,
           params
         ) do
      {:ok, %{rows: rows}} ->
        items =
          Enum.map(rows, fn [
                              tenant_id,
                              group_id,
                              desired_state,
                              generation,
                              synced_gen,
                              updated_at
                            ] ->
            %{
              tenant_id: tenant_id,
              group_id: group_id,
              desired_state: desired_state,
              generation: generation,
              plugin_synced_generation: synced_gen,
              updated_at: updated_at
            }
          end)

        {:ok, items}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Move an unsynced install state that the reconciler skipped or failed to the back
  of the `updated_at` queue, fenced on `generation`, so it cannot starve later rows.
  """
  @spec defer_unsynced_group_install_state(String.t(), String.t(), integer()) ::
          :ok | {:error, term()}
  def defer_unsynced_group_install_state(tenant_id, group_id, generation)
      when is_binary(tenant_id) and is_binary(group_id) and is_integer(generation) do
    now = SystemsClock.utc_now()

    case query(
           """
           UPDATE colab_group_install_states
           SET updated_at = GREATEST(updated_at + interval '1 second', $4)
           WHERE tenant_id = $1
             AND group_id = $2
             AND generation = $3
             AND plugin_synced_generation < generation
           """,
           [tenant_id, group_id, generation, now]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Record final Salix sync acknowledgement strictly AFTER `Comma.Repo` commit
  and Phase B settlement succeeded.
  """
  @spec mark_plugin_synced(String.t(), String.t(), integer(), String.t()) ::
          :ok | {:error, term()}
  def mark_plugin_synced(tenant_id, group_id, generation, desired_state)
      when is_binary(tenant_id) and is_binary(group_id) and is_integer(generation) and
             is_binary(desired_state) do
    now = SystemsClock.utc_now()

    case query(
           """
           UPDATE colab_group_install_states
           SET plugin_synced_generation = $3,
               updated_at = $5
           WHERE tenant_id = $1
             AND group_id = $2
             AND generation = $3
             AND desired_state = $4
           """,
           [tenant_id, group_id, generation, desired_state, now]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Internal SQL, locking, encryption & helpers
  # ============================================================================

  defp set_lock_timeout do
    case query("SET LOCAL lock_timeout = '5s'", []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_tenant_shared(tenant_id) do
    case query(
           "SELECT pg_advisory_xact_lock_shared(hashtextextended('colab_tenant:' || $1, 0))",
           [tenant_id]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_tenant_exclusive(tenant_id) do
    case query(
           "SELECT pg_advisory_xact_lock(hashtextextended('colab_tenant:' || $1, 0))",
           [tenant_id]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_group_exclusive(tenant_id, group_id) do
    case query(
           "SELECT pg_advisory_xact_lock(hashtextextended('colab_group:' || $1 || ':' || $2, 0))",
           [tenant_id, group_id]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_scope_not_retired(tenant_id, group_id) do
    case query(
           """
           SELECT 1 FROM colab_retired_scopes
           WHERE scope_key = ANY($1::text[])
           LIMIT 1
           """,
           [["tenant:" <> tenant_id, "group:" <> group_id]]
         ) do
      {:ok, %{rows: [[1]]}} -> {:error, :scope_retired}
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp scope_retired_in_tx?(tenant_id, group_id) do
    ensure_scope_not_retired(tenant_id, group_id) == {:error, :scope_retired}
  end

  defp fetch_attempt(attempt_id) do
    case query("SELECT #{@attempt_columns} FROM colab_oauth_attempts WHERE attempt_id = $1", [
           attempt_id
         ]) do
      {:ok, %{rows: [row]}} -> {:ok, decode_attempt(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_attempt_for_update(attempt_id) do
    case query(
           "SELECT #{@attempt_columns} FROM colab_oauth_attempts WHERE attempt_id = $1 FOR UPDATE",
           [attempt_id]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_attempt(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attempt_matches_caller?(
         attempt,
         tenant_id,
         group_id,
         initiator_user_id,
         operation,
         requested_binding_id
       ) do
    attempt.tenant_id == tenant_id and
      attempt.group_id == group_id and
      attempt.initiator_user_id == initiator_user_id and
      attempt.operation == operation and
      (is_nil(requested_binding_id) or attempt.target_binding_id == requested_binding_id)
  end

  defp get_non_retired_account(tenant_id, group_id, binding_id) do
    case query(
           """
           SELECT #{@account_columns}
           FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND binding_id = $3 AND state != 'retired'
           """,
           [tenant_id, group_id, binding_id]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_account(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_sole_non_retired_account(tenant_id, group_id) do
    case query(
           """
           SELECT #{@account_columns}
           FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND state != 'retired'
           ORDER BY created_at ASC
           LIMIT 2
           """,
           [tenant_id, group_id]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, decode_account(row)}
      {:ok, _} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp count_non_retired_accounts(tenant_id, group_id) do
    case query(
           """
           SELECT COUNT(*)::bigint FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND state != 'retired'
           """,
           [tenant_id, group_id]
         ) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_remaining_non_retired_ids(tenant_id, group_id) do
    case query(
           """
           SELECT binding_id FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND state != 'retired'
           ORDER BY created_at ASC, binding_id ASC
           """,
           [tenant_id, group_id]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [id] -> id end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail_open_attempts_for_group_in_tx(tenant_id, group_id, now) do
    case query(
           """
           UPDATE colab_oauth_attempts
           SET status = 'failed',
               exchange_claim_id = NULL,
               exchanged_ciphertext = NULL,
               updated_at = $3
           WHERE tenant_id = $1
             AND group_id = $2
             AND status IN ('pending', 'exchanging', 'exchanged')
           """,
           [tenant_id, group_id, now]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_target_accounts_for_disconnect(tenant_id, group_id, :all) do
    case query(
           """
           SELECT #{@account_columns}
           FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND state != 'retired'
           ORDER BY binding_id ASC
           FOR UPDATE
           """,
           [tenant_id, group_id]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &decode_account/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_target_accounts_for_disconnect(tenant_id, group_id, {:one, binding_id}) do
    case query(
           """
           SELECT #{@account_columns}
           FROM colab_accounts
           WHERE tenant_id = $1 AND group_id = $2 AND binding_id = $3 AND state != 'retired'
           FOR UPDATE
           """,
           [tenant_id, group_id, binding_id]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &decode_account/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp has_assigning_leases_in_tx?(tenant_id, group_id, binding_ids) do
    case query(
           """
           SELECT EXISTS(
             SELECT 1 FROM colab_vm_leases
             WHERE tenant_id = $1
               AND group_id = $2
               AND account_id = ANY($3::text[])
               AND state = 'assigning'
           )
           """,
           [tenant_id, group_id, binding_ids]
         ) do
      {:ok, %{rows: [[exists]]}} -> exists == true
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp claim_leases_for_disconnect_in_tx(tenant_id, group_id, binding_ids, next_reap) do
    sql = """
    WITH target AS (
      SELECT vm_id FROM colab_vm_leases
      WHERE tenant_id = $1
        AND group_id = $2
        AND account_id = ANY($3::text[])
        AND state IN ('active', 'stopping')
      ORDER BY created_at ASC
      FOR UPDATE
    )
    UPDATE colab_vm_leases l
    SET state = 'stopping',
        generation = l.generation + 1,
        reap_after = $4
    FROM target
    WHERE l.vm_id = target.vm_id
    RETURNING
      l.vm_id, l.tenant_id, l.group_id, l.owner_scope, l.requester_principal,
      l.account_id, l.google_sub, l.notebook_hash, l.endpoint, l.variant,
      l.accelerator, l.high_mem, l.state, l.generation, l.owner_node,
      l.proxy_url, l.host_key_fingerprint, l.created_at, l.last_used_at,
      l.busy_until, l.hold_until, l.reap_after, l.last_error
    """

    case query(sql, [tenant_id, group_id, binding_ids, next_reap]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &Leases.decode_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_bindings_with_token_in_tx(tenant_id, group_id, binding_ids, delete_token) do
    case query(
           """
           SELECT binding_id FROM colab_accounts
           WHERE tenant_id = $1
             AND group_id = $2
             AND binding_id = ANY($3::text[])
             AND state = 'draining'
             AND delete_token = $4
           ORDER BY binding_id ASC
           FOR UPDATE
           """,
           [tenant_id, group_id, binding_ids, delete_token]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [id] -> id end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp count_all_leases_for_bindings_in_tx(tenant_id, group_id, binding_ids) do
    case query(
           """
           SELECT COUNT(*)::bigint FROM colab_vm_leases
           WHERE tenant_id = $1
             AND group_id = $2
             AND account_id = ANY($3::text[])
           """,
           [tenant_id, group_id, binding_ids]
         ) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_group_install_state_in_tx(
         tenant_id,
         group_id,
         desired_state,
         binding_id,
         now,
         sync? \\ true
       ) do
    # sync? = false records the new generation as already plugin-synced.
    case query(
           """
           INSERT INTO colab_group_install_states (
             tenant_id, group_id, generation, desired_state, binding_id,
             plugin_synced_generation, updated_at
           ) VALUES ($1, $2, 1, $3, $4, CASE WHEN $6::boolean THEN 0 ELSE 1 END, $5)
           ON CONFLICT (tenant_id, group_id) DO UPDATE SET
             generation = colab_group_install_states.generation + 1,
             desired_state = EXCLUDED.desired_state,
             binding_id = EXCLUDED.binding_id,
             plugin_synced_generation =
               CASE WHEN $6::boolean THEN colab_group_install_states.plugin_synced_generation
                    ELSE colab_group_install_states.generation + 1 END,
             updated_at = EXCLUDED.updated_at
           RETURNING generation
           """,
           [tenant_id, group_id, desired_state, binding_id, now, sync?]
         ) do
      {:ok, %{rows: [[gen]]}} -> {:ok, gen}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fresh_draining?(%{state: "draining", delete_started_at: %DateTime{} = started}, now) do
    DateTime.diff(now, started, :second) < @draining_stale_seconds
  end

  defp fresh_draining?(_, _), do: false

  defp expired_at?(%DateTime{} = expires_at, now) do
    DateTime.compare(expires_at, now) != :gt
  end

  defp expired_at?(_, _), do: true

  defp refresh_claim_active?(%{refresh_claim_expires_at: %DateTime{} = exp}, now) do
    DateTime.compare(exp, now) == :gt
  end

  defp refresh_claim_active?(_, _), do: false

  defp rejected_revision?(current_rev, rejected_rev)
       when is_integer(current_rev) and is_integer(rejected_rev),
       do: current_rev <= rejected_rev

  defp rejected_revision?(_, _), do: false

  defp token_fresh?(creds, now_unix, lead_seconds) do
    case expires_at_unix(creds["expires_at"]) do
      {:ok, exp} -> exp - now_unix > lead_seconds
      :error -> false
    end
  end

  defp token_unexpired?(creds, now_unix) do
    case expires_at_unix(creds["expires_at"]) do
      {:ok, exp} -> exp > now_unix
      :error -> false
    end
  end

  defp expires_at_unix(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, DateTime.to_unix(dt)}
      _ -> :error
    end
  end

  defp expires_at_unix(_), do: :error

  defp check_deadline(nil), do: :ok

  defp check_deadline(deadline_ms) when is_integer(deadline_ms) do
    if SystemsClock.monotonic_time(:millisecond) >= deadline_ms,
      do: {:error, :budget_exhausted},
      else: :ok
  end

  defp compute_http_timeout(nil, nil), do: {:ok, []}

  defp compute_http_timeout(nil, timeout) when is_integer(timeout) and timeout > 0,
    do: {:ok, [receive_timeout: timeout]}

  defp compute_http_timeout(deadline_ms, explicit_timeout) when is_integer(deadline_ms) do
    remaining = deadline_ms - SystemsClock.monotonic_time(:millisecond)

    if remaining <= 0 do
      :exhausted
    else
      cap =
        if is_integer(explicit_timeout) and explicit_timeout > 0,
          do: explicit_timeout,
          else: 20_000

      {:ok, [receive_timeout: min(cap, remaining)]}
    end
  end

  defp extract_ccu(info, observed_at) do
    %{
      ccu_balance: float_or_nil(info["currentBalance"]),
      ccu_rate_hourly: float_or_nil(info["consumptionRateHourly"]),
      eligible_gpus: normalize_eligible_gpus(info["eligibleGpus"]),
      ccu_observed_at: observed_at
    }
  end

  defp float_or_nil(v) when is_float(v), do: v
  defp float_or_nil(v) when is_integer(v), do: v * 1.0
  defp float_or_nil(_), do: nil

  defp normalize_eligible_gpus(list) when is_list(list) do
    Enum.filter(list, &(is_binary(&1) and &1 != ""))
  end

  defp normalize_eligible_gpus(_), do: []

  defp normalize_operation(:reconnect), do: "reconnect"
  defp normalize_operation("reconnect"), do: "reconnect"
  defp normalize_operation(_), do: "install"

  defp error_body_text(body) when is_binary(body), do: body
  defp error_body_text(body) when is_map(body), do: Jason.encode!(body)
  defp error_body_text(body), do: inspect(body)

  defp kick_reaper_async do
    if pid = Process.whereis(Reaper) do
      SystemsRuntime.Proc.send(pid, :sweep_now)
    end

    :ok
  rescue
    _ -> :ok
  end

  # ---- AES-256-GCM credential envelope (using :subscription_storage_key) ----

  @doc false
  def seal_payload(tenant_id, group_id, entity_id, value) do
    with {:ok, key} <- storage_key() do
      nonce = SystemsRuntime.Proc.random_bytes(12)
      aad = tenant_id <> ":" <> group_id <> ":" <> entity_id

      {body, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          Jason.encode!(value),
          aad,
          true
        )

      {:ok, nonce <> tag <> body}
    end
  end

  @doc false
  def open_payload(tenant_id, group_id, entity_id, ciphertext) when is_binary(ciphertext) do
    with {:ok, key} <- storage_key(),
         <<nonce::binary-size(12), tag::binary-size(16), body::binary>> <- ciphertext,
         aad = tenant_id <> ":" <> group_id <> ":" <> entity_id,
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, body, aad, tag, false),
         {:ok, value} <- Jason.decode(plain) do
      {:ok, value}
    else
      _ -> {:error, :unavailable}
    end
  end

  def open_payload(_, _, _, _), do: {:error, :unavailable}

  defp storage_key do
    case SystemsRuntime.get_env(:salix_agent, :subscription_storage_key) do
      secret when is_binary(secret) and byte_size(secret) == 32 -> {:ok, secret}
      _ -> {:error, :not_configured}
    end
  end

  defp random_id, do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(24), padding: false)

  defp query(sql, params), do: Repo.query(sql, params)

  defp decode_account([
         binding_id,
         tenant_id,
         group_id,
         alias_name,
         google_sub,
         email,
         credentials_ciphertext,
         credential_revision,
         refresh_claim_id,
         refresh_claim_expires_at,
         status,
         state,
         delete_token,
         delete_started_at,
         ccu_balance,
         ccu_rate_hourly,
         eligible_gpus,
         ccu_observed_at,
         created_at,
         updated_at,
         reconnect_revision
       ]) do
    %{
      binding_id: binding_id,
      tenant_id: tenant_id,
      group_id: group_id,
      alias: alias_name,
      google_sub: google_sub,
      email: email,
      credentials_ciphertext: credentials_ciphertext,
      credential_revision: credential_revision,
      refresh_claim_id: refresh_claim_id,
      refresh_claim_expires_at: refresh_claim_expires_at,
      status: status,
      state: state,
      delete_token: delete_token,
      delete_started_at: delete_started_at,
      ccu_balance: ccu_balance,
      ccu_rate_hourly: ccu_rate_hourly,
      eligible_gpus: normalize_eligible_gpus(eligible_gpus),
      ccu_observed_at: ccu_observed_at,
      created_at: created_at,
      updated_at: updated_at,
      reconnect_revision: reconnect_revision
    }
  end

  defp decode_attempt([
         attempt_id,
         tenant_id,
         group_id,
         initiator_user_id,
         operation,
         target_binding_id,
         target_alias,
         expected_revision,
         state_token,
         code_verifier,
         redirect_uri,
         status,
         exchange_claim_id,
         exchanging_started_at,
         exchanged_ciphertext,
         result_binding_id,
         result_generation,
         expires_at,
         created_at,
         updated_at,
         expected_reconnect_revision
       ]) do
    %{
      attempt_id: attempt_id,
      tenant_id: tenant_id,
      group_id: group_id,
      initiator_user_id: initiator_user_id,
      operation: operation,
      target_binding_id: target_binding_id,
      target_alias: target_alias,
      expected_revision: expected_revision,
      expected_reconnect_revision: expected_reconnect_revision,
      state_token: state_token,
      code_verifier: code_verifier,
      redirect_uri: redirect_uri,
      status: status,
      exchange_claim_id: exchange_claim_id,
      exchanging_started_at: exchanging_started_at,
      exchanged_ciphertext: exchanged_ciphertext,
      result_binding_id: result_binding_id,
      result_generation: result_generation,
      expires_at: expires_at,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp clean_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp clean_string(_), do: nil

  defp reject_nil_values(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
