import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import {
  Button,
  CubeIcon,
  MarkdownStream,
  Menu,
  MenuItem,
  MenuPopover,
  MenuTrigger,
  MoreHorizontalIcon,
  NativeSurfaceSuppressor,
  PageLoading,
  PluginDetail,
  PluginDetailSection,
  SkillFileBrowser,
  SkillFileSource,
  spacing,
  toast,
  type PluginDetailCopy,
  type SkillFileView,
} from "@comma/ui";
import { useEffect, useRef, useState } from "react";
import type { CommaApiClient, CommaSkill } from "../../api";
import { useCommaUiThemeName } from "../commaUiTheme";
import { nativePlatformClipboard } from "../../runtime-chat/nativePlatformActions";
import { revealLabel, saveFileAndShow } from "../../runtime-files/fileDownloads";
import { portableSkillMarkdown, skillMarkdownBody } from "./skillMarkdown";

type SkillContentState =
  | { status: "loading" }
  | { status: "error" }
  | { status: "ready"; files: readonly string[]; markdown: string };

type SkillFileState =
  | { status: "loading" }
  | { status: "error" }
  | { status: "ready"; content: string };

const entryFilePath = "SKILL.md";

export function SkillDetailPage({
  api,
  categoryName,
  copy,
  onBack,
  onTryInChat,
  skill,
  workspaceId,
}: {
  api: CommaApiClient;
  categoryName?: string | undefined;
  copy: PluginDetailCopy;
  onBack: () => void;
  onTryInChat: () => void;
  skill: CommaSkill;
  workspaceId: string;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const bridge = getNativeBridge();
  const isDark = useCommaUiThemeName() === "Dark mode";
  const [state, setState] = useState<SkillContentState>({ status: "loading" });
  // The Downloads copy made by Open / Reveal, reused for this skill's page.
  const downloadRef = useRef<string | undefined>(undefined);

  useEffect(() => {
    const controller = new AbortController();
    setState({ status: "loading" });
    void api
      .getWorkspaceSkill(workspaceId, skill.skill_id, { signal: controller.signal })
      .then((detail) => {
        if (controller.signal.aborted) return;
        setState({
          // A skill always has its entry file, even when the catalog lists none.
          files: detail.files.includes(entryFilePath)
            ? detail.files
            : [entryFilePath, ...detail.files],
          markdown: detail.content,
          status: "ready",
        });
      })
      .catch(() => {
        if (!controller.signal.aborted) setState({ status: "error" });
      });
    return () => controller.abort();
  }, [api, skill.skill_id, workspaceId]);

  const markdown = state.status === "ready" ? state.markdown : undefined;
  const [selectedPath, setSelectedPath] = useState(entryFilePath);
  const [view, setView] = useState<SkillFileView>("rendered");
  const [file, setFile] = useState<SkillFileState>({ status: "loading" });

  useEffect(() => {
    if (markdown === undefined) return undefined;
    if (selectedPath === entryFilePath) {
      setFile({ content: markdown, status: "ready" });
      return undefined;
    }
    const controller = new AbortController();
    setFile({ status: "loading" });
    void api
      .getWorkspaceSkillFile(workspaceId, skill.skill_id, selectedPath, {
        signal: controller.signal,
      })
      .then((loaded) => {
        if (!controller.signal.aborted) {
          setFile({ content: loaded.content, status: "ready" });
        }
      })
      .catch(() => {
        if (!controller.signal.aborted) setFile({ status: "error" });
      });
    return () => controller.abort();
  }, [api, markdown, selectedPath, skill.skill_id, workspaceId]);

  const isMarkdownFile = /\.(md|markdown)$/i.test(selectedPath);
  const showLocalCopy = async (show: "open" | "reveal") => {
    if (markdown === undefined) return;
    downloadRef.current = await saveFileAndShow(
      {
        content: new Blob([markdown], { type: "text/markdown" }),
        fileName: `${skill.skill_id}.md`,
      },
      show,
      { bridge, downloadRef: downloadRef.current, locale }
    );
  };
  const copyMarkdown = async () => {
    if (markdown === undefined) return;
    try {
      await nativePlatformClipboard.writeText(
        portableSkillMarkdown(skill.name, markdown)
      );
      toast.success(messages.plugins_skills_markdown_copied());
    } catch {
      toast.error(messages.plugins_skills_copy_failed());
    }
  };

  return (
    <PluginDetail
      className="comma-plugins-route"
      copy={{ ...copy, backLabel: messages.plugins_skills_back() }}
      headerActions={
        <MenuTrigger>
          <Button
            aria-label={messages.plugins_skills_actions()}
            className="size-7 p-0"
            hierarchy="tertiary-gray"
            iconLeading={<MoreHorizontalIcon />}
            iconOnly
            isDisabled={markdown === undefined}
            size="sm"
          />
          <MenuPopover offset={spacing.xs} placement="bottom end">
            <NativeSurfaceSuppressor />
            <Menu
              aria-label={messages.plugins_skills_actions()}
              className="w-44 bg-popup-secondary px-sm py-sm shadow-2xl"
              onAction={(key) => {
                if (key === "copy") void copyMarkdown();
                else void showLocalCopy(key === "open" ? "open" : "reveal");
              }}
            >
              {/* A browser cannot open or reveal a local file. */}
              {bridge.platform === "electron" ? (
                <>
                  <MenuItem contentClassName="h-8" gutter="none" id="open">
                    {messages.plugins_skills_open()}
                  </MenuItem>
                  <MenuItem contentClassName="h-8" gutter="none" id="reveal">
                    {revealLabel(bridge.os, locale)}
                  </MenuItem>
                </>
              ) : null}
              <MenuItem contentClassName="h-8" gutter="none" id="copy">
                {messages.plugins_skills_copy_markdown()}
              </MenuItem>
            </Menu>
          </MenuPopover>
        </MenuTrigger>
      }
      installed
      onBack={onBack}
      onTryInChat={onTryInChat}
      plugin={{
        icon: <CubeIcon className="text-fg-tertiary" />,
        id: skill.skill_id,
        name: skill.name,
        summary: categoryName ?? messages.plugins_skills_kind(),
        ...(skill.description ? { description: skill.description } : {}),
      }}
    >
      <PluginDetailSection title={messages.plugins_skills_content()}>
        {state.status === "loading" ? (
          <div className="px-md py-3xl">
            <PageLoading label={messages.common_loading()} />
          </div>
        ) : state.status === "error" ? (
          <output className="block px-md text-sm text-quaternary">
            {messages.plugins_skills_content_failed()}
          </output>
        ) : (
          <SkillFileBrowser
            canRender={isMarkdownFile}
            filesLabel={messages.plugins_skills_files()}
            onSelectPath={setSelectedPath}
            onViewChange={setView}
            paths={state.files}
            renderedLabel={messages.plugins_skills_view_rendered()}
            selectedPath={selectedPath}
            sourceLabel={messages.plugins_skills_view_source()}
            view={view}
            viewLabel={messages.plugins_skills_view()}
          >
            {file.status === "loading" ? (
              <div className="py-3xl">
                <PageLoading label={messages.common_loading()} />
              </div>
            ) : file.status === "error" ? (
              <output className="block text-sm text-quaternary">
                {messages.plugins_skills_file_failed()}
              </output>
            ) : isMarkdownFile && view === "rendered" ? (
              <MarkdownStream
                animation="none"
                content={skillMarkdownBody(file.content)}
                final
                htmlPolicy="escape"
                streamId={`${skill.skill_id}:${selectedPath}`}
              />
            ) : (
              <SkillFileSource
                isDark={isDark}
                path={selectedPath}
                text={file.content}
              />
            )}
          </SkillFileBrowser>
        )}
      </PluginDetailSection>
    </PluginDetail>
  );
}
