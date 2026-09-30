import type { HTMLAttributes } from "react";
import type { AiInputMenuRegistration, AiInputRichValue } from "../richText";

export interface AiInputRichEditorProps {
  value: string;
  richValue?: AiInputRichValue | undefined;
  richValueFromText?: ((text: string) => AiInputRichValue) | undefined;
  registrations: readonly AiInputMenuRegistration[];
  ariaLabel: string;
  clipboard: {
    readText(): Promise<string>;
    writeText(text: string): Promise<void>;
  };
  onPasteFilesFromMenu?: (() => Promise<boolean>) | undefined;
  placeholder: string;
  className?: string | undefined;
  disabled?: boolean | undefined;
  readOnly?: boolean | undefined;
  required?: boolean | undefined;
  maxLength?: number | undefined;
  editorProps?: HTMLAttributes<HTMLDivElement> | undefined;
  spellCheck?: HTMLAttributes<HTMLDivElement>["spellCheck"] | undefined;
  minHeight: number;
  maxHeight: number;
  onEditorChange: (value: AiInputRichValue, element: HTMLDivElement) => void;
  onEditorLayoutChange: (element: HTMLDivElement) => void;
  onSubmitRequest: () => void;
}
