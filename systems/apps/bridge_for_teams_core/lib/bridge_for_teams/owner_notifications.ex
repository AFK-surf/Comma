defmodule BridgeForTeams.OwnerNotifications do
  @moduledoc """
  Emails an Agent Swarm's owners about a problem only they can fix. Salix
  reports the problem through `SalixAgent.Ports.OwnerAlerts`; this module
  records it, and `BridgeForTeams.OwnerNotifications.Worker` sends it from a
  fixed template through `BridgeForTeams.TeamsMail`.

  The owners are every user whose effective role on the swarm is admin: an
  explicit project `"admin"` grant, or an org owner or admin. Agents never
  see the recipients or write the text.

  Kinds (see `SalixAgent.Ports.OwnerAlerts` for their facts):

    * `"model_failing"`: an agent stopped because its model calls kept failing.
    * `"reauthorization_required"`: an OAuth connection must be reconnected.

  A swarm gets at most one email a UTC day for each kind and subject
  (`dedupe_key`). Alerts for groups that are not a live swarm are ignored.
  """

  import Ecto.Query

  alias BridgeForTeams.Repo

  alias BridgeForTeams.Schema.{
    Agent,
    Organization,
    OrgMembership,
    OwnerNotification,
    Project,
    ProjectMembership
  }

  @kinds ~w(model_failing reauthorization_required)
  @fact_keys ~w(agent_id category status quota_exhausted provider alias)
  @max_text 120

  @doc "The `SalixAgent.Ports.OwnerAlerts` callback (set at application start)."
  @spec owner_alert(String.t(), String.t(), String.t(), map()) :: :ok
  def owner_alert(group_id, kind, ref, facts)
      when kind in @kinds and is_binary(group_id) and is_binary(ref) and is_map(facts) do
    case live_project(group_id) do
      %Project{} = project -> record(project, kind, ref, facts)
      nil -> :ok
    end
  end

  def owner_alert(_group_id, _kind, _ref, _facts), do: :ok

  @doc "Record one notification for `project`, unless one for the same subject exists today."
  @spec record(Project.t(), String.t(), String.t(), map()) :: :ok
  def record(%Project{} = project, kind, ref, facts) do
    now = SystemsClock.timestamp(:utc_datetime_usec)
    ref = clip(ref, 255 - 40)

    Repo.insert(
      %OwnerNotification{
        project_id: project.id,
        kind: kind,
        ref: ref,
        dedupe_key: "#{kind}:#{ref}:#{Date.to_iso8601(DateTime.to_date(now))}",
        facts: sanitize(facts),
        send_after: now
      },
      on_conflict: :nothing,
      conflict_target: [:project_id, :dedupe_key]
    )

    :ok
  end

  @doc """
  The swarm's owner emails: explicit project admins plus the org's owners and
  admins, without blanks or case duplicates.
  """
  @spec owner_emails(Project.t()) :: [String.t()]
  def owner_emails(%Project{} = project) do
    explicit =
      from(m in ProjectMembership,
        join: u in assoc(m, :user),
        where: m.project_id == ^project.id and m.role == "admin",
        select: u.email
      )

    derived =
      from(m in OrgMembership,
        join: u in assoc(m, :user),
        where: m.org_id == ^project.org_id and m.role in ["owner", "admin"],
        select: u.email
      )

    (Repo.all(explicit) ++ Repo.all(derived))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.sort()
  end

  @doc """
  The email for a notification: `{subject, body}`, in the org's default
  language (`en` or `zh_Hans`). `base_url` is the dashboard's public URL.
  """
  @spec render(OwnerNotification.t(), Project.t(), Organization.t(), String.t() | nil) ::
          {String.t(), String.t()}
  def render(%OwnerNotification{} = n, %Project{} = project, %Organization{} = org, base_url) do
    locale = if org.default_locale == "zh_Hans", do: :zh, else: :en
    template(n.kind, locale, n.facts, project, org, link(n.kind, n.facts, project, org, base_url))
  end

  defp template("model_failing", :en, facts, project, org, url) do
    {"[Action needed] #{project.name}: an agent's model keeps failing",
     """
     An agent in the Agent Swarm "#{project.name}" (#{org.name}) has stopped working: its model calls kept failing.

     Agent: #{agent_label(facts["agent_id"], :en)}
     Reason: #{model_reason(facts, :en)}

     Check the swarm's model settings and provider account#{link_line(url, :en)}

     The agent resumes on its next message. You get at most one such email a day for this agent.
     """}
  end

  defp template("model_failing", :zh, facts, project, org, url) do
    {"【需处理】#{project.name}：agent 的模型调用持续失败",
     """
     Agent Swarm「#{project.name}」（#{org.name}）中的一个 agent 已停止工作：模型调用连续失败。

     Agent：#{agent_label(facts["agent_id"], :zh)}
     原因：#{model_reason(facts, :zh)}

     请检查这个 swarm 的模型设置和模型服务账号#{link_line(url, :zh)}

     agent 收到下一条消息时会重新尝试。同一个 agent 每天最多收到一封这类邮件。
     """}
  end

  defp template("reauthorization_required", :en, facts, project, org, url) do
    {"[Action needed] #{project.name}: reconnect #{provider_name(facts["provider"])}",
     """
     The #{provider_name(facts["provider"])} connection#{alias_part(facts["alias"], :en)} in the Agent Swarm "#{project.name}" (#{org.name}) can no longer refresh its access, so agents cannot use it.

     Reconnect it#{link_line(url, :en)}

     You get at most one such email a day for this connection.
     """}
  end

  defp template("reauthorization_required", :zh, facts, project, org, url) do
    {"【需处理】#{project.name}：请重新连接 #{provider_name(facts["provider"])}",
     """
     Agent Swarm「#{project.name}」（#{org.name}）中的 #{provider_name(facts["provider"])} 连接#{alias_part(facts["alias"], :zh)}已无法刷新授权，agent 暂时用不了它。

     请重新连接#{link_line(url, :zh)}

     同一个连接每天最多收到一封这类邮件。
     """}
  end

  defp model_reason(%{"quota_exhausted" => true}, :en),
    do: "the model provider account has run out of balance or quota."

  defp model_reason(%{"quota_exhausted" => true}, :zh), do: "模型服务账号的余额或额度已用完。"

  defp model_reason(%{"status" => status}, :en) when is_integer(status),
    do: "the model provider kept answering HTTP #{status}."

  defp model_reason(%{"status" => status}, :zh) when is_integer(status),
    do: "模型服务持续返回 HTTP #{status}。"

  defp model_reason(facts, :en),
    do: "the model provider kept returning errors (#{facts["category"] || "unknown"})."

  defp model_reason(facts, :zh), do: "模型服务持续返回错误（#{facts["category"] || "unknown"}）。"

  defp agent_label(agent_id, locale) when is_binary(agent_id) do
    case Repo.one(
           from(a in Agent, where: a.salix_agent_id == ^agent_id, select: a.role, limit: 1)
         ) do
      "router" when locale == :zh -> "Router（主 agent）"
      "router" -> "Router"
      _worker when locale == :zh -> "Worker（#{agent_id}）"
      _worker -> "Worker (#{agent_id})"
    end
  end

  defp agent_label(_agent_id, _locale), do: "-"

  defp alias_part(alias_name, :en) when is_binary(alias_name) and alias_name != "",
    do: " \"#{alias_name}\""

  defp alias_part(alias_name, :zh) when is_binary(alias_name) and alias_name != "",
    do: "「#{alias_name}」"

  defp alias_part(_alias_name, _locale), do: ""

  @provider_names %{
    "google" => "Google",
    "github" => "GitHub",
    "slack" => "Slack",
    "notion" => "Notion",
    "linear" => "Linear",
    "feishu" => "Feishu",
    "lark" => "Lark",
    "microsoft" => "Microsoft",
    "x" => "X",
    "remote_mcp" => "MCP"
  }

  defp provider_name(provider) when is_binary(provider),
    do: Map.get(@provider_names, provider, provider)

  defp provider_name(_provider), do: "OAuth"

  defp link_line(nil, :en), do: " in the Comma for Teams dashboard."
  defp link_line(nil, :zh), do: "（在 Comma for Teams 控制台中操作）。"
  defp link_line(url, :en), do: ":\n#{url}"
  defp link_line(url, :zh), do: "：\n#{url}"

  defp link(kind, _facts, project, %Organization{slug: slug}, base_url)
       when is_binary(base_url) and base_url != "" and is_binary(slug) do
    page = if kind == "reauthorization_required", do: "connections", else: "agents"

    String.trim_trailing(base_url, "/") <>
      "/orgs/#{URI.encode(slug, &URI.char_unreserved?/1)}/projects/#{project.id}/#{page}"
  end

  defp link(_kind, _facts, _project, _org, _base_url), do: nil

  defp live_project(group_id) do
    Repo.one(
      from(p in Project,
        where: p.salix_group_id == ^group_id and is_nil(p.archived_at),
        limit: 1
      )
    )
  end

  defp sanitize(facts) do
    facts
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(@fact_keys)
    |> Map.new(fn
      {key, value} when is_binary(value) -> {key, clip(value, @max_text)}
      {key, value} when is_integer(value) or is_boolean(value) or is_nil(value) -> {key, value}
      {key, _value} -> {key, nil}
    end)
  end

  defp clip(text, max), do: String.slice(text, 0, max)
end
