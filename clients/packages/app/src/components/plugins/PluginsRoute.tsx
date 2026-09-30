import { PageLoading } from "@comma/ui";
import { useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  PluginCatalog,
  PluginDetail,
  toast,
  type PluginCatalogCopy,
  type PluginCatalogTab,
  type PluginCategory,
  type PluginDefinition,
  type PluginDetailCopy,
} from "@comma/ui";
import { useNavigate } from "@tanstack/react-router";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import type { CommaPlugin } from "../../api";
import { PluginBrandArtwork } from "./PluginBrandArtwork";
import { usePluginInstall } from "./PluginInstallProvider";
import { PluginPersonalSources, withMcpGrants } from "./PluginPersonalSources";
import { SkillDetailPage } from "./SkillDetailPage";
import { usePluginPersonalSources } from "./usePluginPersonalSources";
import { readActiveWorkspaceId, writeActiveWorkspaceId } from "../activeWorkspace";
import { useChatApi } from "../chat/ChatProvider";
import { useWorkspaceSkillsState } from "../chat/useWorkspaceSkills";

type PluginsRouteState =
  | { status: "loading" }
  | { status: "empty" }
  | { status: "error"; message: string }
  | { status: "ready"; plugins: CommaPlugin[]; workspaceId: string };

export function PluginsRoute() {
  const api = useChatApi();
  const installation = usePluginInstall();
  const messages = useCommaMessages();
  const navigate = useNavigate();
  const catalogCopy: PluginCatalogCopy = {
    addLabel: messages.plugins_add(),
    addPluginAriaLabel: (name) => messages.plugins_add_named({ name }),
    emptyLabel: messages.plugins_no_results(),
    installedLabel: messages.plugins_installed(),
    manageLabel: messages.plugins_manage(),
    openPluginAriaLabel: (name) => messages.plugins_view_details({ name }),
    searchAriaLabel: messages.plugins_search(),
    searchPlaceholder: messages.plugins_search_placeholder(),
    showAllCategoryAriaLabel: (category) =>
      messages.plugins_show_all_category({ category }),
    showAllLabel: messages.plugins_show_all(),
    openSkillAriaLabel: (name) => messages.plugins_skills_view_details({ name }),
    skillCategoriesAriaLabel: messages.plugins_skills_categories(),
    skillsEmptyLabel: messages.plugins_skills_no_results(),
    skillsSearchAriaLabel: messages.plugins_skills_search(),
    skillsSearchPlaceholder: messages.plugins_skills_search_placeholder(),
    skillsTitle: messages.plugins_skills(),
    title: messages.plugins_title(),
  };
  const detailCopy: PluginDetailCopy = {
    backLabel: messages.plugins_back(),
    descriptionLabel: messages.plugins_description(),
    installLabel: messages.plugins_add_to_comma(),
    installPluginAriaLabel: (name) => messages.plugins_add_to_comma_named({ name }),
    manageLabel: messages.plugins_manage(),
    mcpsLabel: messages.plugins_mcps(),
    skillsLabel: messages.plugins_skills(),
    tryInChatLabel: messages.plugins_try_in_chat(),
    tryPluginInChatAriaLabel: (name) => messages.plugins_try_in_chat_named({ name }),
    uninstallLabel: messages.plugins_uninstall(),
    uninstallPluginAriaLabel: (name) => messages.plugins_uninstall_named({ name }),
  };
  const [revision, setRevision] = useState(0);
  const [state, setState] = useState<PluginsRouteState>({ status: "loading" });
  const [selectedPluginId, setSelectedPluginId] = useState<string>();
  const [catalogTab, setCatalogTab] = useState<PluginCatalogTab>("plugins");
  const [selectedSkillId, setSelectedSkillId] = useState<string>();
  const [skillCategoryId, setSkillCategoryId] = useState<string>();
  const [pendingPluginIds, setPendingPluginIds] = useState<ReadonlySet<string>>(
    () => new Set()
  );
  const mutationInFlight = useRef(new Map<string, symbol>());

  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    setState({ status: "loading" });

    void api
      .listWorkspaces({ signal: controller.signal })
      .then(async (workspaces) => {
        const preferredWorkspaceId = readActiveWorkspaceId();
        const workspace =
          workspaces.find(
            (candidate) =>
              candidate.id === preferredWorkspaceId &&
              workspaceSupportsPlugins(candidate)
          ) ?? workspaces.find(workspaceSupportsPlugins);

        if (!workspace) {
          if (active) setState({ status: "empty" });
          return;
        }

        writeActiveWorkspaceId(workspace.id);
        const plugins = await api.listWorkspacePlugins(workspace.id, {
          signal: controller.signal,
        });
        if (active)
          setState({
            plugins: plugins.filter((plugin) => plugin.id !== "feishu"),
            status: "ready",
            workspaceId: workspace.id,
          });
      })
      .catch((error: unknown) => {
        if (!active || controller.signal.aborted) return;
        setState({
          message:
            error instanceof Error ? error.message : messages.plugins_load_failed(),
          status: "error",
        });
      });

    return () => {
      active = false;
      controller.abort();
    };
  }, [api, messages, revision]);

  const selectedPlugin =
    state.status === "ready"
      ? state.plugins.find((plugin) => plugin.id === selectedPluginId)
      : undefined;
  const personalSources = usePluginPersonalSources({
    api,
    workspaceId: state.status === "ready" ? state.workspaceId : undefined,
    pluginId: selectedPlugin?.installed ? selectedPlugin.id : undefined,
    refreshToken: installation.completionVersion,
  });

  const updatePlugin = useCallback((plugin: CommaPlugin) => {
    setState((current) =>
      current.status === "ready"
        ? {
            ...current,
            plugins: current.plugins.map((candidate) =>
              candidate.id === plugin.id ? plugin : candidate
            ),
          }
        : current
    );
  }, []);

  const workspaceId = state.status === "ready" ? state.workspaceId : undefined;
  const skillCatalog = useWorkspaceSkillsState(api, workspaceId ?? "");
  const skills = skillCatalog.skills;
  useEffect(() => {
    if (installation.result?.workspaceId === workspaceId) {
      if (installation.result) updatePlugin(installation.result.plugin);
    }
  }, [installation.result, workspaceId, updatePlugin]);

  const mutatePlugin = async (pluginId: string, installed: boolean) => {
    if (state.status !== "ready" || mutationInFlight.current.has(pluginId)) return;
    const target = { pluginId, workspaceId: state.workspaceId };
    if (installed) {
      await installation.install(target);
      return;
    }
    installation.cancel(target);
    const requestId = Symbol();
    mutationInFlight.current.set(pluginId, requestId);
    setPendingPluginIds((current) => new Set(current).add(pluginId));
    try {
      updatePlugin(await api.uninstallWorkspacePlugin(state.workspaceId, pluginId));
    } catch (error) {
      toast.error(
        messages.plugins_uninstall_failed(),
        error instanceof Error ? { description: error.message } : {}
      );
    } finally {
      mutationInFlight.current.delete(pluginId);
      setPendingPluginIds((current) => {
        const next = new Set(current);
        next.delete(pluginId);
        return next;
      });
    }
  };

  // Load failures ride the toast stack with a Retry action; the panel keeps a
  // quiet placeholder so the content area is never blank.
  useEffect(() => {
    if (state.status !== "error") return undefined;
    // Each effect owns its toast. A delayed dismissal must not close a retry's toast.
    const toastId = toast.error(messages.plugins_load_failed(), {
      ...(state.message ? { description: state.message } : {}),
      actions: [
        {
          label: messages.common_retry(),
          onPress: () => setRevision((value) => value + 1),
        },
      ],
      testId: "plugins-load-error",
    });
    return () => {
      toast.dismiss(toastId);
    };
  }, [messages, state]);

  if (state.status === "loading") {
    return (
      <PluginsRouteStatus label={messages.plugins_title()}>
        <PageLoading label={messages.common_loading()} />
      </PluginsRouteStatus>
    );
  }

  if (state.status === "empty") {
    return (
      <PluginsRouteStatus label={messages.plugins_title()}>
        {messages.plugins_no_workspace()}
      </PluginsRouteStatus>
    );
  }

  if (state.status === "error") {
    return (
      <PluginsRouteStatus label={messages.plugins_title()} role="alert">
        <span>{messages.plugins_load_failed()}</span>
        <Button
          hierarchy="secondary-gray"
          onPress={() => setRevision((value) => value + 1)}
          size="sm"
        >
          {messages.common_retry()}
        </Button>
      </PluginsRouteStatus>
    );
  }

  const pendingIds = new Set(pendingPluginIds);
  if (installation.pending?.workspaceId === state.workspaceId)
    pendingIds.add(installation.pending.pluginId);
  const pluginDefinitions = state.plugins.map(toPluginDefinition);
  const definitionById = new Map(
    pluginDefinitions.map((plugin) => [plugin.id, plugin])
  );

  if (selectedPlugin) {
    const reauthorizingConnectionId =
      installation.pending?.workspaceId === state.workspaceId &&
      installation.pending.pluginId === selectedPlugin.id
        ? installation.pending.connectionId
        : undefined;
    const reauthorize = (connectionId: string) => {
      personalSources.cancel();
      void installation.reauthorize({
        pluginId: selectedPlugin.id,
        workspaceId: state.workspaceId,
        connectionId,
      });
    };
    const plugin = withMcpGrants(definitionById.get(selectedPlugin.id)!, {
      onReauthorize: reauthorize,
      personalSources,
      pluginName: selectedPlugin.name,
      reauthorizingConnectionId,
    });

    return (
      <PluginDetail
        className="comma-plugins-route"
        copy={detailCopy}
        installed={selectedPlugin.installed}
        installPending={pendingIds.has(selectedPlugin.id)}
        onBack={() => setSelectedPluginId(undefined)}
        onInstall={() => void mutatePlugin(selectedPlugin.id, true)}
        onTryInChat={() => void navigate({ to: "/" })}
        plugin={plugin}
        {...(!selectedPlugin.locked
          ? {
              onUninstall: () => void mutatePlugin(selectedPlugin.id, false),
              uninstallPending: pendingPluginIds.has(selectedPlugin.id),
            }
          : {})}
      >
        {selectedPlugin.installed ? (
          <PluginPersonalSources
            onReauthorize={reauthorize}
            personalSources={personalSources}
            plugin={selectedPlugin}
            reauthorizingConnectionId={reauthorizingConnectionId}
          />
        ) : null}
      </PluginDetail>
    );
  }

  // Salix source families, in display order.
  const skillCategories = [
    { id: "custom", name: messages.plugins_skills_category_custom() },
    { id: "imported", name: messages.plugins_skills_category_imported() },
    { id: "system", name: messages.plugins_skills_category_system() },
  ];
  const selectedSkill = skills.find((skill) => skill.skill_id === selectedSkillId);

  if (selectedSkill) {
    return (
      <SkillDetailPage
        api={api}
        categoryName={
          skillCategories.find((category) => category.id === selectedSkill.source)?.name
        }
        copy={detailCopy}
        onBack={() => setSelectedSkillId(undefined)}
        onTryInChat={() => void navigate({ to: "/" })}
        skill={selectedSkill}
        workspaceId={state.workspaceId}
      />
    );
  }

  const installedPlugins = state.plugins
    .filter((plugin) => plugin.installed)
    .map((plugin) => definitionById.get(plugin.id)!);
  const categories = pluginCategories(
    state.plugins,
    definitionById,
    messages.plugins_category_integrations()
  );

  return (
    <PluginCatalog
      className="comma-plugins-route"
      categories={categories}
      copy={catalogCopy}
      installedPlugins={installedPlugins}
      onPluginInstall={(plugin) => void mutatePlugin(plugin.id, true)}
      onPluginOpen={(plugin) => setSelectedPluginId(plugin.id)}
      onTabChange={setCatalogTab}
      pendingPluginIds={pendingIds}
      onSkillCategoryChange={setSkillCategoryId}
      onSkillOpen={(skill) => setSelectedSkillId(skill.id)}
      skillsStatus={
        skillCatalog.status === "loading" ? (
          <PageLoading label={messages.common_loading()} />
        ) : skillCatalog.status === "error" ? (
          <div className="flex flex-col items-center gap-md px-md py-3xl">
            <p role="alert" className="m-0 text-sm text-secondary">
              {messages.plugins_skills_load_failed()}
            </p>
            <Button hierarchy="secondary-gray" onPress={skillCatalog.retry} size="sm">
              {messages.common_retry()}
            </Button>
          </div>
        ) : null
      }
      skillCategories={skillCategories}
      {...(skillCategoryId ? { skillCategoryId } : {})}
      skills={skills.map((skill) => ({
        id: skill.skill_id,
        name: skill.name,
        ...(skill.description ? { description: skill.description } : {}),
        ...(skill.source ? { categoryId: skill.source } : {}),
      }))}
      tab={catalogTab}
    />
  );
}

function PluginsRouteStatus({
  children,
  label,
  role,
}: {
  children: ReactNode;
  label: string;
  role?: "alert";
}) {
  return (
    <section
      aria-label={label}
      className="flex size-full min-h-0 flex-col items-center justify-center gap-md bg-primary p-3xl text-sm text-secondary"
      role={role}
    >
      {children}
    </section>
  );
}

function pluginCategories(
  plugins: readonly CommaPlugin[],
  definitionById: ReadonlyMap<string, PluginDefinition>,
  fallbackCategoryName: string
): PluginCategory[] {
  const categories = new Map<string, { name: string; plugins: PluginDefinition[] }>();

  for (const plugin of plugins) {
    if (plugin.installed) continue;
    const sourceCategory = plugin.category.trim();
    const categoryId = sourceCategory || "Integrations";
    const categoryName =
      categoryId === "Integrations" ? fallbackCategoryName : categoryId;
    const category = categories.get(categoryId) ?? {
      name: categoryName,
      plugins: [],
    };
    category.plugins.push(definitionById.get(plugin.id)!);
    categories.set(categoryId, category);
  }

  return Array.from(categories, ([id, category]) => ({
    id: id.toLocaleLowerCase().replace(/[^a-z0-9]+/g, "-"),
    name: category.name,
    plugins: category.plugins,
  }));
}

function toPluginDefinition(plugin: CommaPlugin): PluginDefinition {
  // MCPs carry no brand of their own; they show their plugin's product logo.
  const icon = <PluginBrandArtwork brand={plugin.brand} name={plugin.name} />;
  return {
    icon,
    id: plugin.id,
    mcps: plugin.mcps.map((resource) => ({ ...resource, icon })),
    name: plugin.name,
    skills: plugin.skills,
    summary: plugin.summary,
    ...(plugin.description ? { description: plugin.description } : {}),
  };
}

function workspaceSupportsPlugins(workspace: {
  status?: "failed" | "provisioning" | "ready" | undefined;
}) {
  return workspace.status === undefined || workspace.status === "ready";
}
