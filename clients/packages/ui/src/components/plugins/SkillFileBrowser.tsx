import { useEffect, useMemo, useState, type ReactNode } from "react";
import { ChevronDownSmallIcon, CodeIcon, EyeIcon, FolderIcon } from "../icons";
import { codeTokenStyle } from "../markdown-stream/MarkdownStream";
import {
  highlightedCodeLines,
  type ShikiHighlightResult,
} from "../markdown-stream/shikiHighlightTokens";
import { renderCodeHighlightInWorker } from "../markdown-stream/shikiHighlightWorkerClient";
import { cx } from "../utils";

export type SkillFileView = "rendered" | "source";

export interface SkillFileBrowserProps {
  /** File paths inside the skill, e.g. `SKILL.md`, `references/format.md`. */
  paths: readonly string[];
  selectedPath: string;
  onSelectPath: (path: string) => void;
  view: SkillFileView;
  onViewChange: (view: SkillFileView) => void;
  /** Whether the selected file has a rendered form; otherwise only source shows. */
  canRender: boolean;
  filesLabel: string;
  viewLabel: string;
  renderedLabel: string;
  sourceLabel: string;
  children: ReactNode;
  className?: string;
}

interface SkillFileTreeNode {
  name: string;
  path: string;
  children?: SkillFileTreeNode[];
}

const entryFileName = "SKILL.md";

const buildSkillFileTree = (paths: readonly string[]): SkillFileTreeNode[] => {
  const root: SkillFileTreeNode[] = [];
  for (const path of paths) {
    let level = root;
    const segments = path.split("/");
    segments.forEach((name, index) => {
      const isFile = index === segments.length - 1;
      const nodePath = segments.slice(0, index + 1).join("/");
      let node = level.find((candidate) => candidate.path === nodePath);
      if (!node) {
        node = { name, path: nodePath, ...(isFile ? {} : { children: [] }) };
        level.push(node);
      }
      level = node.children ?? level;
    });
  }

  const sort = (nodes: SkillFileTreeNode[]) => {
    // The entry file leads; then files, then folders, each by name.
    nodes.sort(
      (a, b) =>
        Number(b.path === entryFileName) - Number(a.path === entryFileName) ||
        Number(Boolean(a.children)) - Number(Boolean(b.children)) ||
        a.name.localeCompare(b.name)
    );
    for (const node of nodes) if (node.children) sort(node.children);
    return nodes;
  };
  return sort(root);
};

const SkillFileTree = ({
  depth,
  nodes,
  onSelectPath,
  selectedPath,
}: {
  depth: number;
  nodes: readonly SkillFileTreeNode[];
  onSelectPath: (path: string) => void;
  selectedPath: string;
}) => {
  const [collapsedPaths, setCollapsedPaths] = useState<ReadonlySet<string>>(
    () => new Set()
  );

  return (
    <ul className="m-0 flex list-none flex-col gap-xxs p-0">
      {nodes.map((node) => {
        const rowClasses =
          "flex w-full min-w-0 items-center gap-sm rounded-md border-0 bg-transparent py-xs pr-md text-left text-sm outline-none transition-colors focus-visible:shadow-focus-gray";
        const indent = {
          paddingInlineStart: `calc(var(--spacing-md) * ${depth * 2 + 1})`,
        };

        if (!node.children) {
          const selected = node.path === selectedPath;
          return (
            <li key={node.path}>
              <button
                aria-current={selected ? "true" : undefined}
                className={cx(
                  rowClasses,
                  selected
                    ? "bg-secondary font-medium text-primary"
                    : "text-tertiary hover:text-primary"
                )}
                onClick={() => onSelectPath(node.path)}
                style={indent}
                type="button"
              >
                <span className="min-w-0 truncate">{node.name}</span>
              </button>
            </li>
          );
        }

        const collapsed = collapsedPaths.has(node.path);
        return (
          <li key={node.path}>
            <button
              aria-expanded={!collapsed}
              className={cx(rowClasses, "text-tertiary hover:text-primary")}
              onClick={() =>
                setCollapsedPaths((current) => {
                  const next = new Set(current);
                  if (!next.delete(node.path)) next.add(node.path);
                  return next;
                })
              }
              style={indent}
              type="button"
            >
              <FolderIcon className="size-4 shrink-0 text-fg-tertiary" />
              <span className="min-w-0 flex-1 truncate">{node.name}</span>
              <ChevronDownSmallIcon
                className={cx(
                  "size-4 shrink-0 text-fg-tertiary transition-transform",
                  collapsed && "-rotate-90"
                )}
              />
            </button>
            {collapsed ? null : (
              <SkillFileTree
                depth={depth + 1}
                nodes={node.children}
                onSelectPath={onSelectPath}
                selectedPath={selectedPath}
              />
            )}
          </li>
        );
      })}
    </ul>
  );
};

export const SkillFileBrowser = ({
  paths,
  selectedPath,
  onSelectPath,
  view,
  onViewChange,
  canRender,
  filesLabel,
  viewLabel,
  renderedLabel,
  sourceLabel,
  children,
  className,
}: SkillFileBrowserProps) => {
  const tree = useMemo(() => buildSkillFileTree(paths), [paths]);
  const views = [
    { icon: <EyeIcon />, id: "rendered", label: renderedLabel },
    { icon: <CodeIcon />, id: "source", label: sourceLabel },
  ] as const;

  return (
    <div
      className={cx(
        "flex w-full min-w-0 overflow-hidden rounded-xl border border-primary",
        className
      )}
      data-slot="skill-file-browser"
    >
      <nav
        aria-label={filesLabel}
        className="w-[200px] shrink-0 border-r border-primary p-sm"
      >
        <SkillFileTree
          depth={0}
          nodes={tree}
          onSelectPath={onSelectPath}
          selectedPath={selectedPath}
        />
      </nav>
      <div className="flex min-w-0 flex-1 flex-col gap-lg p-xl">
        <div className="flex min-h-7 items-center justify-between gap-md">
          <span className="min-w-0 truncate font-mono text-sm text-tertiary">
            /{selectedPath}
          </span>
          {canRender ? (
            <fieldset
              aria-label={viewLabel}
              className="m-0 flex min-w-0 shrink-0 items-center gap-xxs rounded-md border-0 bg-secondary p-xxs"
            >
              {views.map((option) => {
                const pressed = option.id === view;
                return (
                  <button
                    aria-label={option.label}
                    aria-pressed={pressed}
                    className={cx(
                      "inline-flex size-6 items-center justify-center rounded-sm border-0 outline-none transition-colors focus-visible:shadow-focus-gray [&_svg]:size-4",
                      pressed
                        ? "bg-primary text-primary shadow-xs"
                        : "bg-transparent text-fg-tertiary hover:text-primary"
                    )}
                    key={option.id}
                    onClick={() => onViewChange(option.id)}
                    type="button"
                  >
                    {option.icon}
                  </button>
                );
              })}
            </fieldset>
          ) : null}
        </div>
        <div className="min-w-0 text-sm" data-slot="skill-file-content">
          {children}
        </div>
      </div>
    </div>
  );
};

const sourceLanguageByExtension: Record<string, string> = {
  bash: "bash",
  css: "css",
  html: "html",
  js: "javascript",
  json: "json",
  jsx: "jsx",
  markdown: "markdown",
  md: "markdown",
  py: "python",
  sh: "bash",
  toml: "toml",
  ts: "typescript",
  tsx: "tsx",
  yaml: "yaml",
  yml: "yaml",
};

/**
 * A text file as numbered source lines; long lines wrap under their number.
 * Colors come from the chat code block's Shiki worker; until they arrive, and
 * for unknown file types, the lines read as plain text.
 */
export const SkillFileSource = ({
  isDark = false,
  path,
  text,
}: {
  isDark?: boolean;
  path: string;
  text: string;
}) => {
  const extension = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  const language = sourceLanguageByExtension[extension] ?? "plaintext";
  const theme = isDark ? "vitesse-dark" : "vitesse-light";
  const [highlight, setHighlight] = useState<{
    key: string;
    result: ShikiHighlightResult;
  }>();
  const highlightKey = JSON.stringify([language, theme, text]);

  useEffect(() => {
    let active = true;
    void renderCodeHighlightInWorker(text, language, theme)
      .then((result) => {
        if (active) setHighlight({ key: highlightKey, result });
      })
      // A failed highlight leaves the readable plain lines in place.
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [highlightKey, language, text, theme]);

  const lines = useMemo(
    () =>
      highlightedCodeLines(
        text,
        highlight?.key === highlightKey ? highlight.result : undefined
      ),
    [highlight, highlightKey, text]
  );

  return (
    <ol
      className="m-0 grid list-none grid-cols-[auto_minmax(0,1fr)] gap-x-lg p-0 font-mono text-sm text-secondary"
      data-slot="skill-file-source"
    >
      {lines.map((tokens, index) => (
        // Source lines have no identity beyond their position.
        // eslint-disable-next-line react/no-array-index-key
        <li className="col-span-2 grid grid-cols-subgrid" key={index}>
          <span aria-hidden="true" className="select-none text-right text-quaternary">
            {index + 1}
          </span>
          <span className="whitespace-pre-wrap break-all">
            {tokens.length > 0
              ? tokens.map((token) => (
                  <span key={token.offset} style={codeTokenStyle(token)}>
                    {token.content}
                  </span>
                ))
              : " "}
          </span>
        </li>
      ))}
    </ol>
  );
};
