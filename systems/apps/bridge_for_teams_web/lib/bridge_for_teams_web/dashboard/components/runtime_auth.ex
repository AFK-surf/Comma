defmodule BridgeForTeamsWeb.Dashboard.Components.RuntimeAuth do
  @moduledoc "Administrator runtime-auth layout. Secret controls belong only to the browser hook."
  use Phoenix.Component
  import BridgeForTeamsWeb.Dashboard.CoreComponents
  alias Phoenix.LiveView.JS

  attr(:rows, :list, required: true)
  attr(:can_manage, :boolean, required: true)
  attr(:selected, :map, default: nil)
  attr(:requests, :list, default: [])
  attr(:requests_next_cursor, :string, default: nil)
  attr(:endpoint, :string, required: true)
  attr(:managed_endpoint, :string, required: true)

  def panel(assigns) do
    ~H"""
    <section id="runtime-auth" class="space-y-3 rounded-xl border border-neutral-200 p-4">
      <h2 class="text-sm font-semibold text-neutral-700">Runtime 鉴权</h2>
      <p class="text-xs text-neutral-500">凭证仅保存到选中的运行环境；使用同一目标的 Agent 共用其鉴权状态。</p>
      <div :if={@requests != [] or @requests_next_cursor} id="runtime-auth-requests" class="space-y-2 rounded-lg bg-amber-50 p-3">
        <p class="text-sm font-medium text-amber-900">Router 等待管理员处理</p>
        <div :for={request <- @requests} id={"runtime-auth-request-#{request["request_id"]}"} class="flex items-center justify-between gap-3 text-xs">
          <span class="break-all">{request["action"]} · {get_in(request, ["target", "workload_id"])}</span>
          <.button
            :if={@can_manage}
            size="sm"
            phx-click="manage_runtime_auth"
            phx-value-id={get_in(request, ["target", "workload_id"])}
            phx-value-request-id={request["request_id"]}
          >处理</.button>
          <span :if={!@can_manage} class="text-neutral-500">需要管理员完成</span>
        </div>
        <.button
          :if={@requests_next_cursor}
          id="runtime-auth-requests-next"
          size="sm"
          phx-click="next_runtime_auth_requests"
        >下一页</.button>
      </div>
      <.table id="runtime-auth-targets" rows={@rows} row_id={fn row -> "runtime-auth-#{row.id}" end}>
        <:col :let={row} label="目标"><span class="break-all font-mono text-xs">{row.id}</span></:col>
        <:col :let={row} label="Provider">{row.provider}</:col>
        <:col :let={row} label="运行环境"><.status_pill status={row.status} /></:col>
        <:col label="鉴权">打开目标查看当前状态</:col>
        <:action :let={row}>
          <.button :if={@can_manage} size="sm" phx-click="manage_runtime_auth" phx-value-id={row.id}>管理</.button>
          <.button :if={!@can_manage && managed_target?(row)} size="sm" phx-click="manage_runtime_auth" phx-value-id={row.id}>查看</.button>
          <span :if={!@can_manage && !managed_target?(row)} class="text-xs text-neutral-500">需要管理员完成</span>
        </:action>
      </.table>
      <.modal :if={@selected && (@can_manage || managed_target?(@selected))} id="runtime-auth-panel-modal" show on_cancel={JS.push("close_runtime_auth_panel")}>
        <:title>管理运行环境鉴权</:title>
        <div class="space-y-3">
          <p class="break-all font-mono text-xs">{@selected.id}</p>
          <p :if={@selected.target["device_id"]} class="break-all font-mono text-xs">设备：{@selected.target["device_id"]}</p>
          <p class="text-sm">{@selected.provider} · 使用此运行环境的 Agent 共用本次修改。</p>
          <div :if={managed_target?(@selected)} id="managed-runtime-auth-controls" phx-hook="ManagedRuntimeAuth" phx-update="ignore" data-endpoint={managed_endpoint(@managed_endpoint, @endpoint, @selected)} class="space-y-3">
            <p data-managed-status class="text-sm">正在读取组织账号状态…</p>
            <div data-managed-unbound hidden class="space-y-3">
              <p class="text-sm">选择“自行配置”以使用运行环境中的凭据，或绑定一个兼容的组织账号。</p>
              <label data-managed-source-label class="block text-sm">鉴权来源
                <select data-managed-source class="mt-1 block w-full rounded border border-neutral-300 p-2">
                  <option value="self_configured">自行配置</option>
                  <option value="organization">组织账号</option>
                </select>
              </label>
              <label data-managed-account-label hidden class="block text-sm">组织账号
                <select data-managed-account class="mt-1 block w-full rounded border border-neutral-300 p-2"></select>
              </label>
              <.button data-managed-action="accounts-next" hidden>更多账号</.button>
              <.button data-managed-action="bind" hidden variant="primary">绑定账号</.button>
            </div>
            <div data-managed-bound hidden class="space-y-2">
              <p data-managed-account-summary class="text-sm"></p>
              <p class="text-xs text-neutral-500">已配置状态不表示模型请求成功。长期 API key 会发送到此运行环境。</p>
              <div class="flex flex-wrap gap-2">
                <.button data-managed-action="retry" hidden>重试同一账号</.button>
                <.button data-managed-action="unbind" variant="danger">解绑账号</.button>
              </div>
            </div>
            <.button data-managed-action="refresh">重新检查</.button>
            <p data-managed-feedback role="status" aria-live="polite" class="text-sm text-neutral-600"></p>
          </div>
          <div id="runtime-auth-private-controls" phx-hook="RuntimeAuth" phx-update="ignore" data-managed-self-auth={to_string(managed_target?(@selected))} hidden={managed_target?(@selected)} data-target={Jason.encode!(@selected.target)} data-endpoint={@endpoint} data-request-id={Map.get(@selected, :request_id)} class="space-y-3">
            <p data-auth-status class="text-sm">正在读取状态…</p>
            <div data-auth-ceremony hidden class="space-y-2 text-sm">
              <a data-auth-login-url target="_blank" rel="noopener noreferrer" class="underline">打开 Provider 登录页</a>
              <p data-auth-device-code>设备码：<code data-auth-user-code></code></p>
              <label data-auth-callback-label hidden class="block">登录页返回的授权码
                <input data-auth-callback-code type="password" autocomplete="off" spellcheck="false" class="mt-1 block w-full rounded border border-neutral-300 p-2" />
              </label>
              <.button data-auth-action="complete-login" hidden>提交授权码</.button>
              <p data-auth-login-help>完成登录后，点击“重新检查”。</p>
            </div>
            <label class="block text-sm">输入方式
              <select data-auth-method disabled class="mt-1 block w-full rounded border border-neutral-300 p-2"></select>
            </label>
            <label class="block text-sm">API key
              <input data-auth-secret type="password" autocomplete="off" spellcheck="false" disabled class="mt-1 block w-full rounded border border-neutral-300 p-2" />
            </label>
            <label class="block text-sm">鉴权文件（UTF-8 JSON，最多 64 KiB）
              <input data-auth-file type="file" accept=".json,application/json" disabled class="mt-1 block w-full text-sm" />
            </label>
            <label class="flex items-center gap-2 text-sm"><input type="checkbox" data-auth-save-verify disabled />保存并验证</label>
            <div class="flex flex-wrap gap-2">
              <.button data-auth-action="login" disabled>使用 Provider 原生登录</.button>
              <.button data-auth-action="save" variant="primary" disabled>保存到运行环境</.button>
              <.button data-auth-action="verify" disabled>验证已保存凭证</.button>
              <.button data-auth-action="refresh">重新检查</.button>
              <.button data-auth-action="cancel" disabled>取消当前操作</.button>
              <.button data-auth-action="finish-saved" hidden>结束处理（已保存未验证）</.button>
            </div>
            <p class="text-xs text-neutral-500">验证会向当前 provider 发起一次短请求，可能产生少量费用。只保存不会自动验证。</p>
            <p data-auth-feedback role="status" aria-live="polite" class="text-sm text-neutral-600"></p>
          </div>
        </div>
      </.modal>
    </section>
    """
  end

  defp managed_target?(selected),
    do: selected.target["kind"] == "compute_workload" or selected.provider in ~w(codex claude)

  defp managed_endpoint(workloads, _auth, %{target: %{"kind" => "compute_workload"}, id: id}),
    do: "#{workloads}/#{URI.encode(id, &URI.char_unreserved?/1)}/managed-auth"

  defp managed_endpoint(_workloads, auth, %{target: target}) do
    base = String.trim_trailing(auth, "/runtime-auth")
    device = URI.encode(target["device_id"], &URI.char_unreserved?/1)
    runtime = URI.encode(target["runtime_id"], &URI.char_unreserved?/1)
    "#{base}/devices/#{device}/runtimes/#{runtime}/managed-auth"
  end
end
