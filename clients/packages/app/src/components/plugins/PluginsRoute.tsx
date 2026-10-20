import { PageLoading } from "@comma/ui/components/PageLoading";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import {
  PluginCatalog,
  PluginDetail,
  type PluginCatalogCopy,
  type PluginCatalogTab,
  type PluginCategory,
  type PluginDefinition,
  type PluginDetailCopy,
} from "@comma/ui/components/plugins";
import { toast } from "@comma/ui/components/toast";
import { useNavigate } from "@tanstack/react-router";
import { useCall, useTopic, type Plugin } from "@comma/core-client";
import { useCallback, useEffect, useState, type ReactNode } from "react";
import { PluginBrandArtwork } from "./PluginBrandArtwork";
import { usePluginInstall } from "./pluginInstall";
import { PluginPersonalSources, withMcpGrants } from "./PluginPersonalSources";
import { SkillDetailPage } from "./SkillDetailPage";
import { usePluginPersonalSources } from "./usePluginPersonalSources";
import { useSelectWorkspace, useWorkspacePreference } from "../activeWorkspace";
import { useWorkspaceSkillsState } from "../chat/useWorkspaceSkills";

export function PluginsRoute() {
  const installation = usePluginInstall();
  const call = useCall();
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
  // The core picks the workspace: the active one when it can have plugins, else the first that can.
  const preferredWorkspaceId = useWorkspacePreference();
  const selectWorkspace = useSelectWorkspace();
  const { value: state = { status: "loading" } } = useTopic(
    preferredWorkspaceId === undefined
      ? null
      : { topic: "plugins", prefer: preferredWorkspaceId }
  );
  const [selectedPluginId, setSelectedPluginId] = useState<string>();
  const [catalogTab, setCatalogTab] = useState<PluginCatalogTab>("plugins");
  const [selectedSkillId, setSelectedSkillId] = useState<string>();
  const [skillCategoryId, setSkillCategoryId] = useState<string>();

  const workspaceId = state.status === "ready" ? state.workspace : undefined;
  useEffect(() => {
    if (workspaceId) selectWorkspace(workspaceId);
  }, [workspaceId, selectWorkspace]);
  const retry = useCallback(
    () =>
      void call("plugins.refresh", {
        workspace: state.status === "error" ? (state.workspace ?? "") : "",
      }).catch(() => undefined),
    [call, state]
  );

  const selectedPlugin =
    state.status === "ready"
      ? state.plugins.find((plugin) => plugin.id === selectedPluginId)
      : undefined;
  const personalSources = usePluginPersonalSources({
    workspaceId,
    pluginId: selectedPlugin?.installed ? selectedPlugin.id : undefined,
  });

  const skillCatalog = useWorkspaceSkillsState(workspaceId ?? "");
  const skills = skillCatalog.skills;

  const mutatePlugin = (pluginId: string, installed: boolean) => {
    if (!workspaceId) return;
    if (installed) {
      void installation.install({ pluginId, workspaceId });
      return;
    }
    // The core stops an install under way first; a failure is its notice.
    void call("plugin.uninstall", { plugin: pluginId, workspace: workspaceId }).catch(
      () => undefined
    );
  };

  // Load failures ride the toast stack with a Retry action; the panel keeps a
  // quiet placeholder so the content area is never blank.
  const errorMessage = state.status === "error" ? state.error.message : undefined;
  useEffect(() => {
    if (state.status !== "error") return undefined;
    // Each effect owns its toast. A delayed dismissal must not close a retry's toast.
    const toastId = toast.error(messages.plugins_load_failed(), {
      ...(errorMessage ? { description: errorMessage } : {}),
      actions: [{ label: messages.common_retry(), onPress: retry }],
      testId: "plugins-load-error",
    });
    return () => {
      toast.dismiss(toastId);
    };
  }, [errorMessage, messages, retry, state.status]);

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
        <Button hierarchy="secondary-gray" onPress={retry} size="sm">
          {messages.common_retry()}
        </Button>
      </PluginsRouteStatus>
    );
  }

  // A request in flight; an authorization waiting on the browser is not one.
  const pendingIds = new Set(
    state.plugins
      .filter(
        (plugin) =>
          plugin.activity === "installing" ||
          plugin.activity === "verifying" ||
          plugin.activity === "reauthorizing" ||
          plugin.activity === "uninstalling"
      )
      .map((plugin) => plugin.id)
  );
  const pluginDefinitions = state.plugins.map(toPluginDefinition);
  const definitionById = new Map(
    pluginDefinitions.map((plugin) => [plugin.id, plugin])
  );

  if (selectedPlugin) {
    const reauthorizingConnectionId = selectedPlugin.reauthorizing;
    const reauthorize = (connectionId: string) => {
      personalSources.cancel();
      void installation.reauthorize({
        pluginId: selectedPlugin.id,
        workspaceId: state.workspace,
        connectionId,
      });
    };
    const plugin = withMcpGrants(definitionById.get(selectedPlugin.id)!, {
      onReauthorize: reauthorize,
      personalSources,
      pluginName: selectedPlugin.name,
      reauthorizingConnectionId,
    });
    if (selectedPlugin.credentialSetup) {
      plugin.description = [
        plugin.description ?? plugin.summary,
        messages.plugins_credentials_description({ name: selectedPlugin.name }),
      ].join(" ");
      if (selectedPlugin.installed) {
        plugin.mcps = (plugin.mcps ?? []).map((resource) => ({
          ...resource,
          trailingContent: (
            <Button
              className="relative -my-xxs h-7 px-lg py-xs after:absolute after:inset-x-0 after:-inset-y-md"
              hierarchy="tertiary-gray"
              size="sm"
              isDisabled={pendingIds.has(selectedPlugin.id)}
              onPress={() => void mutatePlugin(selectedPlugin.id, true)}
            >
              {messages.plugins_credentials_update()}
            </Button>
          ),
        }));
      }
    }

    return (
      <PluginDetail
        className="comma-plugins-route"
        copy={detailCopy}
        installed={selectedPlugin.installed}
        installPending={pendingIds.has(selectedPlugin.id)}
        onBack={() => setSelectedPluginId(undefined)}
        onInstall={() => mutatePlugin(selectedPlugin.id, true)}
        onTryInChat={() => void navigate({ to: "/" })}
        plugin={plugin}
        {...(!selectedPlugin.locked
          ? {
              onUninstall: () => mutatePlugin(selectedPlugin.id, false),
              uninstallPending: selectedPlugin.activity === "uninstalling",
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
        categoryName={
          skillCategories.find((category) => category.id === selectedSkill.source)?.name
        }
        copy={detailCopy}
        onBack={() => setSelectedSkillId(undefined)}
        onTryInChat={() => void navigate({ to: "/" })}
        skill={selectedSkill}
        workspaceId={state.workspace}
      />
    );
  }

  const installedPlugins = state.installed.map((id) => definitionById.get(id)!);
  const categories: PluginCategory[] = state.categories.map((category) => ({
    id: category.id,
    name: category.name ?? messages.plugins_category_integrations(),
    plugins: category.plugins.map((id) => definitionById.get(id)!),
  }));

  return (
    <PluginCatalog
      className="comma-plugins-route"
      categories={categories}
      copy={catalogCopy}
      installedPlugins={installedPlugins}
      onPluginInstall={(plugin) => mutatePlugin(plugin.id, true)}
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

function toPluginDefinition(plugin: Plugin): PluginDefinition {
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
