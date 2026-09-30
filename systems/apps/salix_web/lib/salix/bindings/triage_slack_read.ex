defmodule Salix.Bindings.TriageSlackRead do
  @moduledoc """
  One evaluator-owned Slack permalink read with opaque model arguments.

  The model cannot select a connection, channel or timestamp. The frozen source
  authority supplies the connection. The source channel must remain authorized;
  the linked target channel must independently be enabled on that installation.
  Slack auth.test binds the URL host to the installation. Existing IM dispatch
  consumes the captured installation pin before reading, so reconnect cannot
  substitute a different workspace.
  """

  alias SalixAgent.{SessionToolDispatch, ToolDisclosure}
  alias SalixIM.{GroupDirectory, ProviderConnects}
  alias SalixIM.Provider.Slack.API
  alias SalixIM.Triage.{CanonicalJSON, SlackPermalink}

  @name "triage.slack_read_permalink"
  @authority_keys ~w(provider tenant_id group_id connect_id connect_generation workspace_id approved_channel_id inbound_agent_id app_id bot_user_id bot_id)
  @pin_keys ~w(tenant_id group_id connect_id connect_generation workspace_id)

  def valid_authority?(authority) when is_map(authority) do
    Enum.sort(Map.keys(authority)) == Enum.sort(@authority_keys) and
      authority["provider"] == "slack" and
      Enum.all?(@authority_keys, &(is_binary(authority[&1]) and authority[&1] != ""))
  end

  def valid_authority?(_), do: false

  def disclosure do
    %{
      "revision" => "triage-slack-read-v1",
      "tools" => [
        %{
          "name" => @name,
          "prompt_visibility" => "manual",
          "summary" => "Read the exact message behind one authorized Slack permalink.",
          "manual_available" => true,
          "helpable" => false,
          "callable" => true,
          "safety" => "read",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"link_ref" => %{"type" => "string"}},
            "required" => ["link_ref"],
            "additionalProperties" => false
          },
          "manual" =>
            "Use exactly the decision target link_ref. Never supply raw Slack coordinates.",
          "examples" => %{},
          "discovery_sources" => []
        }
      ]
    }
  end

  def execute(call, context, target) do
    authority = context.slack_source_authority

    with {:ok, coordinates} <- SlackPermalink.parse(target["resolved_url"]),
         {:ok, scope} <- GroupDirectory.scope_for_agent(context.agent_id),
         {:ok, connect} <-
           ProviderConnects.get_agent_visible_connect_by_id(
             scope,
             authority["connect_id"],
             "slack"
           ),
         true <- connect["workspace_id"] == authority["workspace_id"],
         :ok <- verify_workspace(connect, coordinates),
         :ok <- authorize_source(context, authority),
         :ok <- authorize_target(context, authority, coordinates),
         {:ok, result} <- dispatch(call, context, connect, coordinates) do
      exact_message_result(result, coordinates)
    else
      {:error, reason}
      when reason in [
             :invalid_slack_permalink,
             :slack_source_changed,
             :slack_target_not_authorized,
             :slack_workspace_unverified
           ] ->
        failure(reason)

      _ ->
        failure(:slack_source_unavailable)
    end
  rescue
    _ -> failure(:slack_source_unavailable)
  catch
    :exit, _ -> failure(:slack_source_unavailable)
  end

  defp authorize_source(context, authority) do
    with true <- valid_authority?(authority),
         true <- authority["tenant_id"] == context.tenant_id,
         true <- authority["group_id"] == context.group_id,
         true <- authority["inbound_agent_id"] == context.agent_id,
         {:ok, current} <-
           ProviderConnects.get_slack_triage_authority(
             context.tenant_id,
             context.group_id,
             authority["connect_id"],
             authority["approved_channel_id"]
           ),
         true <- Map.take(current, @authority_keys) == authority do
      :ok
    else
      _ -> {:error, :slack_source_changed}
    end
  end

  defp authorize_target(context, authority, coordinates) do
    case ProviderConnects.get_slack_triage_authority(
           context.tenant_id,
           context.group_id,
           authority["connect_id"],
           coordinates.channel
         ) do
      {:ok, _current_target} -> :ok
      {:error, :slack_triage_authority_ineligible} -> {:error, :slack_target_not_authorized}
      _unavailable -> {:error, :slack_source_unavailable}
    end
  end

  # The permalink is untrusted input. Only the authenticated provider response
  # supplies the expected host; source workspace identity alone is not a URL.
  defp verify_workspace(connect, coordinates) do
    identity = connect |> API.installation() |> API.auth_test()

    case URI.parse(identity["url"] || "") do
      %URI{scheme: "https", host: host, userinfo: nil, port: 443} ->
        if identity["team_id"] == connect["workspace_id"] and
             is_binary(host) and String.downcase(host) == coordinates.host,
           do: :ok,
           else: {:error, :slack_workspace_unverified}

      _ ->
        {:error, :slack_workspace_unverified}
    end
  rescue
    _ -> {:error, :slack_workspace_unverified}
  end

  defp dispatch(call, context, connect, coordinates) do
    leaf =
      if coordinates.thread_ts,
        do: "im_api.slack.get_thread_replies",
        else: "im_api.slack.get_channel_history"

    params = %{
      "connect_id" => connect["connect_id"],
      "channel" => coordinates.channel,
      "oldest" => coordinates.message_ts,
      "latest" => coordinates.message_ts,
      "inclusive" => true,
      "limit" => 1
    }

    params =
      if coordinates.thread_ts, do: Map.put(params, "ts", coordinates.thread_ts), else: params

    actual_call = %{call | args: %{"tool" => leaf, "params" => params}}

    # A dispatch context carries the activation's admitted source ids as data;
    # the session itself stays with the kernel. This read runs under the
    # Triage authority alone, so it declares none.
    actual_context =
      context
      |> Map.put(:triage_slack_read_source, Map.take(connect, @pin_keys))
      |> Map.put_new(:source_message_ids, [])

    disclosure = ToolDisclosure.materialize(context.role, :internal, actual_context)

    with %{"safety" => "read", "callable" => true} = entry <-
           Enum.find(disclosure["tools"], &(&1["name"] == leaf)),
         [result] <-
           SessionToolDispatch.execute(
             [actual_call],
             Map.put(actual_context, :tool_disclosure, %{disclosure | "tools" => [entry]})
           ),
         true <- result[:events] in [nil, []] do
      {:ok, result}
    else
      _ -> {:error, :slack_source_unavailable}
    end
  end

  defp exact_message_result(%{error: false, content: content} = result, coordinates) do
    with {:ok, page} <- Jason.decode(content),
         messages when is_list(messages) <- page["messages"],
         %{"text" => text} = message <-
           Enum.find(messages, &(&1["ts"] == coordinates.message_ts)),
         true <- is_binary(text) and String.trim(text) != "",
         true <- message["stale"] != true do
      body = %{
        "messages" => [
          Map.take(message, ~w(ts text thread_ts files source_references task_cards))
        ]
      }

      body =
        if page["incomplete"], do: Map.put(body, "incomplete", page["incomplete"]), else: body

      %{result | content: CanonicalJSON.encode!(body)}
    else
      _ -> failure(:slack_exact_message_unavailable)
    end
  end

  defp exact_message_result(_result, _coordinates), do: failure(:slack_source_unavailable)

  defp failure(reason) do
    %{
      content: CanonicalJSON.encode!(%{"error" => Atom.to_string(reason)}),
      status: "error",
      error: true,
      error_class: "tool_error",
      events: []
    }
  end
end
