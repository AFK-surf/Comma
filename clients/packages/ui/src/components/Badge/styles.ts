export type BadgeColor =
  | "gray"
  | "brand"
  | "error"
  | "warning"
  | "success"
  | "blue"
  | "indigo"
  | "purple"
  | "pink"
  | "orange";

export type BadgeSize = "sm" | "md" | "lg";
export type BadgeType = "pill-color" | "pill-outline" | "badge-color" | "badge-modern";

const utilityPillColor = (color: BadgeColor) =>
  `bg-utility-${color}-50 text-utility-${color}-700 border-utility-${color}-200`;

const utilityPillOutline = (color: BadgeColor) =>
  `bg-primary text-utility-${color}-700 border-utility-${color}-300`;

export const pillColorClasses: Record<BadgeColor, string> = {
  gray: utilityPillColor("gray"),
  brand: utilityPillColor("brand"),
  error: utilityPillColor("error"),
  warning: utilityPillColor("warning"),
  success: utilityPillColor("success"),
  blue: utilityPillColor("blue"),
  indigo: utilityPillColor("indigo"),
  purple: utilityPillColor("purple"),
  pink: utilityPillColor("pink"),
  orange: utilityPillColor("orange"),
};

export const pillOutlineClasses: Record<BadgeColor, string> = {
  gray: "bg-primary text-utility-gray-700 border-primary",
  brand: utilityPillOutline("brand"),
  error: utilityPillOutline("error"),
  warning: utilityPillOutline("warning"),
  success: utilityPillOutline("success"),
  blue: utilityPillOutline("blue"),
  indigo: utilityPillOutline("indigo"),
  purple: utilityPillOutline("purple"),
  pink: utilityPillOutline("pink"),
  orange: utilityPillOutline("orange"),
};

export const badgeColorClasses: Record<BadgeColor, string> = {
  gray: `${utilityPillColor("gray")} rounded-md`,
  brand: `${utilityPillColor("brand")} rounded-md`,
  error: `${utilityPillColor("error")} rounded-md`,
  warning: `${utilityPillColor("warning")} rounded-md`,
  success: `${utilityPillColor("success")} rounded-md`,
  blue: `${utilityPillColor("blue")} rounded-md`,
  indigo: `${utilityPillColor("indigo")} rounded-md`,
  purple: `${utilityPillColor("purple")} rounded-md`,
  pink: `${utilityPillColor("pink")} rounded-md`,
  orange: `${utilityPillColor("orange")} rounded-md`,
};

export const badgeModernClasses: Record<BadgeColor, string> = {
  gray: "bg-primary text-utility-gray-700 border-primary shadow-xs rounded-md",
  brand: `${utilityPillOutline("brand")} shadow-xs rounded-md`,
  error: `${utilityPillOutline("error")} shadow-xs rounded-md`,
  warning: `${utilityPillOutline("warning")} shadow-xs rounded-md`,
  success: `${utilityPillOutline("success")} shadow-xs rounded-md`,
  blue: `${utilityPillOutline("blue")} shadow-xs rounded-md`,
  indigo: `${utilityPillOutline("indigo")} shadow-xs rounded-md`,
  purple: `${utilityPillOutline("purple")} shadow-xs rounded-md`,
  pink: `${utilityPillOutline("pink")} shadow-xs rounded-md`,
  orange: `${utilityPillOutline("orange")} shadow-xs rounded-md`,
};

export const sizeClasses: Record<BadgeSize, string> = {
  sm: "px-2 py-0.5 text-xs",
  md: "px-2.5 py-0.5 text-sm",
  lg: "px-3 py-1 text-sm",
};

export const badgeDotColorClasses: Record<BadgeColor, string> = {
  gray: "bg-utility-gray-700",
  brand: "bg-utility-brand-700",
  error: "bg-utility-error-700",
  warning: "bg-utility-warning-700",
  success: "bg-utility-success-700",
  blue: "bg-utility-blue-700",
  indigo: "bg-utility-indigo-700",
  purple: "bg-utility-purple-700",
  pink: "bg-utility-pink-700",
  orange: "bg-utility-orange-700",
};

export const typeClasses: Record<BadgeType, (color: BadgeColor) => string> = {
  "pill-color": (c) => `rounded-full border ${pillColorClasses[c]}`,
  "pill-outline": (c) => `rounded-full border ${pillOutlineClasses[c]}`,
  "badge-color": (c) => `border ${badgeColorClasses[c]}`,
  "badge-modern": (c) => `border ${badgeModernClasses[c]}`,
};
