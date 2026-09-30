import "@comma/ui/styles.css";
import { nativePlatformClipboard } from "../../../../../packages/app/src/runtime-chat/nativePlatformActions";
import { isAllowedAttachment } from "../../../../../packages/app/src/components/chat/model/protocol";

import {
  AiInput,
  createAiInputRichValue,
  type AiInputAttachment,
  type AiInputMenuRegistration,
  type AiInputRichTokenSegment,
  type AiInputRichValue,
} from "@comma/ui";
import { StrictMode, useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";

const quoteDetail =
  "圆橡皮，中间留出金属箍空隙。\n点 形状 → 铅笔 会得到一支完整的铅笔。";

const initialAttachments: AiInputAttachment[] = [
  {
    id: "quote",
    type: "quote",
    name: "圆橡皮，中间留出金属箍空隙。",
    detail: quoteDetail,
  },
  {
    id: "image",
    type: "image",
    name: "Generated asset",
  },
  { id: "image-loading", type: "image", name: "Uploading shot.png", state: "loading" },
  { id: "image-error", type: "image", name: "Broken shot.png", state: "error" },
  { id: "file", type: "file", name: "Openai", meta: "PDF" },
];

const richMenus: AiInputMenuRegistration[] = [
  {
    id: "skills",
    trigger: "/",
    label: "Skills",
    groups: [
      {
        id: "fixture-skills",
        items: [
          { id: "alpha", label: "Alpha" },
          { id: "beta", label: "Beta" },
        ],
      },
    ],
  },
];

const mentionMenu = (
  onAddFiles: () => void,
  routinesLoading: boolean,
  routinesReady: boolean
): AiInputMenuRegistration => ({
  id: "mentions",
  trigger: "@",
  label: "Mentions",
  maxItems: Number.POSITIVE_INFINITY,
  groups: [
    {
      id: "add",
      label: "Add",
      items: [
        {
          id: "add-files-or-folders",
          label: "Add files or folders",
          keywords: ["upload", "attach"],
          action: onAddFiles,
        },
      ],
    },
    {
      id: "tasks",
      label: "Tasks",
      items: [
        {
          id: "task:cnv1_e2e",
          label: "Fix login flow",
          plainText: "[Fix login flow](comma:task/cnv1_e2e)",
        },
        {
          id: "task:cnv1_long",
          label:
            "Overflowing extremely long task title used to assert that menu rows and composer tokens clamp and ellipsize instead of spilling out",
          plainText: "[Overflowing task](comma:task/cnv1_long)",
        },
      ],
    },
    // Toggled by specs to assert the indexing/searching state.
    ...(routinesLoading
      ? [{ id: "routines", label: "Routines", status: "loading" as const, items: [] }]
      : routinesReady
        ? [
            {
              id: "routines",
              label: "Routines",
              items: [
                {
                  id: "routine:daily-digest",
                  label: "Daily digest",
                  plainText: "https://example.test/daily-digest",
                },
              ],
            },
          ]
        : []),
  ],
});

let plainClipboardText = "";
const plainClipboard = {
  async readText() {
    return plainClipboardText;
  },
  async writeText(_text: string) {},
};

function restoredRichValue(revision: number) {
  const token: AiInputRichTokenSegment = {
    type: "token",
    instanceId: "restored-alpha",
    menuId: "skills",
    itemId: "alpha",
    trigger: "/",
    label: "Alpha",
    plainText: "/alpha",
    data: { revision },
  };
  return createAiInputRichValue([token, { type: "text", text: " draft" }]);
}

function tokenRevision(token: AiInputRichTokenSegment) {
  const data = token.data;
  if (!data || typeof data !== "object" || !("revision" in data)) return null;
  return typeof data.revision === "number" ? data.revision : null;
}

declare global {
  interface Window {
    aiInputFixture?: {
      getSnapshot: () => {
        textareaClientHeight: number;
        textareaMaxHeight: string;
        textareaOverflowY: string;
        textareaScrollHeight: number;
        value: string;
      };
      getRichSnapshot: () => {
        plainText: string;
        tokenItemIds: string[];
        tokenRevisions: Array<number | null>;
        lastSubmission: {
          plainText: string;
          tokenItemIds: string[];
          tokenRevisions: Array<number | null>;
        } | null;
      };
      getVoiceSnapshot: () => {
        cancels: number;
        confirms: number;
        presses: number;
      };
      getMentionSnapshot: () => { addFilesPresses: number };
      setMentionRoutinesLoading: (loading: boolean) => void;
      resolveMentionRoutines: () => void;
      loadAsyncMenus: () => void;
      resetAttachments: () => void;
      restoreRichValue: (revision?: number) => void;
      setPrimaryDisabled: (disabled: boolean) => void;
      setPrimaryReadOnly: (readOnly: boolean) => void;
      setPrimaryShowVoiceButton: (showVoiceButton: boolean) => void;
      setPrimarySubmitPending: (submitPending: boolean) => void;
      setPlainClipboardText: (text: string) => void;
      setRichDisabled: (disabled: boolean) => void;
      setValue: (value: string) => void;
      updateRestoredTokenRevision: (revision: number) => void;
    };
  }
}

function getTextarea() {
  const textarea = document.querySelector<HTMLTextAreaElement>(
    "textarea[aria-label='AI prompt']"
  );

  if (!textarea) {
    throw new Error("AI Input textarea was not mounted.");
  }

  return textarea;
}

function AiInputFixture() {
  const [value, setValue] = useState("");
  const [attachments, setAttachments] = useState(initialAttachments);
  const [richValue, setRichValue] = useState<AiInputRichValue>(() =>
    createAiInputRichValue([])
  );
  const [lastRichSubmission, setLastRichSubmission] = useState<AiInputRichValue | null>(
    null
  );
  const [primaryDisabled, setPrimaryDisabled] = useState(false);
  const [primaryReadOnly, setPrimaryReadOnly] = useState(false);
  const [primaryShowVoiceButton, setPrimaryShowVoiceButton] = useState(true);
  const [primarySubmitPending, setPrimarySubmitPending] = useState(false);
  const [voiceLifecycle, setVoiceLifecycle] = useState({
    cancels: 0,
    confirms: 0,
    presses: 0,
  });
  const [richDisabled, setRichDisabled] = useState(false);
  const [addFilesPresses, setAddFilesPresses] = useState(0);
  const [mentionRoutinesLoading, setMentionRoutinesLoading] = useState(false);
  const [mentionRoutinesReady, setMentionRoutinesReady] = useState(false);
  const [asyncMenus, setAsyncMenus] = useState<AiInputMenuRegistration[]>([]);
  const [asyncValue, setAsyncValue] = useState("review this");
  const [overLimitValue, setOverLimitValue] = useState("1234567890");
  const [plainMaxLengthValue, setPlainMaxLengthValue] = useState("12345");

  useEffect(() => {
    window.aiInputFixture = {
      getSnapshot: () => {
        const textarea = getTextarea();
        const styles = getComputedStyle(textarea);

        return {
          textareaClientHeight: textarea.getBoundingClientRect().height,
          textareaMaxHeight: styles.maxHeight,
          textareaOverflowY: styles.overflowY,
          textareaScrollHeight: textarea.scrollHeight,
          value,
        };
      },
      getRichSnapshot: () => ({
        plainText: richValue.plainText,
        tokenItemIds: richValue.tokens.map((token) => token.itemId),
        tokenRevisions: richValue.tokens.map(tokenRevision),
        lastSubmission: lastRichSubmission
          ? {
              plainText: lastRichSubmission.plainText,
              tokenItemIds: lastRichSubmission.tokens.map((token) => token.itemId),
              tokenRevisions: lastRichSubmission.tokens.map(tokenRevision),
            }
          : null,
      }),
      getVoiceSnapshot: () => voiceLifecycle,
      getMentionSnapshot: () => ({ addFilesPresses }),
      setMentionRoutinesLoading,
      resolveMentionRoutines: () => {
        setMentionRoutinesLoading(false);
        setMentionRoutinesReady(true);
      },
      loadAsyncMenus: () => setAsyncMenus(richMenus),
      resetAttachments: () => {
        setAttachments(initialAttachments);
      },
      restoreRichValue: (revision = 1) => {
        setRichValue(restoredRichValue(revision));
        setLastRichSubmission(null);
      },
      setPrimaryDisabled,
      setPrimaryReadOnly,
      setPrimaryShowVoiceButton,
      setPrimarySubmitPending,
      setPlainClipboardText: (text) => {
        plainClipboardText = text;
      },
      setRichDisabled,
      setValue,
      updateRestoredTokenRevision: (revision) => {
        setRichValue((current) =>
          createAiInputRichValue(
            current.segments.map((segment) =>
              segment.type === "token" ? { ...segment, data: { revision } } : segment
            )
          )
        );
      },
    };

    return () => {
      delete window.aiInputFixture;
    };
  }, [addFilesPresses, lastRichSubmission, richValue, value, voiceLifecycle]);

  const richMenusWithMentions = useMemo(
    () => [
      ...richMenus,
      mentionMenu(
        () => setAddFilesPresses((current) => current + 1),
        mentionRoutinesLoading,
        mentionRoutinesReady
      ),
    ],
    [mentionRoutinesLoading, mentionRoutinesReady]
  );

  return (
    <main className="min-h-screen bg-primary p-8 text-primary">
      <section className="mx-auto flex max-w-[760px] flex-col gap-6">
        <h1 className="text-lg font-semibold">AI Input E2E Fixture</h1>
        <div data-testid="primary-ai-input">
          <AiInput
            attachments={attachments.map((attachment) => ({
              ...attachment,
              name: attachment.name,
              // Pressing a failed tile puts it back into its upload.
              onRetry: () => {
                setAttachments((current) =>
                  current.map((item) =>
                    item.id === attachment.id
                      ? { ...item, state: "loading" as const }
                      : item
                  )
                );
              },
            }))}
            richText={new URLSearchParams(window.location.search).has("rich")}
            {...(new URLSearchParams(window.location.search).has("appClipboard")
              ? { clipboard: nativePlatformClipboard }
              : {})}
            disabled={primaryDisabled}
            onAttachPress={() => {}}
            onAttachmentRemove={(attachment) => {
              setAttachments((current) =>
                current.filter((item) => item.id !== attachment.id)
              );
            }}
            onDropFiles={() => {}}
            // Mirrors the composer: a paste carrying files becomes attachments
            // instead of prompt text.
            onPasteFiles={(clipboardData) => {
              // Use the application admission rule, not just a fixture count.
              if (
                Array.from(clipboardData.files).some(
                  (file) => !isAllowedAttachment(file.name)
                )
              )
                return;
              setAttachments((current) => [
                ...current,
                ...Array.from(clipboardData.files).map((file, index) => ({
                  id: `pasted-${current.length + index}`,
                  type: "file" as const,
                  name: file.name,
                })),
              ]);
            }}
            onValueChange={setValue}
            onVoiceCancel={() => {
              setVoiceLifecycle((current) => ({
                ...current,
                cancels: current.cancels + 1,
              }));
            }}
            onVoiceConfirm={() => {
              setVoiceLifecycle((current) => ({
                ...current,
                confirms: current.confirms + 1,
              }));
            }}
            onVoicePress={() => {
              setVoiceLifecycle((current) => ({
                ...current,
                presses: current.presses + 1,
              }));
            }}
            readOnly={primaryReadOnly}
            showVoiceButton={primaryShowVoiceButton}
            submitPending={primarySubmitPending}
            value={value}
          />
        </div>
        <div aria-live="polite" data-testid="attachment-count">
          Attachments: {attachments.length}
        </div>
        <div
          data-testid="narrow-ai-input-container"
          style={{ maxWidth: "100%", width: 320 }}
        >
          <AiInput
            aria-label="Rich AI prompt"
            disabled={richDisabled}
            menuRegistrations={richMenusWithMentions}
            onRichSubmit={setLastRichSubmission}
            onRichValueChange={setRichValue}
            richValue={richValue}
            sendLabel="Submit rich prompt"
            size="small"
          />
        </div>
        <AiInput
          aria-label="Async skills prompt"
          menuRegistrations={asyncMenus}
          onValueChange={setAsyncValue}
          richText
          value={asyncValue}
        />
        <AiInput
          aria-label="Over-limit rich prompt"
          maxLength={5}
          onValueChange={setOverLimitValue}
          richText
          value={overLimitValue}
        />
        <AiInput
          aria-label="Max-length plain prompt"
          clipboard={plainClipboard}
          maxLength={5}
          onValueChange={setPlainMaxLengthValue}
          value={plainMaxLengthValue}
        />
      </section>
    </main>
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <AiInputFixture />
  </StrictMode>
);
