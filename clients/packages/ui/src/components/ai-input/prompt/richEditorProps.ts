import type { HTMLAttributes } from "react";
import type { AiInputNativeAttributes } from "../types";

/**
 * Preserve the attributes shared by textarea and contenteditable while avoiding
 * textarea-only attributes on the rich editor's div.
 */
export const getRichEditorProps = ({
  autoComplete: _autoComplete,
  cols: _cols,
  dirName: _dirName,
  disabled: _disabled,
  form: _form,
  maxLength: _maxLength,
  minLength: _minLength,
  name: _name,
  placeholder: _placeholder,
  readOnly: _readOnly,
  required: _required,
  rows: _rows,
  wrap: _wrap,
  ...sharedProps
}: AiInputNativeAttributes): HTMLAttributes<HTMLDivElement> => sharedProps;
