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
      {children}
    </CommaUiThemeContext.Provider>
  );
}

export function useCommaUiThemeName(): CommaUiThemeName {
  return useContext(CommaUiThemeContext);
}
