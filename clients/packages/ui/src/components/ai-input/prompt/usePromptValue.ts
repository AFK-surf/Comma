import { useCallback, useLayoutEffect, useRef, type ChangeEvent } from "react";
import { createPlainAiInputRichValue, type AiInputRichValue } from "../richText";
import type { useAiInputAutoSize } from "../sizing/useAiInputAutoSize";
import type { AiInputAttachment, ForwardedAiInputProps } from "../types";

export interface PromptValueOptions extends ForwardedAiInputProps<
  | "onChange"
  | "onRichSubmit"
  | "onRichValueChange"
  | "onSubmit"
  | "onValueChange"
  | "richValue"
  | "richValueFromText"
  | "value"
> {
  attachments: AiInputAttachment[];
  /** What the prompt shows: the rich value's text, the controlled value, or the draft. */
  currentValue: string;
  disabled: boolean;
  setDraftValue: (value: string) => void;
  sizing: Pick<
    ReturnType<typeof useAiInputAutoSize>,
    "measureEdit" | "measureNow" | "requestMeasure"
  >;
  submitDisabled: boolean;
  submitPending: boolean;
  usesRichText: boolean;
}

export type PromptValue = ReturnType<typeof usePromptValue>;

const hasPromptValue = (value: string, attachments: AiInputAttachment[]) =>
  value.trim().length > 0 || attachments.length > 0;

/**
 * The prompt's value on its way out: whether there is something to send,
 * each edit reaching the host (and the draft, when uncontrolled) with the
 * measurement it needs, and submit sending the structured value the prompt
 * last produced.
 */
export function usePromptValue({
  attachments,
  currentValue,
  disabled,
  onChange,
  onRichSubmit,
  onRichValueChange,
  onSubmit,
  onValueChange,
  richValue,
  richValueFromText,
  setDraftValue,
  sizing: { measureEdit, measureNow, requestMeasure },
  submitDisabled,
  submitPending,
  usesRichText,
  value,
}: PromptValueOptions) {
  const toRichValue = richValueFromText ?? createPlainAiInputRichValue;
  const filled = hasPromptValue(currentValue, attachments);
  const canSubmit = !disabled && !submitDisabled && !submitPending && filled;
  const currentRichValueRef = useRef<AiInputRichValue>(
    richValue ?? toRichValue(currentValue)
  );
  // The last value the prompt itself produced; it already asked for a read.
  const lastEditorValueRef = useRef<string | null>(null);

  useLayoutEffect(() => {
    if (richValue !== undefined) {
      currentRichValueRef.current = richValue;
      return;
    }

    if (currentRichValueRef.current.plainText !== currentValue) {
      currentRichValueRef.current = toRichValue(currentValue);
    }
  }, [currentValue, richValue, toRichValue]);

  const handleChange = (event: ChangeEvent<HTMLTextAreaElement>) => {
    if (value === undefined) setDraftValue(event.currentTarget.value);
    onChange?.(event);
    onValueChange?.(event.currentTarget.value);
    lastEditorValueRef.current = event.currentTarget.value;
    measureEdit();
  };

  // A value written from outside (such as a restored draft) is measured
  // before it paints, so motion that follows sees it settled.
  // The prompt's own edits were already measured, or asked for a read.
  useLayoutEffect(() => {
    if (currentValue === lastEditorValueRef.current) return;
    lastEditorValueRef.current = currentValue;
    measureNow();
  }, [currentValue, measureNow]);
  useLayoutEffect(measureNow, [attachments.length, measureNow]);
  useLayoutEffect(() => {
    requestMeasure();
  }, [richValue, requestMeasure]);

  const handleSubmit = useCallback(() => {
    if (!canSubmit) return;
    const submittedValue =
      usesRichText && richValue !== undefined
        ? richValue
        : usesRichText && currentRichValueRef.current.plainText === currentValue
          ? currentRichValueRef.current
          : toRichValue(currentValue);
    onSubmit?.(submittedValue.plainText);
    onRichSubmit?.(submittedValue);
  }, [
    canSubmit,
    currentValue,
    onRichSubmit,
    onSubmit,
    richValue,
    toRichValue,
    usesRichText,
  ]);

  const handleEditorChange = (nextRichValue: AiInputRichValue) => {
    currentRichValueRef.current = nextRichValue;
    if (value === undefined && richValue === undefined) {
      setDraftValue(nextRichValue.plainText);
    }
    onValueChange?.(nextRichValue.plainText);
    onRichValueChange?.(nextRichValue);
    lastEditorValueRef.current = nextRichValue.plainText;
    measureEdit();
  };

  return { canSubmit, filled, handleChange, handleEditorChange, handleSubmit };
}
