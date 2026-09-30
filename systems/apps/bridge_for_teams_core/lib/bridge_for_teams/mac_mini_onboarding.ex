defmodule BridgeForTeams.MacMiniOnboarding do
  @moduledoc """
  Product-facing runner onboarding/install wrapper lifecycle.

  The dashboard creates a short-lived install code and shows only a one-line
  `curl | sh` command. The wrapper endpoint consumes the code once, lazy-mints a
  durable runner API key, fills in the `BFT_*` environment internally, and
  executes the server-bundled installer with the current Server descriptor's
  exact artifacts.
  """
  import Ecto.Query
  require Logger

  alias BridgeForTeams.{Auth, Observability}
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Repo

  alias BridgeForTeams.Schema.{
    ApiKey,
    MacMiniInstallCode,
    MacMiniProvisioner,
    Organization
  }

  @default_ttl_seconds 15 * 60
  @default_install_prefix "$HOME/.bridge-for-teams"
  @default_state_dir "$HOME/.bridge-for-teams/state"
  @default_launchd_label "com.bridgeforteams.runner"
  @installer_path Path.expand(
                    "../../../../connector/mac-mini-provisioner-install.sh",
                    __DIR__
                  )
  @external_resource @installer_path
  @installer_source File.read!(@installer_path)
  @doc """
  Create a short-lived, single-use install code and dashboard command.

  Options:
    * `:created_by_id` - user id for audit
    * `:wrapper_url` - full public wrapper endpoint URL
    * `:server_build_id` - diagnostic identity of the issuing Server build
    * `:ttl_seconds` - code lifetime, defaults to 15 minutes
  """
  @spec create_install_code(Ecto.UUID.t(), keyword()) ::
          {:ok, %{code: String.t(), command: String.t(), install_code: MacMiniInstallCode.t()}}
          | {:error, term()}
  def create_install_code(org_id, opts \\ []) when is_binary(org_id) do
    result =
      with %Organization{} <- Repo.get(Organization, org_id) do
        raw_code = "bfti_" <> Sessions.generate_token()

        runner_stable_id =
          normalized_runner_stable_id(Keyword.get(opts, :runner_stable_id)) ||
            "runner_" <> Sessions.generate_token()

        now = Keyword.get(opts, :now, DateTime.utc_now())
        ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

        with {:ok, server_build_id} <- server_build_id(opts) do
          audit_metadata =
            opts
            |> Keyword.get(:audit_metadata, %{})
            |> Map.new(fn {key, value} -> {to_string(key), value} end)
            |> maybe_put_runner_stable_id(runner_stable_id)
            |> Map.put("server_build_id", server_build_id)

          attrs = %{
            "org_id" => org_id,
            "created_by_id" => Keyword.get(opts, :created_by_id),
            "code_hash" => Sessions.hash_token(raw_code),
            "server_build_id" => server_build_id,
            "runner_stable_id" => runner_stable_id,
            "audit_metadata" => audit_metadata,
            "expires_at" => DateTime.add(now, ttl_seconds, :second)
          }

          create_install_code_with_optional_audit(attrs, raw_code, opts)
        end
      else
        nil -> {:error, :org_not_found}
        {:error, reason} -> {:error, reason}
      end

    maybe_record_install_code_write_attempt(result, org_id, opts)
  end

  defp create_install_code_with_optional_audit(attrs, raw_code, opts) do
    if audit_enabled?(opts) do
      Repo.transaction(fn ->
        with {:ok, install_code} <-
               %MacMiniInstallCode{} |> MacMiniInstallCode.changeset(attrs) |> Repo.insert(),
             {:ok, _audit} <- record_install_code_audit(install_code, opts) do
          %{
            code: raw_code,
            command: command(Keyword.fetch!(opts, :wrapper_url), raw_code),
            install_code: install_code
          }
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      case %MacMiniInstallCode{} |> MacMiniInstallCode.changeset(attrs) |> Repo.insert() do
        {:ok, install_code} ->
          {:ok,
           %{
             code: raw_code,
             command: command(Keyword.fetch!(opts, :wrapper_url), raw_code),
             install_code: install_code
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Consume a raw install code exactly once and lazy-mint the durable runner key.
  """
  @spec consume_install_code(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok,
           %{
             install_code: MacMiniInstallCode.t(),
             org: Organization.t(),
             token: String.t(),
             api_key: BridgeForTeams.Schema.ApiKey.t()
           }}
          | {:error, atom()}
  def consume_install_code(org_id, raw_code, opts \\ [])
      when is_binary(org_id) and is_binary(raw_code) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    code_hash = Sessions.hash_token(raw_code)

    result =
      Repo.transaction(fn ->
        install_code =
          Repo.one(
            from(c in MacMiniInstallCode,
              where: c.org_id == ^org_id and c.code_hash == ^code_hash,
              lock: "FOR UPDATE"
            )
          )

        case validate_consumable_code(install_code, now) do
          :ok ->
            org = Repo.get!(Organization, org_id)

            with {:ok, %{token: token, api_key: api_key}} <-
                   Auth.create_api_key(org_id, runner_api_key_attrs(now)),
                 {:ok, consumed} <-
                   install_code
                   |> MacMiniInstallCode.changeset(%{
                     "api_key_id" => api_key.id,
                     "consumed_at" => now
                   })
                   |> Repo.update() do
              %{
                install_code: consumed,
                org: org,
                token: token,
                api_key: api_key
              }
            else
              {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
              {:error, _reason} -> Repo.rollback(:api_key_mint_failed)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end

    maybe_record_install_code_consumption_event(result, org_id, code_hash, opts)
  end

  @doc "List durable runner keys with the stable runner identity that consumed them."
  def list_runner_credentials(org_id) when is_binary(org_id) do
    Repo.all(
      from(c in MacMiniInstallCode,
        join: key in ApiKey,
        on: key.id == c.api_key_id,
        where: c.org_id == ^org_id,
        order_by: [desc: key.created_at],
        select: {c, key}
      )
    )
    |> Enum.map(fn {install_code, api_key} ->
      %{stable_id: runner_stable_id(install_code), api_key: api_key}
    end)
  end

  @doc "Revoke every bound key and remove one org-scoped runner registration."
  def remove_runner(org_id, provisioner_id, opts \\ [])
      when is_binary(org_id) and is_binary(provisioner_id) do
    Repo.transaction(fn ->
      case Repo.get_by(MacMiniProvisioner, id: provisioner_id, org_id: org_id) do
        nil ->
          Repo.rollback(:runner_not_found)

        provisioner ->
          org_id
          |> list_runner_credentials()
          |> Enum.filter(&(&1.stable_id == provisioner.stable_id))
          |> Enum.map(& &1.api_key)
          |> Enum.filter(&is_nil(&1.revoked_at))
          |> Enum.each(fn api_key ->
            case Auth.revoke_api_key(org_id, api_key.id, opts) do
              {:ok, _api_key} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

          case Repo.delete(provisioner) do
            {:ok, deleted} -> deleted
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  defp maybe_record_install_code_consumption_event(
         {:ok, %{install_code: %MacMiniInstallCode{} = install_code}} = result,
         org_id,
         _code_hash,
         opts
       ) do
    request_id = install_code_consumption_request_id(opts)

    record_install_code_consumption_event(%{
      org_id: org_id,
      domain: "runner",
      source: "bft.dashboard",
      event_type: "runner.install_code.consumed",
      severity: "info",
      status: "consumed",
      resource_type: "runner_install_code",
      resource_id: install_code.id,
      summary: "Runner install code consumed",
      evidence: install_code_consumption_evidence(request_id, install_code),
      correlation_id: request_id
    })

    result
  end

  defp maybe_record_install_code_consumption_event(
         {:error, reason} = result,
         org_id,
         code_hash,
         opts
       ) do
    request_id = install_code_consumption_request_id(opts)
    install_code = install_code_for_consumption_event(org_id, code_hash)
    reason_class = install_code_consumption_reason_class(reason)

    record_install_code_consumption_event(%{
      org_id: org_id,
      domain: "runner",
      source: "bft.dashboard",
      event_type: "runner.install_code.consume_failed",
      severity: install_code_consumption_failure_severity(reason_class),
      status: "failed",
      reason_class: reason_class,
      resource_type: "runner_install_code",
      resource_id: install_code && install_code.id,
      summary: "Runner install code consume failed",
      evidence: install_code_consumption_evidence(request_id, install_code, reason_class),
      correlation_id: request_id
    })

    result
  end

  defp maybe_record_install_code_consumption_event(result, _org_id, _code_hash, _opts),
    do: result

  defp install_code_for_consumption_event(org_id, code_hash) do
    Repo.one(
      from(c in MacMiniInstallCode,
        where: c.org_id == ^org_id and c.code_hash == ^code_hash
      )
    )
  end

  defp record_install_code_consumption_event(attrs) do
    case Observability.create_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("runner_install_code_consumption_event_failed reason=#{inspect(reason)}")

        :ok
    end
  end

  defp install_code_consumption_evidence(request_id, install_code, reason_class \\ nil) do
    install_code_id = install_code && install_code.id
    server_build_id = install_code && install_code.server_build_id

    %{
      "install_code_id" => install_code_id,
      "server_build_id" => server_build_id,
      "request_id" => request_id,
      "reason_class" => reason_class
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp install_code_consumption_request_id(opts) do
    case Keyword.get(opts, :request_id) do
      request_id when is_binary(request_id) and request_id != "" -> request_id
      _ -> Ecto.UUID.generate()
    end
  end

  defp install_code_consumption_reason_class(%Ecto.Changeset{}), do: "validation_failed"

  defp install_code_consumption_reason_class(reason) when is_atom(reason),
    do: Atom.to_string(reason)

  defp install_code_consumption_reason_class(reason) when is_binary(reason), do: reason
  defp install_code_consumption_reason_class(_reason), do: "unknown"

  defp install_code_consumption_failure_severity("api_key_mint_failed"),
    do: "error"

  defp install_code_consumption_failure_severity(_reason_class), do: "warning"

  @doc "Render the shell wrapper returned by the public install endpoint."
  @spec wrapper_script(map()) :: String.t()
  def wrapper_script(%{
        org: %Organization{} = org,
        install_code: %MacMiniInstallCode{} = install_code,
        token: token,
        release: release
      })
      when is_map(release) do
    exports = base_exports(org, install_code, token, release)
    platform_exports = platform_exports(release)

    [
      "#!/usr/bin/env sh",
      "set -eu",
      "",
      "log() { printf '%s\\n' \"$*\" >&2; }",
      "resolve_install_home() {",
      "  if [ -n \"${BFT_INSTALL_USER:-}\" ]; then",
      "    [ \"$(id -u)\" = 0 ] || { log 'BFT_INSTALL_USER requires administrator access'; exit 1; }",
      "    install_home=$(dscl . -read \"/Users/$BFT_INSTALL_USER\" NFSHomeDirectory 2>/dev/null | awk '{print $2}')",
      "    case \"$install_home\" in /*) ;; *) log 'BFT_INSTALL_USER has no valid home directory'; exit 1 ;; esac",
      "    HOME=$install_home",
      "    export HOME",
      "  fi",
      "}",
      "log 'BridgeForTeams runner'",
      "log #{shell_quote("Org: #{org.name}")}",
      "log #{shell_quote("Org ID: #{org.id}")}",
      "log 'Mode: install runner'",
      "log #{shell_quote("Server build: #{install_code.server_build_id}")}",
      "log #{shell_quote("Install prefix: #{display_path(release_value(release, :install_prefix, @default_install_prefix))}")}",
      "log #{shell_quote("Status: #{display_path(status_path(release))}")}",
      "log 'Launchd: none'",
      "log ''",
      "log '[ok] Install code accepted'",
      "",
      "resolve_install_home",
      Enum.map_join(exports, "\n", &render_export/1),
      platform_exports,
      "",
      @installer_source
    ]
    |> Enum.join("\n")
  end

  @doc "Render a redacted shell error response instead of HTML."
  @spec error_script(atom() | String.t(), keyword()) :: String.t()
  def error_script(reason, _opts \\ []) do
    reason = error_reason_label(reason)

    [
      "#!/usr/bin/env sh",
      "set -eu",
      "printf '%s\\n' 'BridgeForTeams runner' >&2",
      "printf '%s\\n' #{shell_quote("Status: failed")} >&2",
      "printf '%s\\n' #{shell_quote("Reason: #{reason}")} >&2",
      "printf '%s\\n' 'Next: generate a fresh runner install command from BridgeForTeams settings' >&2",
      "exit 1",
      ""
    ]
    |> Enum.join("\n")
  end

  defp error_reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason_label(reason) when is_binary(reason), do: reason
  defp error_reason_label({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason_label(_reason), do: "install_unavailable"

  defp command(wrapper_url, raw_code) do
    uri =
      wrapper_url
      |> URI.parse()
      |> URI.append_query(URI.encode_query(%{"code" => raw_code}))
      |> URI.to_string()

    ~s(curl -fsSL "#{uri}" | sh)
  end

  defp validate_consumable_code(nil, _now), do: {:error, :invalid_code}

  defp validate_consumable_code(%MacMiniInstallCode{consumed_at: %DateTime{}}, _now),
    do: {:error, :code_already_consumed}

  defp validate_consumable_code(%MacMiniInstallCode{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      {:error, :code_expired}
    end
  end

  defp runner_api_key_attrs(now) do
    %{
      "name" => "Runner install #{Calendar.strftime(now, "%Y-%m-%d %H:%M UTC")}",
      "scopes" => ["runners:write"]
    }
  end

  defp base_exports(org, install_code, token, release) do
    [
      {"BFT_API_BASE_URL", release_value(release, :api_base_url, ""), :literal},
      {"BFT_ORG_ID", org.id, :literal},
      {"BFT_RUNNER_TOKEN", token, :literal},
      {"BFT_RUNNER_STABLE_ID", runner_stable_id(install_code), :literal},
      {"BFT_INSTALL_PREFIX", release_value(release, :install_prefix, @default_install_prefix),
       :path},
      {"BFT_STATE_DIR", release_value(release, :state_dir, @default_state_dir), :path},
      {"BFT_LAUNCHD_LABEL", release_value(release, :launchd_label, @default_launchd_label),
       :literal}
    ]
    |> Enum.reject(fn {_key, value, _mode} -> value in [nil, ""] end)
  end

  defp platform_exports(%{targets: targets}) when is_map(targets) do
    targets
    |> Map.take(["darwin-arm64"])
    |> Map.new(fn {platform, components} ->
      exports =
        for {component, prefix} <- [
              {"runner", "BFT_RUNNER"},
              {"salix-connect", "BFT_SALIX_CONNECTOR"},
              {"agent-vmm-host", "BFT_AGENT_VMM_HOST"}
            ],
            {field, suffix} <- [{"source", "URL"}, {"sha256", "SHA256"}, {"size", "SIZE"}],
            into: %{} do
          {prefix <> "_" <> suffix, target_field(components, component, field)}
        end

      {platform, exports}
    end)
    |> SalixStore.ConnectorInstall.artifact_exports()
  end

  defp target_field(components, component, field) do
    components
    |> Map.fetch!(component)
    |> then(&(Map.get(&1, field) || Map.fetch!(&1, String.to_existing_atom(field))))
  end

  defp normalized_runner_stable_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      stable_id -> stable_id
    end
  end

  defp normalized_runner_stable_id(_), do: nil

  defp server_build_id(opts) do
    case Keyword.get(opts, :server_build_id) do
      value when is_binary(value) and byte_size(value) in 1..200 -> {:ok, value}
      _ -> {:error, :server_release_unavailable}
    end
  end

  defp runner_stable_id(%MacMiniInstallCode{
         id: id,
         runner_stable_id: stable_id,
         audit_metadata: metadata
       })
       when is_binary(id) do
    case stable_id || install_code_runner_stable_id(id, metadata) do
      stable_id when is_binary(stable_id) and stable_id != "" -> stable_id
      _ -> "runner_" <> String.replace(id, "-", "")
    end
  end

  defp install_code_runner_stable_id(_id, %{"runner_stable_id" => stable_id}), do: stable_id
  defp install_code_runner_stable_id(_id, _metadata), do: nil

  defp maybe_put_runner_stable_id(metadata, stable_id)
       when is_binary(stable_id) and stable_id != "",
       do: Map.put(metadata, "runner_stable_id", stable_id)

  defp maybe_put_runner_stable_id(metadata, _stable_id), do: metadata

  defp status_path(release) do
    Path.join(
      release_value(release, :install_prefix, @default_install_prefix),
      "runner-install-status.json"
    )
  end

  defp release_value(release, key, default) do
    Map.get(release, key, Map.get(release, Atom.to_string(key), default))
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp render_export({key, value, :path}) do
    value = to_string(value || "")

    if String.starts_with?(value, "$HOME/") do
      suffix = String.trim_leading(value, "$HOME/")
      ~s(export #{key}="$HOME"#{shell_quote("/" <> suffix)})
    else
      "export #{key}=#{shell_quote(value)}"
    end
  end

  defp render_export({key, value, _mode}) do
    "export #{key}=#{shell_quote(value)}"
  end

  defp display_path("$HOME/" <> rest), do: "~/" <> rest
  defp display_path(value), do: value

  defp shell_quote(value) do
    value = to_string(value || "")
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp record_install_code_audit(%MacMiniInstallCode{} = install_code, opts) do
    Observability.record_audit(%{
      org_id: install_code.org_id,
      actor_user_id: Keyword.get(opts, :actor_user_id) || Keyword.get(opts, :created_by_id),
      actor_label: Keyword.get(opts, :actor_label),
      action: "runner_install_code.created",
      resource_type: "runner_install_code",
      resource_id: install_code.id,
      resource_label: "Runner install command",
      result: "ok",
      request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
      metadata:
        %{
          "install_code_id" => install_code.id,
          "server_build_id" => install_code.server_build_id,
          "expires_at" => install_code.expires_at
        }
        |> Map.merge(Keyword.get(opts, :audit_metadata, %{})),
      redacted_diff: %{"install_code" => %{"from" => nil, "to" => install_code.id}}
    })
  end

  defp maybe_record_install_code_write_attempt({:error, reason} = result, org_id, opts) do
    if audit_enabled?(opts) do
      case Observability.record_write_attempt(%{
             org_id: org_id,
             actor_user_id:
               Keyword.get(opts, :actor_user_id) || Keyword.get(opts, :created_by_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: "runner_install_code.created",
             resource_type: "runner_install_code",
             resource_label: "Runner install command",
             result: "failed",
             reason: reason,
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             surface: "runner_install_code",
             metadata: install_code_attempt_metadata(opts)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, audit_reason} ->
          Logger.warning(
            "runner_install_code_write_attempt_audit_failed reason=#{inspect(audit_reason)}"
          )
      end
    end

    result
  end

  defp maybe_record_install_code_write_attempt(result, _org_id, _opts), do: result

  defp install_code_attempt_metadata(opts) do
    audit_metadata = Keyword.get(opts, :audit_metadata, %{})

    %{
      "rotated_key_id" => audit_metadata["rotated_key_id"] || audit_metadata[:rotated_key_id]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      not is_nil(present(Keyword.get(opts, :actor_user_id))) ||
      not is_nil(present(Keyword.get(opts, :created_by_id))) ||
      not is_nil(present(Keyword.get(opts, :actor_label)))
  end
end
