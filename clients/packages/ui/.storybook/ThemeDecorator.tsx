import type { Decorator } from "@storybook/react-vite";
import type { ReactNode } from "react";
import { useEffect } from "react";

export type StorybookTheme = "light" | "dark";

const applyDocumentTheme = (theme: StorybookTheme) => {
  const root = document.documentElement;
  const isDark = theme === "dark";

  root.classList.toggle("dark", isDark);
  root.setAttribute("data-theme", isDark ? "Dark mode" : "Light mode");
};

export const ThemeDecorator: Decorator = (Story, { globals }) => {
  const theme = (globals.theme as StorybookTheme | undefined) ?? "light";

  useEffect(() => {
    applyDocumentTheme(theme);
    return () => {
      document.documentElement.classList.remove("dark");
      document.documentElement.setAttribute("data-theme", "Light mode");
    };
  }, [theme]);

  return (
    <main
      aria-label="Story preview"
      className={theme === "dark" ? "dark" : undefined}
      data-theme={theme === "dark" ? "Dark mode" : "Light mode"}
    >
      <Story />
    </main>
  );
};

export const themeToolbarItems = [
  { value: "light", title: "Light", icon: "sun" },
  { value: "dark", title: "Dark", icon: "moon" },
] as const;

export const ThemeDecoratorForTests = ({
  theme,
  children,
}: {
  theme: StorybookTheme;
  children: ReactNode;
}) => {
  useEffect(() => {
    applyDocumentTheme(theme);
  }, [theme]);

  return (
    <main
      className={theme === "dark" ? "dark" : undefined}
      data-theme={theme === "dark" ? "Dark mode" : "Light mode"}
    >
      {children}
    </main>
  );
};
