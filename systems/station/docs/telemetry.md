# 遥测

**什么都不带内容**：聊天文字、引用、文件名、提示词、agent 的输出、对话标题，一样都不发。发出去的只有动作、计数、耗时和错误（带调用栈）。

网页版、安卓和 still.fail cloud 的遥测在 still.fail 的仓库里，不在这里。

## 错误：PostHog

`src/ops/telemetry.ts`，只做错误追踪，**默认关闭**。station 跑在用户自己的机器上，由它的管理者在 `config.json` 里打开：

```json
{ "telemetry": { "errors": true } }
```

打开后（改配置立即生效，关掉也立即停）上报 error 级别的每一条日志。每条带 station 的 id（有 mesh 登记时）和 `release`。日志的字段一律不发（可能带着人写的东西），只发那句话和其中的错误信息。错误信息里家目录下的路径换成 `~`，引号括起来的内容去掉。

项目 key 是 PostHog 的公开 key（`phc_…`），不进仓库。station 启动时从发布包的 `dist/admin/posthog.json` 读 key。没有这个文件的构建什么都不上报。

## 链路追踪

station 的 span 是 OpenTelemetry（OTLP JSON），经 still.fail cloud 转到 Axiom（`src/mesh/traces.ts`）。Comma 的控制面不收 station 的 trace。

- 只在配置打开时发，默认关闭。`stillfail-station` 启动时读，改了要重启：

  ```json
  { "telemetry": { "traces": true } }
  ```

  关闭时 station 什么都不记，但照样把 `traceparent` 往下传。
- span：每个请求流一个，从流被接受到答复最后一个字节写出（事件流到它的开头）。station 的管理 API 在同一个进程里，没有自己的 span。请求带 W3C `traceparent` 时，span 记在它下面。
- 属性：`http.request.method`、`url.path`（路由，id 换成 `:id`，不带查询串）、`http.response.status_code`、请求和答复的大小、`stillfail.path`、`stillfail.stream`、`error.type`。从不带消息内容、标题、文件名和邮箱。资源属性：`service.name` 是 `stillfail-mesh`，`stillfail.station` 是 station 的 id。
- 发送：攒一批后发到 still.fail cloud 的 `POST /v1/telemetry/traces`，用 station 的 key 签名。每个前缀（`stillfail`、`ember`）各用自己的 headers（`x-<prefix>-station`、`x-<prefix>-ts`、`x-<prefix>-signature`），签的是 `<prefix>-station-telemetry-v1:<origin>:<station>:<ts>:<body 的 sha256，hex>`。station 必须已登记。发不出去的一批直接丢掉，不重试。
- Axiom 的 token 只在 still.fail cloud 里，station 和客户端都不带。
