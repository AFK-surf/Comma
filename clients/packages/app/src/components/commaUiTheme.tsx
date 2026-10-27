import { MarkdownStreamDarkContext } from "@comma/ui/components/markdown-stream";
import { createContext, useContext, type ReactNode } from "react";

export type CommaUiThemeName = "Light mode" | "Dark mode";

const CommaUiThemeContext = createContext<CommaUiThemeName>("Light mode");

export function CommaUiThemeProvider({
  children,
  theme,
}: {
  children: ReactNode;
  theme: CommaUiThemeName;
}) {
  return (
    <CommaUiThemeContext.Provider value={theme}>
      <MarkdownStreamDarkContext.Provider value={theme === "Dark mode"}>
        {children}
      </MarkdownStreamDarkContext.Provider>
    </CommaUiThemeContext.Provider>
  );
}

export function useCommaUiThemeName(): CommaUiThemeName {
  return useContext(CommaUiThemeContext);
}
