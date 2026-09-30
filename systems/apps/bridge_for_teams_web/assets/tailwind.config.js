// Tailwind config for the BridgeForTeams dashboard (Linear-style minimalist).
// Content globs MUST include the dashboard .ex and .heex sources so utility
// classes used in HEEx are preserved.
const plugin = require("tailwindcss/plugin");

module.exports = {
  content: [
    "./js/**/*.js",
    "../../salix_web/lib/salix_web/dashboard/live/account_pool_live.ex",
    "../../salix_web/lib/salix_web/dashboard/components/core_components.ex",
    "../lib/bridge_for_teams_web/dashboard/**/*.{ex,heex}",
    "../lib/bridge_for_teams_web/dashboard.ex",
  ],
  theme: {
    extend: {
      colors: {
        // Brand blue accent (#205BFF).
        brand: {
          50: "#f4f7ff",
          100: "#e4ebff",
          200: "#c7d6ff",
          300: "#9bb5ff",
          400: "#5e89ff",
          500: "#205bff",
          600: "#1c4fde",
          700: "#1742b8",
          800: "#133594",
          900: "#0f2a75",
        },
        // Linear-app lch neutral ramp (constant cool hue anchor ~282):
        // whisper-quiet chrome, 4 text tiers, hairline borders.
        neutral: {
          50: "#fcfcfd", // bg-primary (content canvas)
          100: "#f5f5f6", // shell / sidebar gray
          200: "#eeeef0", // bg-secondary / border-primary
          300: "#dcdcde", // border-secondary
          350: "#d2d3d7", // border-tertiary
          400: "#a8acb8", // text-quaternary
          500: "#82858e", // between quaternary and tertiary
          600: "#5c5e66", // text-tertiary
          700: "#44464d",
          800: "#2e3035", // text-secondary
          900: "#17181a", // text-primary
        },
      },
      fontFamily: {
        sans: [
          "Inter Variable",
          "Inter",
          "SF Pro Display",
          "-apple-system",
          "system-ui",
          "Segoe UI",
          "sans-serif",
        ],
      },
      // Intermediate weights à la Linear (450/500/600 — never 400/700).
      fontWeight: {
        book: "450",
      },
      borderRadius: {
        md: "0.375rem",
        lg: "0.5rem",
      },
      boxShadow: {
        // Micro layered shadows, single top light source, neutral tint.
        subtle:
          "0px 1px 1px rgba(23, 24, 26, 0.04), 0px 3px 6px -2px rgba(23, 24, 26, 0.02)",
        // The raised center work surface above the gray chrome.
        raised:
          "0 0 0 0.5px rgba(23, 24, 26, 0.07), 0 1px 2px rgba(23, 24, 26, 0.03), 0 12px 32px -16px rgba(23, 24, 26, 0.08)",
        popover:
          "0 0 0 0.5px rgba(23, 24, 26, 0.08), 0 4px 12px rgba(23, 24, 26, 0.08)",
      },
    },
  },
  plugins: [
    plugin(({ addVariant }) => {
      addVariant("phx-click-loading", [
        ".phx-click-loading&",
        ".phx-click-loading &",
      ]);
      addVariant("phx-submit-loading", [
        ".phx-submit-loading&",
        ".phx-submit-loading &",
      ]);
      addVariant("phx-change-loading", [
        ".phx-change-loading&",
        ".phx-change-loading &",
      ]);
    }),
  ],
};
