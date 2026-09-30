import {
  render as renderWithTestingLibrary,
  type RenderOptions,
  type RenderResult,
} from "@testing-library/react";
import type { ReactElement, ReactNode } from "react";
import { LocaleProvider } from "../src/i18n/locale";

export function render(
  ui: ReactElement,
  options?: Omit<RenderOptions, "wrapper">
): RenderResult {
  return renderWithTestingLibrary(ui, {
    ...options,
    wrapper: ({ children }: { children: ReactNode }) => (
      <LocaleProvider>{children}</LocaleProvider>
    ),
  });
}
