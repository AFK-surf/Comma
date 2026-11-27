defmodule SalixMCP.Credentials do
  @moduledoc """
  Credential resolver seam for MCP bindings.

  MCP bindings only store references to credentials. The concrete resolver lives
  in the composition layer that owns OAuth and other credential domains.
  """

  @callback resolve(binding :: map()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  @callback resolve_remote_headers(definition :: map(), binding :: map()) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}
  @callback redaction_values(definition :: map(), binding :: map()) :: [String.t()]
  @callback start_remote_authorization(
              tenant_id :: String.t(),
              group_id :: String.t(),
              binding_id :: String.t(),
              params :: map()
            ) :: {:ok, map()} | {:error, term()}
  @callback invalidate_remote_oauth_binding(binding :: map(), reason :: String.t()) ::
              :ok | {:error, term()}
  @callback mark_remote_oauth_reauthorization_required(binding :: map(), reason :: String.t()) ::
              :ok | {:error, term()}
  # The server refused the managed OAuth tokens a binding's
  # `oauth_binding_refs` resolved to.
  @callback oauth_refs_refused(binding :: map()) :: :ok

  # A binding whose definition runs each call as the person who asked
  # (`SalixMCP.HostedServices.per_requester?/1`): `requester` is that person's
  # encoded principal, from the turn's sealed origin.
  @callback requester_headers(binding :: map(), requester :: String.t()) ::
              {:ok, %{String.t() => String.t()}} | {:error, :sign_in_required | term()}
  @callback request_requester_sign_in(binding :: map(), requester :: String.t(), waiter :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback requester_sign_in_rejected(binding :: map(), requester :: String.t()) :: :ok
  @callback binding_deleted(binding :: map()) :: :ok | {:error, term()}

  @optional_callbacks resolve_remote_headers: 2,
                      requester_headers: 2,
                      request_requester_sign_in: 3,
                      requester_sign_in_rejected: 2,
                      binding_deleted: 1,
                      redaction_values: 2,
                      start_remote_authorization: 4,
                      invalidate_remote_oauth_binding: 2,
                      mark_remote_oauth_reauthorization_required: 2,
                      oauth_refs_refused: 1

  def resolve(%{"mcp_id" => "mcp1_0000000000000000009"} = binding),
    do: resolve_with_owner(binding)

  def resolve(%{"oauth_binding_refs" => refs} = binding)
      when is_map(refs) and map_size(refs) > 0,
      do: resolve_with_owner(binding)

  def resolve(_binding), do: {:ok, %{}}

  defp resolve_with_owner(binding) do
    case SystemsRuntime.get_env(:salix_mcp, :credential_resolver_mod) do
      nil -> {:error, {:missing_oauth, "MCP OAuth credential resolver is not configured"}}
      mod -> mod.resolve(binding)
    end
  end

  def resolve_remote_headers(definition, binding) do
    case resolver_mod() do
      nil ->
        {:ok, %{}}

      mod ->
        if exported?(mod, :resolve_remote_headers, 2) do
          mod.resolve_remote_headers(definition, binding)
        else
          {:ok, %{}}
        end
    end
  end

  def redaction_values(definition, binding) do
    case resolver_mod() do
      nil ->
        []

      mod ->
        if exported?(mod, :redaction_values, 2) do
          mod.redaction_values(definition, binding)
        else
          []
        end
    end
  end

  def start_remote_authorization(tenant_id, group_id, binding_id, params) do
    case resolver_mod() do
      nil ->
        {:error, {:precondition_failed, "remote MCP OAuth resolver is not configured"}}

      mod ->
        if exported?(mod, :start_remote_authorization, 4) do
          mod.start_remote_authorization(tenant_id, group_id, binding_id, params)
        else
          {:error, {:precondition_failed, "remote MCP OAuth resolver is not configured"}}
        end
    end
  end

  def invalidate_remote_oauth_binding(binding, reason) do
    case resolver_mod() do
      nil ->
        :ok

      mod ->
        if exported?(mod, :invalidate_remote_oauth_binding, 2) do
          mod.invalidate_remote_oauth_binding(binding, reason)
        else
          :ok
        end
    end
  end

  def mark_remote_oauth_reauthorization_required(binding, reason) do
    case resolver_mod() do
      nil ->
        :ok

      mod ->
        if exported?(mod, :mark_remote_oauth_reauthorization_required, 2) do
          mod.mark_remote_oauth_reauthorization_required(binding, reason)
        else
          :ok
        end
    end
  end

  def oauth_refs_refused(%{"oauth_binding_refs" => refs} = binding)
      when is_map(refs) and map_size(refs) > 0,
      do: optional(:oauth_refs_refused, [binding], :ok)

  def oauth_refs_refused(_binding), do: :ok

  def requester_headers(binding, requester),
    do: optional(:requester_headers, [binding, requester], {:error, :sign_in_required})

  def request_requester_sign_in(binding, requester, waiter),
    do:
      optional(
        :request_requester_sign_in,
        [binding, requester, waiter],
        {:error, "personal sign-in is not available on this server"}
      )

  def requester_sign_in_rejected(binding, requester),
    do: optional(:requester_sign_in_rejected, [binding, requester], :ok)

  def binding_deleted(binding), do: optional(:binding_deleted, [binding], :ok)

  defp optional(fun, args, default) do
    mod = resolver_mod()

    if mod && exported?(mod, fun, length(args)),
      do: apply(mod, fun, args),
      else: default
  end

  defp resolver_mod, do: SystemsRuntime.get_env(:salix_mcp, :credential_resolver_mod)

  defp exported?(mod, fun, arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
end
