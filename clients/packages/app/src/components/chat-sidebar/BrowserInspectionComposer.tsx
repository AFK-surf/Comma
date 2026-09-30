import { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import { browserInspectionComposerConsolePrefix } from "@comma/native-bridge";
import { CrossLargeIcon } from "@comma/ui";
import { useCommaMessages } from "@comma/i18n/react";
import { Button as AriaButton } from "react-aria-components";
import { CommaAppearanceProvider } from "../commaAppearance";
import { Composer } from "../chat/composer/Composer";
import { fixedDraftSource } from "../chat/composer/conversationDraft";

type BrowserInspectionComposerMessage =
  | { height: number; type: "layout" }
  | { type: "cancel" }
  | { message: string; type: "submit" };

const browserInspectionDraftStorageKey = "comma-browser-inspection-composer-draft";

function emit(message: BrowserInspectionComposerMessage) {
  console.info(`${browserInspectionComposerConsolePrefix}${JSON.stringify(message)}`);
}

export function BrowserInspectionComposer() {
  const messages = useCommaMessages();
  const [draft, setDraftState] = useState(
    () => sessionStorage.getItem(browserInspectionDraftStorageKey) ?? ""
  );
  const draftSource = useMemo(() => fixedDraftSource(draft), [draft]);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const setDraft = useCallback((value: string) => {
    setDraftState(value);
    if (value) {
      sessionStorage.setItem(browserInspectionDraftStorageKey, value);
    } else {
      sessionStorage.removeItem(browserInspectionDraftStorageKey);
    }
  }, []);

  useLayoutEffect(() => {
    document.documentElement.dataset.commaWindowRole = "browser-inspection-composer";
    document.body.dataset.commaWindowRole = "browser-inspection-composer";
    const cancel = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setDraft("");
        emit({ type: "cancel" });
      }
    };
    const activate = (event: Event) => {
      const resetDraft =
        !(event instanceof CustomEvent) || event.detail?.resetDraft !== false;
      if (resetDraft) setDraft("");
      containerRef.current?.querySelector<HTMLElement>('[role="textbox"]')?.focus();
    };
    window.addEventListener("keydown", cancel);
    window.addEventListener("comma-browser-inspection-composer-activate", activate);
    return () => {
      window.removeEventListener("keydown", cancel);
      window.removeEventListener(
        "comma-browser-inspection-composer-activate",
        activate
      );
    };
  }, [setDraft]);

  useLayoutEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const report = () => {
      emit({
        height: Math.ceil(container.getBoundingClientRect().height),
        type: "layout",
      });
    };
    report();
    const observer = new ResizeObserver(report);
    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  return (
    <CommaAppearanceProvider>
      <div className="comma-browser-inspection-composer-surface" ref={containerRef}>
        <Composer
          draftSource={draftSource}
          onDraftChange={setDraft}
          onSend={(message) => {
            setDraft("");
            emit({ message, type: "submit" });
          }}
          placeholder="Ask about this element…"
          submitDisabled={false}
          toolbarLeading={
            <AriaButton
              aria-label={messages.common_close()}
              className="pointer-events-auto inline-flex size-[30px] shrink-0 items-center justify-center rounded-full bg-quaternary text-ai-input-panel-icon-primary outline-none transition-colors hover:bg-fg-senary focus-visible:shadow-focus-gray"
              onPress={() => {
                setDraft("");
                emit({ type: "cancel" });
              }}
            >
              <CrossLargeIcon className="size-4" />
            </AriaButton>
          }
          variant="side-chat"
        />
      </div>
    </CommaAppearanceProvider>
  );
}
