#!/usr/bin/env node

import { existsSync, readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const architectureRoot = resolve(scriptDir, "..");
const repositoryRoot = resolve(architectureRoot, "../..");
const outputDir = join(architectureRoot, "generated");

const relativeToRepository = (path) =>
  relative(repositoryRoot, path).replaceAll("\\", "/");
const read = (path) => readFileSync(path, "utf8");
const readJson = (path) => JSON.parse(read(path));
const codeId = (value) =>
  value
    .replace(/^@/, "")
    .replaceAll(/[^A-Za-z0-9_-]+/g, "_")
    .replace(/^([0-9])/, "_$1");
const quote = (value) => `'${String(value).replaceAll("'", "\\'")}'`;
const markdownLink = (label, path) => `[${label}](../../../${path})`;

function immediateDirectories(path) {
  return readdirSync(path, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => join(path, entry.name))
    .sort();
}

function collectClientPackages() {
  const roots = [
    join(repositoryRoot, "clients/apps"),
    join(repositoryRoot, "clients/packages"),
  ];
  return roots
    .flatMap(immediateDirectories)
    .map((directory) => {
      const packagePath = join(directory, "package.json");
      const manifest = readJson(packagePath);
      const scopes = ["dependencies", "peerDependencies", "devDependencies"];
      const dependencies = scopes.flatMap((scope) =>
        Object.keys(manifest[scope] ?? {})
          .filter((name) => name.startsWith("@comma/"))
          .map((name) => ({ name, scope })),
      );
      return {
        id: codeId(manifest.name),
        kind: relativeToRepository(directory).startsWith("clients/apps/")
          ? "app"
          : "package",
        name: manifest.name,
        path: relativeToRepository(packagePath),
        dependencies,
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
}

function collectOtpApps() {
  return immediateDirectories(join(repositoryRoot, "systems/apps"))
    .filter((directory) => existsSync(join(directory, "mix.exs")))
    .map((directory) => {
      const mixPath = join(directory, "mix.exs");
      const source = read(mixPath);
      const name = source.match(/\bapp:\s*:([A-Za-z0-9_]+)/)?.[1];
      if (!name) {
        throw new Error(
          `Could not find app name in ${relativeToRepository(mixPath)}`,
        );
      }
      const dependencies = [
        ...source.matchAll(
          /\{\s*:([A-Za-z0-9_]+),([^\n]*\bin_umbrella:\s*true[^\n]*)\}/g,
        ),
      ].map(([, dependency, options]) => ({
        name: dependency,
        scope: /\bonly:\s*:(?:test|dev)\b/.test(options)
          ? "development"
          : "runtime",
      }));
      return {
        id: codeId(name),
        name,
        path: relativeToRepository(mixPath),
        dependencies,
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
}

function collectSubsystems() {
  const path = join(repositoryRoot, "systems/apps/comma/lib/comma.ex");
  const source = read(path);
  const block = source.match(/@subsystems\s+%\{([\s\S]*?)\n\s*\}/)?.[1];
  if (!block) {
    throw new Error(
      `Could not find @subsystems in ${relativeToRepository(path)}`,
    );
  }
  return [...block.matchAll(/([A-Za-z0-9_]+):\s*\[([\s\S]*?)\]/g)].map(
    ([, name, appBlock]) => ({
      name,
      apps: [...appBlock.matchAll(/:([A-Za-z0-9_]+)/g)].map(
        (match) => match[1],
      ),
    }),
  );
}

function collectNativeCapabilities() {
  const path = join(
    repositoryRoot,
    "clients/packages/native-bridge/src/capability-leaves.ts",
  );
  const source = read(path);
  const starts = [
    ...source.matchAll(/defineNative(Capability|Event|State)\(\{/g),
  ];
  const leaves = starts.flatMap((match, index) => {
    const end = starts[index + 1]?.index ?? source.length;
    const body = source.slice(match.index, end);
    const id = body.match(/\bid:\s*["']([^"']+)["']/)?.[1];
    if (!id) return [];
    return [{ id, kind: match[1].toLowerCase(), namespace: id.split(".")[0] }];
  });
  const uniqueLeaves = [
    ...new Map(
      leaves.map((leaf) => [`${leaf.kind}:${leaf.id}`, leaf]),
    ).values(),
  ];
  const namespaces = [...new Set(uniqueLeaves.map((leaf) => leaf.namespace))]
    .map((namespace) => {
      const namespaceLeaves = uniqueLeaves.filter(
        (leaf) => leaf.namespace === namespace,
      );
      return {
        name: namespace,
        commands: namespaceLeaves.filter((leaf) => leaf.kind === "capability")
          .length,
        events: namespaceLeaves.filter((leaf) => leaf.kind === "event").length,
        states: namespaceLeaves.filter((leaf) => leaf.kind === "state").length,
        leafIds: [...new Set(namespaceLeaves.map((leaf) => leaf.id))].sort(),
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
  const legacyPath = join(
    repositoryRoot,
    "clients/apps/electron/src/main/index.ts",
  );
  const legacySource = read(legacyPath);
  const legacyRawIpc = {
    path: relativeToRepository(legacyPath),
    channels: [
      ...legacySource.matchAll(/\bipcMain\.handle\(\s*["']([^"']+)["']/g),
    ]
      .map((match) => match[1])
      .sort(),
  };
  return {
    path: relativeToRepository(path),
    leaves: uniqueLeaves,
    namespaces,
    legacyRawIpc,
  };
}

function collectDeployment() {
  const path = join(repositoryRoot, "k8s/comma/chart/templates/application.yaml");
  const source = read(path);
  const ports = [
    ...source.matchAll(
      /- name:\s*([A-Za-z0-9-]+)\s*\n\s*containerPort:\s*([0-9]+)/g,
    ),
  ].map(([, name, port]) => ({ name, port: Number(port) }));
  const services = source
    .split(/^---\s*$/m)
    .filter((document) => /^kind:\s*Service\s*$/m.test(document))
    .map((document) => ({
      name: document.match(/^\s*name:\s*([A-Za-z0-9-]+)\s*$/m)?.[1],
      port: Number(document.match(/^\s*port:\s*([0-9]+)\s*$/m)?.[1]),
      targetPort: document.match(/^\s*targetPort:\s*([A-Za-z0-9-]+)\s*$/m)?.[1],
    }))
    .filter((service) => service.name && service.port && service.targetPort);
  const enabledSubsystems =
    source
      .match(/- name:\s*COMMA_SUBSYSTEMS\s*\n\s*value:\s*([^\n]+)/)?.[1]
      ?.trim()
      .split(",") ?? [];
  return {
    path: relativeToRepository(path),
    workload: source.match(/^kind:\s*(StatefulSet)\s*$/m)?.[1] ?? "unknown",
    enabledSubsystems,
    ports,
    services,
  };
}

const productConceptAnchorSpecs = [
  {
    concept: "Comma 用户",
    layer: "产品身份",
    implementation: "Comma.Accounts.User",
    path: "systems/apps/comma_core/lib/comma/accounts/user.ex",
  },
  {
    concept: "Comma Workspace",
    layer: "产品范围",
    implementation: "Comma.Data.Workspace",
    path: "systems/apps/comma_core/lib/comma/data/schemas.ex",
  },
  {
    concept: "Comma 当前 Assistant Chat",
    layer: "产品入口",
    implementation: "Comma.AssistantChats",
    path: "systems/apps/comma_core/lib/comma/assistant_chats.ex",
    supportingSources: [
      {
        label: "SalixIM.RouterConversationInput",
        path: "systems/apps/salix_im/lib/salix_im/router_conversation_input.ex",
      },
    ],
    tests: [
      {
        path: "systems/apps/comma_core/test/comma_core_test.exs",
        name: "assistant ensure resolves and reuses the Group fixed Router Conversation",
      },
    ],
  },
  {
    concept: "BFT 用户",
    layer: "产品身份",
    implementation: "BridgeForTeams.Schema.User",
    path: "systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/user.ex",
  },
  {
    concept: "BFT Organization",
    layer: "产品范围",
    implementation: "BridgeForTeams.Schema.Organization",
    path: "systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/organization.ex",
  },
  {
    concept: "BFT Agent Swarm",
    layer: "产品范围",
    implementation: "BridgeForTeams.Schema.Project",
    path: "systems/apps/bridge_for_teams_core/lib/bridge_for_teams/schema/project.ex",
  },
  {
    concept: "Conversation",
    layer: "协作事实",
    implementation: "SalixIM.ConversationActor",
    path: "systems/apps/salix_im/lib/salix_im/conversation_actor.ex",
  },
  {
    concept: "Participant 接收目标",
    layer: "协作事实",
    implementation: "SalixIM.ConversationParticipantActor",
    path: "systems/apps/salix_im/lib/salix_im/conversation_participant_actor.ex",
  },
  {
    concept: "Message",
    layer: "协作事实",
    implementation: "SalixIM.ConversationMessage",
    path: "systems/apps/salix_im/lib/salix_im/conversation_message.ex",
  },
  {
    concept: "Router Single Session",
    layer: "执行上下文",
    implementation: "SalixAgent.AgentRoleActor",
    path: "systems/apps/salix_agent/lib/salix_agent/agent_role_actor.ex",
    tests: [
      {
        path: "systems/apps/salix_agent/test/deliver_ingress_test.exs",
        name: "a session-less delivery to a router resolves its session at deliver time",
      },
    ],
  },
  {
    concept: "Worker Multi Session",
    layer: "执行上下文",
    implementation: "SalixIM.AgentDeliveryPayload",
    path: "systems/apps/salix_im/lib/salix_im/agent_delivery_payload.ex",
    tests: [
      {
        path: "systems/apps/salix_im/test/agent_actor_role_routing_test.exs",
        name: "worker participant payload uses origin session only when it is the delegator",
      },
    ],
  },
  {
    concept: "Task 创建与持久化边界",
    layer: "Task creation input",
    implementation: "SalixIM.Provider.Internal.internal.task.create",
    path: "systems/apps/salix_im/lib/salix_im/provider/internal.ex",
    supportingSources: [
      {
        label: "SalixIM.Provider.Manuals.internal.task.create",
        path: "systems/apps/salix_im/lib/salix_im/provider/manuals.ex",
      },
      {
        label: "SalixIM.Ports.TaskCreate",
        path: "systems/apps/salix_im/lib/salix_im/ports/task_create.ex",
      },
      {
        label: "Salix.Bindings.AgentConversations",
        path: "systems/apps/salix_web/lib/salix/bindings/agent_conversations.ex",
      },
      {
        label: "SalixCluster.TaskSchedules",
        path: "systems/apps/salix_cluster/lib/salix_cluster/task_schedules.ex",
      },
      {
        label: "SalixIM.TaskConversationInput",
        path: "systems/apps/salix_im/lib/salix_im/task_conversation_input.ex",
      },
    ],
    tests: [
      {
        path: "systems/apps/salix_im/test/provider_test.exs",
        name: "im_api.internal.task.create owns command preparation and calls only the TaskSchedules port",
      },
    ],
  },
  {
    concept: "普通 Task Worker 停机监督",
    layer: "Task owner",
    implementation: "SalixIM.TaskWorkerWatch",
    path: "systems/apps/salix_im/lib/salix_im/task_worker_watch.ex",
    tests: [
      {
        path: "systems/apps/salix_im/test/conversations_test.exs",
        name: "TaskWorkerWatch reminds a silent stopped Worker once, then tells the Router",
      },
      {
        path: "systems/apps/salix_im/test/conversations_test.exs",
        name: "TaskWorkerWatch does not escalate the stop it already reminded for after a restart",
      },
      {
        path: "systems/apps/salix_im/test/conversations_test.exs",
        name: "TaskWorkerWatch retries a reminder whose append failed",
      },
    ],
  },
  {
    concept: "Participant 实时状态与显式 Message 边界",
    layer: "可见输出",
    implementation: "SalixAgent.ToolPolicy",
    path: "systems/apps/salix_agent/lib/salix_agent/tool_policy.ex",
    tests: [
      {
        path: "systems/apps/salix_im/test/conversations_test.exs",
        name: "participant direct reads recover a missed realtime draft clear invalidation",
      },
      {
        path: "systems/apps/salix_im/test/conversations_test.exs",
        name: "participant status keeps display text separate from its exact presentation on a shared session",
      },
      {
        path: "systems/apps/salix_agent/test/server_test.exs",
        name: "an internal conversation gains an agent Message only from explicit send_message",
      },
      {
        path: "systems/apps/salix_agent/test/server_test.exs",
        name: "explicit Feishu dynamic IM operation is the visible reply path",
      },
    ],
  },
  {
    concept: "Comma Workspace → Group scope revision",
    layer: "产品授权",
    implementation: "Comma.WorkspaceGroupBinding",
    path: "systems/apps/comma_core/lib/comma/workspace_group_binding.ex",
  },
  {
    concept: "Comma 控制面显式重新指定 Group Router：固定 Conversation 发送",
    layer: "产品生命周期",
    implementation: "Comma.Conversations.send_message/5",
    path: "systems/apps/comma_core/lib/comma/conversations.ex",
    tests: [
      {
        path: "systems/apps/comma_web/test/comma_api_test.exs",
        name: "the next Comma Chat send follows an explicitly reassigned Group Router",
      },
    ],
  },
  {
    concept: "Group 固定 Router Conversation 显式重新指定收敛",
    layer: "Salix 产品编排",
    implementation: "SalixIM.RouterConversationInput",
    path: "systems/apps/salix_im/lib/salix_im/router_conversation_input.ex",
    tests: [
      {
        path: "systems/apps/salix_im/test/conversations_test.exs",
        name: "concurrent Router reassignment cannot deactivate both desired Router participants",
      },
    ],
  },
  {
    concept: "Comma Center Recommendation 产品 Projection SSOT",
    layer: "产品 Projection",
    implementation: "Comma.Recommendations",
    path: "systems/apps/comma_core/lib/comma/recommendations.ex",
    supportingSources: [
      {
        label: "RecommendationProfile",
        path: "systems/apps/comma_core/lib/comma/data/recommendation_profile.ex",
      },
      {
        label: "RecommendationRun",
        path: "systems/apps/comma_core/lib/comma/data/recommendation_run.ex",
      },
    ],
    tests: [
      {
        path: "systems/apps/comma_core/test/comma/recommendations_test.exs",
        name: "a repeated manual refresh atomically supersedes the active run and clears its evidence",
      },
      {
        path: "systems/apps/comma_core/test/comma/recommendations_test.exs",
        name: "source changes supersede an active run and stop exposing refreshing state",
      },
    ],
  },
  {
    concept: "Recommendation 有界 Source Collector 与受限 Renderer",
    layer: "产品 Runtime",
    implementation: "CommaWeb.RecommendationSourceCollector",
    path: "systems/apps/comma_web/lib/comma_web/recommendation_source_collector.ex",
    supportingSources: [
      {
        label: "RecommendationRuntime",
        path: "systems/apps/comma_web/lib/comma_web/recommendation_runtime.ex",
      },
    ],
    tests: [
      {
        path: "systems/apps/comma_web/test/local_recommendation_flow_test.exs",
        name: "HTTP refresh durably queues work before collection and publishes one stateless model response",
      },
    ],
  },
  {
    concept: "Recommendation 版本化 Contract 与 Electron Media Intake",
    layer: "客户端边界",
    implementation: "@comma/recommendation-contract",
    path: "clients/packages/recommendation-contract/src/index.ts",
    supportingSources: [
      {
        label: "recommendationMedia.load",
        path: "clients/packages/native-bridge/src/capability-leaves.ts",
      },
      {
        label: "Electron Recommendation Media",
        path: "clients/apps/electron/src/main/modules/recommendation-media/index.ts",
      },
    ],
    tests: [
      {
        path: "clients/apps/electron/src/main/test/recommendation-media.test.ts",
        name: 'it("rejects a hostname if any returned address is private',
        name: "rejects a hostname if any returned address is private",
      },
    ],
  },
  {
    concept: "Internal Runtime Session",
    layer: "执行 Owner",
    implementation: "SalixAgent.InternalSessionActor",
    path: "systems/apps/salix_agent/lib/salix_agent/internal_session_actor.ex",
  },
  {
    concept: "External Runtime Session",
    layer: "执行 Owner",
    implementation: "SalixAgent.ExternalSessionActor",
    path: "systems/apps/salix_agent/lib/salix_agent/external_session_actor.ex",
  },
];

function collectProductConceptAnchors() {
  return productConceptAnchorSpecs.map((anchor) => {
    const directTests = anchor.tests ?? [];

    const verified = {
      concept: anchor.concept,
      layer: anchor.layer,
      implementation: anchor.implementation,
      path: anchor.path,
      directTests,
    };

    if (anchor.supportingSources?.length > 0) {
      verified.supportingSources = anchor.supportingSources.map((source) => ({
        label: source.label,
        path: source.path,
      }));
    }

    return verified;
  });
}

function renderRepositoryModel(inventory) {
  const packageElements = inventory.clientPackages
    .map(
      (item) =>
        `      ${item.id} = code_module ${quote(item.name)} {\n        description ${quote(
          `${item.kind === "app" ? "应用" : "包"}；${item.dependencies.length} 个仓库内源码依赖`,
        )}\n        technology 'TypeScript Workspace'\n        link ../../../${item.path} 'package.json'\n      }`,
    )
    .join("\n\n");
  const packageRelations = inventory.clientPackages
    .flatMap((item) =>
      item.dependencies.map(
        (dependency) =>
          `      ${item.id} .depends_on ${codeId(dependency.name)} ${quote(
            dependency.scope === "devDependencies"
              ? "开发依赖"
              : "产品/Peer 依赖",
          )}`,
      ),
    )
    .join("\n");

  const memberships = new Map();
  for (const subsystem of inventory.subsystems) {
    for (const app of subsystem.apps) {
      const current = memberships.get(app) ?? [];
      current.push(subsystem.name);
      memberships.set(app, current);
    }
  }
  const otpElements = inventory.otpApps
    .map(
      (app) =>
        `      ${app.id} = code_module ${quote(app.name)} {\n        description ${quote(
          `所属子系统：${(memberships.get(app.name) ?? ["传递/支持应用"]).join(", ")}`,
        )}\n        technology 'Elixir / OTP 应用'\n        link ../../../${app.path} 'mix.exs'\n      }`,
    )
    .join("\n\n");
  const otpRelations = inventory.otpApps
    .flatMap((app) =>
      app.dependencies
        .filter((dependency) => dependency.scope === "runtime")
        .map(
          (dependency) =>
            `      ${app.id} .depends_on ${codeId(dependency.name)} '生产 in_umbrella 依赖'`,
        ),
    )
    .join("\n");

  const namespaceElements = inventory.nativeCapabilities.namespaces
    .map(
      (namespace) =>
        `      ${codeId(namespace.name)} = code_module ${quote(namespace.name)} {\n        description ${quote(
          `${namespace.commands} 个 command · ${namespace.events} 个 event · ${namespace.states} 个 replay-last state`,
        )}\n        technology '生成式 Native Capability Namespace'\n        link ../../../${inventory.nativeCapabilities.path} 'Leaf Registry'\n      }`,
    )
    .join("\n\n");
  const legacyRawIpc = inventory.nativeCapabilities.legacyRawIpc;
  const legacyIpcElement = `      frozen_legacy_raw_ipc = code_module '冻结的 legacy raw IPC' {\n        description ${quote(
    `${legacyRawIpc.channels.length} 个 allowlist channel：${legacyRawIpc.channels.join(", ")}`,
  )}\n        technology '手写 ipcMain.handle'\n        link ../../../${legacyRawIpc.path} '当前例外'\n      }`;

  const serviceElements = inventory.deployment.services
    .map(
      (service) =>
        `      service_${codeId(service.name)} = code_module ${quote(service.name)} {\n        description ${quote(
          `ClusterIP :${service.port} → ${service.targetPort}`,
        )}\n        technology 'Kubernetes Service'\n        link ../../../${inventory.deployment.path} 'Helm template'\n      }`,
    )
    .join("\n\n");
  const serviceRelations = inventory.deployment.services
    .map(
      (service) =>
        `      service_${codeId(service.name)} .depends_on workload ${quote(`指向 ${service.targetPort}`)}`,
    )
    .join("\n");

  const subsystemViews = inventory.subsystems
    .map((subsystem, index) => {
      const inclusions = subsystem.apps
        .map(
          (app) =>
            `    include comma_platform.source_inventory.otp_apps.${codeId(app)}`,
        )
        .join("\n");
      return `  view evidence_otp_${codeId(subsystem.name)} of comma_platform.source_inventory.otp_apps {\n    title ${quote(
        `${String(index + 2).padStart(2, "0")}E · ${subsystem.name} 子系统的 OTP 应用`,
      )}\n    description '直接来自 Comma.@subsystems；线只表示生产 in_umbrella 源码依赖，不表示网络调用。'\n    autoLayout LeftRight\n\n${inclusions}\n  }`;
    })
    .join("\n\n");

  return `// 由 scripts/generate-inventory.mjs 生成。请修改源清单，不要修改本文件。\nmodel {\n  extend comma_platform.source_inventory {\n    client_modules = source_group '客户端 Workspace 模块' {\n      description 'package.json 声明的 @comma/* 源码依赖；不是运行时调用图'\n\n${packageElements}\n\n${packageRelations}\n    }\n\n    otp_apps = source_group 'OTP 应用清单' {\n      description 'mix.exs 中的 umbrella 源码依赖；subsystem 决定运行时启动集合'\n\n${otpElements}\n\n${otpRelations}\n    }\n\n    native_contracts = source_group 'Native Capability Namespace' {\n      description 'leaf-first registry 的 namespace 聚合，并显式列出冻结的 raw IPC 例外'\n\n${namespaceElements}\n\n${legacyIpcElement}\n    }\n\n    deployment_surface = source_group '部署事实' {\n      description '当前 Helm template 的 workload、subsystem、container port 与 Service target'\n\n      workload = code_module ${quote(`${inventory.deployment.workload}: comma`)} {\n        description ${quote(
    `启动 ${inventory.deployment.enabledSubsystems.join(", ")}；端口 ${inventory.deployment.ports.map((port) => `${port.name}:${port.port}`).join(", ")}`,
  )}\n        technology 'Kubernetes Workload'\n        link ../../../${inventory.deployment.path} 'Helm Template'\n      }\n\n${serviceElements}\n\n${serviceRelations}\n    }\n  }\n}\n\nviews {\n  view evidence_client_modules of comma_platform.source_inventory.client_modules {\n    title '01E · 客户端 Workspace 依赖证据'\n    description '程序化证据视图：只回答源码 package 的依赖方向，不回答运行时权威。'\n    autoLayout LeftRight\n\n    include *\n  }\n\n${subsystemViews}\n\n  view evidence_native_contracts of comma_platform.source_inventory.native_contracts {\n    title '05E · Native Capability Namespace 证据'\n    description '按 namespace 聚合 command/event/state；详细 leaf 仍以 registry 为准。'\n    autoLayout LeftRight\n\n    include *\n  }\n\n  view evidence_deployment_surface of comma_platform.source_inventory.deployment_surface {\n    title '06E · 部署表面证据'\n    description '从当前 Helm template 提取；用于复核手工部署图中的 workload 与端口事实。'\n    autoLayout LeftRight\n\n    include *\n  }\n}\n`;
}

function renderInventoryMarkdown(inventory) {
  const clientRows = inventory.clientPackages
    .map((item) => {
      const production = item.dependencies
        .filter((dependency) => dependency.scope !== "devDependencies")
        .map((dependency) => dependency.name);
      const development = item.dependencies
        .filter((dependency) => dependency.scope === "devDependencies")
        .map((dependency) => dependency.name);
      return `| ${markdownLink(item.name, item.path)} | ${item.kind === "app" ? "应用" : "包"} | ${production.join("<br>") || "—"} | ${development.join("<br>") || "—"} |`;
    })
    .join("\n");
  const subsystemRows = inventory.subsystems
    .map(
      (subsystem) =>
        `| \`${subsystem.name}\` | ${subsystem.apps.map((app) => `\`${app}\``).join(", ")} |`,
    )
    .join("\n");
  const otpRows = inventory.otpApps
    .map((app) => {
      const runtime = app.dependencies
        .filter((dependency) => dependency.scope === "runtime")
        .map((dependency) => `\`${dependency.name}\``);
      const subsystems = inventory.subsystems
        .filter((subsystem) => subsystem.apps.includes(app.name))
        .map((subsystem) => `\`${subsystem.name}\``);
      return `| ${markdownLink(`\`${app.name}\``, app.path)} | ${subsystems.join(", ") || "传递/支持应用"} | ${runtime.join(", ") || "—"} |`;
    })
    .join("\n");
  const nativeRows = inventory.nativeCapabilities.namespaces
    .map(
      (namespace) =>
        `| \`${namespace.name}\` | ${namespace.commands} | ${namespace.events} | ${namespace.states} | ${namespace.leafIds.join("<br>")} |`,
    )
    .join("\n");
  const legacyRawIpc = inventory.nativeCapabilities.legacyRawIpc;
  const serviceRows = inventory.deployment.services
    .map(
      (service) =>
        `| \`${service.name}\` | ${service.port} | \`${service.targetPort}\` |`,
    )
    .join("\n");

  const productConceptRows = inventory.productConceptAnchors
    .map((anchor) => {
      const implementationLinks = [
        markdownLink(`\`${anchor.implementation}\``, anchor.path),
        ...(anchor.supportingSources ?? []).map((source) =>
          markdownLink(`\`${source.label}\``, source.path),
        ),
      ];

      return `| ${anchor.concept} | ${anchor.layer} | ${implementationLinks.join("<br>")} | ${anchor.directTests.map((test) => markdownLink(test.name, test.path)).join("<br>") || "—"} |`;
    })
    .join("\n");

  return `# 程序生成的仓库架构事实清单\n\n> 从当前检出的源码确定性生成。这里是证据附录，不是架构叙事；相关源码变化后运行 \`pnpm architecture:validate\`。评审基线由 PR 或评审记录绑定，不写入生成物。\n\n## 产品概念实现锚点\n\n这张表提供人工维护的实现与测试链接，不检查源码字符串或测试名称，也不证明业务语义。行为证据以实际测试结果为准。\n\n| 产品/领域概念 | 层次 | 当前实现锚点 | 关键直接测试 |\n| --- | --- | --- | --- |\n${productConceptRows}\n\n## 客户端 Workspace 模块\n\n| 模块 | 类型 | 产品/Peer 依赖 | 开发依赖 |\n| --- | --- | --- | --- |\n${clientRows}\n\n## Release 子系统成员\n\n来源：${markdownLink("`Comma.@subsystems`", inventory.subsystemSource)}。成员关系表示“启用该子系统时按顺序启动”，不表示每个 OTP 应用都是独立部署的服务。\n\n| 子系统 | 按启动顺序排列的 OTP 应用 |\n| --- | --- |\n${subsystemRows}\n\n## OTP 源码依赖\n\n| OTP 应用 | 运行时子系统成员 | 生产 in_umbrella 依赖 |\n| --- | --- | --- |\n${otpRows}\n\n## Native Capability Namespace\n\n来源：${markdownLink("Leaf Registry", inventory.nativeCapabilities.path)}。同一 ID 的 command/event/state wrapper 按各自类型计数一次。\n\n| Namespace | Command | Event | State | ID |\n| --- | ---: | ---: | ---: | --- |\n${nativeRows}\n\n### 冻结的 raw IPC 例外\n\n来源：${markdownLink("Electron Main 入口", legacyRawIpc.path)}。这些是生成式 Gateway 的当前态例外，不是扩展点。\n\n${legacyRawIpc.channels.map((channel) => `- \`${channel}\``).join("\n")}\n\n## 当前部署表面\n\n来源：${markdownLink("Helm Application Template", inventory.deployment.path)}。\n\n- Workload 类型：\`${inventory.deployment.workload}\`\n- 启用的子系统：${inventory.deployment.enabledSubsystems.map((name) => `\`${name}\``).join(", ")}\n- Container 端口：${inventory.deployment.ports.map((port) => `\`${port.name}:${port.port}\``).join(", ")}\n\n| Service | 端口 | Target Port |\n| --- | ---: | --- |\n${serviceRows}\n`;
}

const inventory = {
  schemaVersion: 4,
  clientPackages: collectClientPackages(),
  otpApps: collectOtpApps(),
  subsystemSource: "systems/apps/comma/lib/comma.ex",
  subsystems: collectSubsystems(),
  nativeCapabilities: collectNativeCapabilities(),
  deployment: collectDeployment(),
  productConceptAnchors: collectProductConceptAnchors(),
};

mkdirSync(outputDir, { recursive: true });
writeFileSync(
  join(outputDir, "inventory.json"),
  `${JSON.stringify(inventory, null, 2)}\n`,
);
writeFileSync(
  join(outputDir, "inventory.md"),
  renderInventoryMarkdown(inventory),
);
writeFileSync(
  join(outputDir, "repository.c4"),
  renderRepositoryModel(inventory).replace(
    "\n\nviews {\n",
    "\n\nviews '06 · 程序化证据' {\n",
  ),
);

console.log(
  `已生成 ${inventory.clientPackages.length} 个客户端模块、${inventory.otpApps.length} 个 OTP 应用、` +
    `${inventory.nativeCapabilities.namespaces.length} 个 Native Namespace、` +
    `${inventory.nativeCapabilities.legacyRawIpc.channels.length} 个 legacy IPC 例外和 ` +
    `${inventory.deployment.services.length} 个 Service；列出了 ` +
    `${inventory.productConceptAnchors.length} 个产品概念实现锚点。`,
);
