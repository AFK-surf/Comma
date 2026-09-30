defmodule Comma.Synchronicity.HTTP do
  @moduledoc """
  Req adapter for the Synchronicity control-plane internal routes under
  `/internal/v1/integrations/comma/workspaces/{workspace_id}`, all with the
  shared provisioning bearer: `PUT` provisions the Workspace's org + default
  network and ensures the owner's identity/membership (idempotent by
  workspace id); `POST .../devices` enrolls a device; `POST .../api-keys`
  mints a member org key for the Workspace's org and `DELETE
  .../api-keys/{key_id}` revokes one.

  The provisioning secret and base URL come from `:comma_core, :synchronicity`
  config and never leave the server. Responses are classified into a small
  tagged set that convergence maps to a durable outcome.
  """

  @behaviour Comma.Synchronicity.Client

  @receive_timeout 15_000

  @impl true
  def provision_workspace(workspace_id, workspace_name, owner)
      when is_binary(workspace_id) and is_binary(workspace_name) and is_map(owner) do
    config = Comma.Synchronicity.config!()

    options =
      [
        method: :put,
        url:
          config.base_url <>
            "/internal/v1/integrations/comma/workspaces/" <> URI.encode(workspace_id),
        headers: [{"authorization", "Bearer " <> config.provisioning_secret}],
        json: %{"name" => workspace_name, "owner" => owner_body(owner)},
        receive_timeout: @receive_timeout,
        retry: false
      ] ++ config.req_options

    case Req.request(Req.new(options)) do
      {:ok, %Req.Response{status: status, body: body}} -> classify(status, body)
      {:error, reason} -> {:error, {:retryable, transport_reason(reason)}}
    end
  end

  @impl true
  def enroll_device(workspace_id, nk, label, owner)
      when is_binary(workspace_id) and is_binary(nk) and is_binary(label) and is_map(owner) do
    config = Comma.Synchronicity.config!()

    options =
      [
        method: :post,
        url:
          config.base_url <>
            "/internal/v1/integrations/comma/workspaces/" <>
            URI.encode(workspace_id) <> "/devices",
        headers: [{"authorization", "Bearer " <> config.provisioning_secret}],
        json: %{"nk" => nk, "label" => label, "owner" => owner_body(owner)},
        receive_timeout: @receive_timeout,
        retry: false
      ] ++ config.req_options

    case Req.request(Req.new(options)) do
      {:ok, %Req.Response{status: status, body: body}} -> classify_device(status, body)
      {:error, reason} -> {:error, {:retryable, transport_reason(reason)}}
    end
  end

  @impl true
  def mint_api_key(workspace_id, owner, name)
      when is_binary(workspace_id) and is_map(owner) and is_binary(name) do
    config = Comma.Synchronicity.config!()

    options =
      [
        method: :post,
        url:
          config.base_url <>
            "/internal/v1/integrations/comma/workspaces/" <>
            URI.encode(workspace_id) <> "/api-keys",
        headers: [{"authorization", "Bearer " <> config.provisioning_secret}],
        json: %{"name" => name, "owner" => owner_body(owner)},
        receive_timeout: @receive_timeout,
        retry: false
      ] ++ config.req_options

    case Req.request(Req.new(options)) do
      {:ok, %Req.Response{status: status, body: body}} -> classify_key(status, body)
      {:error, reason} -> {:error, {:retryable, transport_reason(reason)}}
    end
  end

  @impl true
  def revoke_api_key(workspace_id, key_id) when is_binary(workspace_id) and is_binary(key_id) do
    config = Comma.Synchronicity.config!()

    options =
      [
        method: :delete,
        url:
          config.base_url <>
            "/internal/v1/integrations/comma/workspaces/" <>
            URI.encode(workspace_id) <> "/api-keys/" <> URI.encode(key_id),
        headers: [{"authorization", "Bearer " <> config.provisioning_secret}],
        receive_timeout: @receive_timeout,
        retry: false
      ] ++ config.req_options

    case Req.request(Req.new(options)) do
      {:ok, %Req.Response{status: status, body: body}} -> classify_revoke(status, body)
      {:error, reason} -> {:error, {:retryable, transport_reason(reason)}}
    end
  end

  @doc """
  Maps an HTTP status + decoded body to a durable outcome. Pure, so the
  branching is unit-tested without a transport. Success is nested under
  `result` (the create path wraps it with the zone serial). `org_slug` is
  what the org API routes by; a control plane that predates it answers
  without one, and the slug then arrives with the first minted key.
  """
  def classify(status, %{"result" => result}) when status in 200..299 do
    case result do
      %{
        "org_id" => org_id,
        "network_id" => network_id,
        "sync_user_id" => sync_user_id,
        "created" => created
      } ->
        {:ok,
         %{
           sync_org_id: org_id,
           sync_org_slug: optional_string(result["org_slug"]),
           sync_network_id: network_id,
           sync_user_id: sync_user_id,
           created: created
         }}

      _ ->
        {:error, {:invalid, :malformed_success_body}}
    end
  end

  def classify(status, _body) when status in 200..299,
    do: {:error, {:invalid, :malformed_success_body}}

  def classify(409, body) do
    case error_code(body) do
      "explicit_link_required" -> {:error, :explicit_link_required}
      other -> {:error, {:invalid, {:conflict, other}}}
    end
  end

  def classify(status, _body) when status in [401, 403], do: {:error, :auth}

  def classify(status, _body) when status == 429 or status in 500..599,
    do: {:error, {:retryable, {:status, status}}}

  def classify(400, body), do: {:error, {:invalid, {:bad_request, error_code(body)}}}

  def classify(status, _body), do: {:error, {:invalid, {:unexpected_status, status}}}

  @doc """
  Device-enrollment counterpart to `classify/2`. Success carries the device id
  + assigned network + domain; a 404 means the Workspace has no org yet.
  """
  def classify_device(status, %{"result" => result}) when status in 200..299 do
    case result do
      %{
        "device_id" => device_id,
        "network" => network,
        "domain" => domain,
        "created" => created
      } ->
        {:ok, %{device_id: device_id, network: network, domain: domain, created: created}}

      _ ->
        {:error, {:invalid, :malformed_success_body}}
    end
  end

  def classify_device(status, _body) when status in 200..299,
    do: {:error, {:invalid, :malformed_success_body}}

  def classify_device(404, _body), do: {:error, :not_provisioned}

  def classify_device(409, body),
    do: {:error, {:invalid, {:conflict, error_code(body)}}}

  def classify_device(status, _body) when status in [401, 403], do: {:error, :auth}

  def classify_device(status, _body) when status == 429 or status in 500..599,
    do: {:error, {:retryable, {:status, status}}}

  def classify_device(400, body), do: {:error, {:invalid, {:bad_request, error_code(body)}}}

  def classify_device(status, _body), do: {:error, {:invalid, {:unexpected_status, status}}}

  @doc """
  Key-mint counterpart to `classify/2`. Success carries the one-time token
  beside the ids the org API routes by; a 404 means the Workspace has no org
  yet.
  """
  def classify_key(status, %{"result" => result}) when status in 200..299 do
    case result do
      %{
        "key_id" => key_id,
        "token" => token,
        "prefix" => prefix,
        "org_id" => org_id,
        "org_slug" => org_slug,
        "network" => network,
        "expires_at" => expires_at
      }
      when is_binary(key_id) and is_binary(token) and is_binary(org_slug) and
             is_integer(expires_at) ->
        {:ok,
         %{
           key_id: key_id,
           token: token,
           prefix: prefix,
           org_id: org_id,
           org_slug: org_slug,
           network: network,
           expires_at: expires_at
         }}

      _ ->
        {:error, {:invalid, :malformed_success_body}}
    end
  end

  def classify_key(status, _body) when status in 200..299,
    do: {:error, {:invalid, :malformed_success_body}}

  def classify_key(404, _body), do: {:error, :not_provisioned}
  def classify_key(status, _body) when status in [401, 403], do: {:error, :auth}

  def classify_key(status, _body) when status == 429 or status in 500..599,
    do: {:error, {:retryable, {:status, status}}}

  def classify_key(400, body), do: {:error, {:invalid, {:bad_request, error_code(body)}}}
  def classify_key(status, _body), do: {:error, {:invalid, {:unexpected_status, status}}}

  @doc """
  Revocation outcome. A 404 is `:not_found` whether the key was never this
  Workspace's or is already gone; the control plane answers the same for both.
  """
  def classify_revoke(status, _body) when status in 200..299, do: :ok

  def classify_revoke(404, body) do
    case error_code(body) do
      "workspace_not_provisioned" -> {:error, :not_provisioned}
      _ -> {:error, :not_found}
    end
  end

  def classify_revoke(status, _body) when status in [401, 403], do: {:error, :auth}

  def classify_revoke(status, _body) when status == 429 or status in 500..599,
    do: {:error, {:retryable, {:status, status}}}

  def classify_revoke(400, body), do: {:error, {:invalid, {:bad_request, error_code(body)}}}
  def classify_revoke(status, _body), do: {:error, {:invalid, {:unexpected_status, status}}}

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_value), do: nil

  defp owner_body(%{subject: subject, email: email, name: name}) when is_binary(name),
    do: %{"subject" => subject, "email" => email, "name" => name}

  defp owner_body(%{subject: subject, email: email}),
    do: %{"subject" => subject, "email" => email}

  defp error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp error_code(_), do: nil

  defp transport_reason(%{__struct__: struct, reason: reason}), do: {struct, reason}
  defp transport_reason(%{__struct__: struct}), do: struct
  defp transport_reason(reason), do: reason
end
