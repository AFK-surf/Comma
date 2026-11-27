// Folding a section of the page a reader edits (`DocumentEditor`). A section is a heading and what is under it, up
// to the next heading of its level or a higher one. A chevron by a heading folds its section away and shows it
// again. The fold is how the page is shown, not part of the document: the Markdown the page writes is the same.
//
// A reader never types in text they cannot see: when the caret comes into a folded section (a key moves it there,
// Enter after the heading makes a line there, the outline goes to a heading in it), the section is shown.
import { useCommaMessages } from "@comma/i18n/react";
import { ChevronDownSmallIcon } from "@comma/ui/components/icons";
import { Tooltip } from "@comma/ui/components/tooltip";
import { Extension, type Editor } from "@tiptap/core";
import type { Node as PageNode } from "@tiptap/pm/model";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { useEditorState } from "@tiptap/react";
import { useEffect, useState } from "react";
import { Focusable } from "react-aria-components";
import { revealSectionEvent } from "./documentReveal";

/** The headings whose sections are folded, by where each heading starts in the document. */
const sections = new PluginKey<readonly number[]>("commaDocumentSections");

/** What changes the folds: one heading's fold is turned, or what holds a place is shown. */
type Turn = { toggle: number } | { reveal: number };

/**
 * What is under the heading that starts at `pos`: from the heading's end to the next heading of its level or a
 * higher one. Undefined where `pos` is no heading of the page's own blocks.
 */
function sectionOf(doc: PageNode, pos: number) {
  if (pos < 0 || pos >= doc.content.size) return undefined;
  const at = doc.resolve(pos);
  const heading = at.nodeAfter;
  if (at.depth !== 0 || heading?.type.name !== "heading") return undefined;
  const from = pos + heading.nodeSize;
  let to = from;
  for (let index = at.index() + 1; index < doc.childCount; index += 1) {
    const block = doc.child(index);
    if (
      block.type.name === "heading" &&
      Number(block.attrs.level) <= Number(heading.attrs.level)
    )
      break;
    to += block.nodeSize;
  }
  return { from, to };
}

/** The folds without those that hold `place`. */
const revealed = (doc: PageNode, folded: readonly number[], place: number) =>
  folded.filter((pos) => {
    const section = sectionOf(doc, pos);
    return !section || place <= section.from || place >= section.to;
  });

/** Keeps the folds of a page, hides what they fold, and shows a section the caret comes into. */
export const SectionFolding = Extension.create({
  name: "sectionFolding",
  addProseMirrorPlugins: () => [
    new Plugin<readonly number[]>({
      key: sections,
      state: {
        init: () => [],
        apply(tr, folded) {
          // A fold follows its heading through an edit, and goes with it.
          let next = tr.docChanged
            ? folded
                .map((pos) => tr.mapping.map(pos))
                .filter((pos) => sectionOf(tr.doc, pos) !== undefined)
            : folded;
          const turn = tr.getMeta(sections) as Turn | undefined;
          if (turn && "toggle" in turn)
            next = next.includes(turn.toggle)
              ? next.filter((pos) => pos !== turn.toggle)
              : sectionOf(tr.doc, turn.toggle)
                ? [...next, turn.toggle]
                : next;
          else if (turn) next = revealed(tr.doc, next, turn.reveal);
          return next;
        },
      },
      appendTransaction(_transactions, _before, state) {
        const folded = sections.getState(state) ?? [];
        const { from, to } = state.selection;
        const held = [from, to].find(
          (place) => revealed(state.doc, folded, place).length !== folded.length
        );
        return held === undefined
          ? null
          : state.tr.setMeta(sections, { reveal: held } satisfies Turn);
      },
      props: {
        decorations(state) {
          const folded = sections.getState(state) ?? [];
          if (folded.length === 0) return DecorationSet.empty;
          const marks: Decoration[] = [];
          for (const pos of folded) {
            const section = sectionOf(state.doc, pos);
            if (!section) continue;
            marks.push(Decoration.node(pos, section.from, { "data-folded": "true" }));
            state.doc.nodesBetween(section.from, section.to, (block, at) => {
              marks.push(
                Decoration.node(at, at + block.nodeSize, {
                  class: "comma-document-folded",
                })
              );
              // The page's own blocks alone: what is in them goes with them.
              return false;
            });
          }
          return DecorationSet.create(state.doc, marks);
        },
      },
    }),
  ],
});

/**
 * The chevrons of the page's sections. One stands by the heading the pointer is level with, one by the heading
 * the caret is in, and one by every heading whose section is folded.
 */
export function SectionFolds({
  editor,
  frame,
}: {
  editor: Editor;
  /** What the chevrons are placed in: the page's own frame. */
  frame: HTMLElement | null;
}) {
  const messages = useCommaMessages();
  const state = useEditorState({
    editor,
    selector: ({ editor: current }) => {
      const at = current.state.selection.$from;
      return {
        folded: sections.getState(current.state) ?? [],
        // The caret's heading, where it is one of the page's own blocks.
        caret:
          at.depth === 1 && at.parent.type.name === "heading"
            ? at.before(1)
            : undefined,
        // The chevrons are placed again as the page's text changes.
        doc: current.state.doc,
      };
    },
    // The page's text is compared as the one thing it is, not part by part.
    equalityFn: (one, other) =>
      one.doc === other?.doc &&
      one.caret === other.caret &&
      one.folded === other.folded,
  });
  // The heading the pointer is level with: the chevron is in the page's margin, beside the heading and not on it.
  const [level, setLevel] = useState<number>();
  useEffect(() => {
    const page = frame?.closest<HTMLElement>(".comma-document-page");
    const root = frame?.querySelector<HTMLElement>(".comma-document-editor");
    if (!page || !root) return undefined;
    const move = (event: MouseEvent) => {
      const heading = Array.from(
        root.querySelectorAll<HTMLElement>(":scope > :is(h1, h2, h3, h4, h5, h6)")
      ).find((one) => {
        const box = one.getBoundingClientRect();
        // A heading folded away with a section it is in has no place: the pointer is level with none such.
        return (
          box.height > 0 && event.clientY >= box.top && event.clientY <= box.bottom
        );
      });
      setLevel(heading ? editor.view.posAtDOM(heading, 0) - 1 : undefined);
    };
    const leave = () => setLevel(undefined);
    // Another part of the page goes to an element of it: what folds the element away is shown first.
    const reveal = (event: Event) => {
      if (!(event.target instanceof Node) || !root.contains(event.target)) return;
      editor.view.dispatch(
        editor.state.tr.setMeta(sections, {
          reveal: editor.view.posAtDOM(event.target, 0),
        } satisfies Turn)
      );
    };
    page.addEventListener("mousemove", move);
    page.addEventListener("mouseleave", leave);
    root.addEventListener(revealSectionEvent, reveal);
    return () => {
      page.removeEventListener("mousemove", move);
      page.removeEventListener("mouseleave", leave);
      root.removeEventListener(revealSectionEvent, reveal);
    };
  }, [editor, frame]);
  if (!frame) return null;

  const origin = frame.getBoundingClientRect();
  const shown = [
    ...new Set([
      ...state.folded,
      ...(state.caret === undefined ? [] : [state.caret]),
      ...(level === undefined ? [] : [level]),
    ]),
  ];
  return shown.map((pos) => {
    // A heading with nothing under it has nothing to fold.
    const section = sectionOf(state.doc, pos);
    const heading = section ? editor.view.nodeDOM(pos) : null;
    if (!section || section.from === section.to || !(heading instanceof HTMLElement))
      return null;
    // A heading that is folded away with a section it is in has no place.
    const box = heading.getBoundingClientRect();
    if (box.height === 0) return null;
    const folded = state.folded.includes(pos);
    const label = folded
      ? messages.file_preview_document_section_expand()
      : messages.file_preview_document_section_collapse();
    return (
      <Tooltip content={label} key={pos} placement="top">
        <Focusable>
          <button
            aria-expanded={!folded}
            aria-label={label}
            className="comma-document-fold"
            data-testid="document-section-fold"
            // The press leaves the caret where it is in the page.
            onMouseDown={(event) => {
              event.preventDefault();
              const turn = editor.state.tr.setMeta(sections, {
                toggle: pos,
              } satisfies Turn);
              // A caret in what is folded away goes to the end of the heading: it stays where the reader sees it.
              const { from } = editor.state.selection;
              if (!folded && from > section.from && from < section.to)
                turn.setSelection(
                  TextSelection.near(turn.doc.resolve(section.from - 1), -1)
                );
              editor.view.dispatch(turn);
            }}
            style={{
              left: box.left - origin.left,
              top: box.top - origin.top,
              // The chevron is at the middle of the heading's first line.
              height: getComputedStyle(heading).lineHeight,
            }}
            type="button"
          >
            <ChevronDownSmallIcon aria-hidden className="size-xl" />
          </button>
        </Focusable>
      </Tooltip>
    );
  });
}
