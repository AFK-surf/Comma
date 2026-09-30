// Tailwind config for the Salix admin dashboard (Linear-style minimalist).
// Content globs MUST include the dashboard .ex and .heex sources so utility
// classes used in HEEx are preserved.
const plugin = require("tailwindcss/plugin");

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/salix_web/dashboard/**/*.{ex,heex}",
    "../lib/salix_web/dashboard.ex",
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
        neutral: {
          50: "#f7f7f8",
          100: "#f1f1f2",
          200: "#e6e6e8",
          300: "#d3d3d6",
          400: "#a0a0a6",
          500: "#737378",
          600: "#52525a",
          700: "#3f3f46",
          800: "#27272a",
          900: "#18181b",
        },
      },
      fontFamily: {
        sans: ["Inter", "system-ui", "-apple-system", "Segoe UI", "sans-serif"],
      },
      borderRadius: {
        md: "0.375rem",
        lg: "0.5rem",
      },
      boxShadow: {
        subtle: "0 1px 2px 0 rgb(0 0 0 / 0.05)",
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
