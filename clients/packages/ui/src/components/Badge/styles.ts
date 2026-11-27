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

export type BadgeSize = "xs" | "sm" | "md" | "lg";
export type BadgeType = "pill-color" | "pill-outline" | "badge-color" | "badge-modern";

export const pillColorClasses: Record<BadgeColor, string> = {
  gray: "bg-[color:var(--comma-badge-gray-bg)] text-secondary",
  brand:
    "bg-[color:var(--comma-badge-brand-bg)] text-[color:var(--comma-badge-brand-fg)]",
  error: "bg-[color:var(--comma-badge-error-bg)] text-utility-error-700",
  warning: "bg-[color:var(--comma-badge-warning-bg)] text-utility-warning-700",
  success: "bg-[color:var(--comma-badge-success-bg)] text-utility-success-700",
  blue: "bg-[color:var(--comma-badge-blue-bg)] text-utility-blue-700",
  indigo: "bg-[color:var(--comma-badge-indigo-bg)] text-utility-indigo-700",
  purple: "bg-[color:var(--comma-badge-purple-bg)] text-utility-purple-700",
  pink: "bg-[color:var(--comma-badge-pink-bg)] text-utility-pink-700",
  orange: "bg-[color:var(--comma-badge-orange-bg)] text-utility-orange-700",
};

export const pillOutlineClasses: Record<BadgeColor, string> = {
  gray: "bg-primary text-secondary border-primary",
  brand:
    "bg-primary text-[color:var(--comma-badge-brand-fg)] border-[color:var(--comma-badge-brand-border)]",
  error:
    "bg-primary text-utility-error-700 border-[color:color-mix(in_srgb,var(--color-utility-error-700)_22%,var(--color-border-primary))]",
  warning:
    "bg-primary text-utility-warning-700 border-[color:color-mix(in_srgb,var(--color-utility-warning-700)_22%,var(--color-border-primary))]",
  success:
    "bg-primary text-utility-success-700 border-[color:color-mix(in_srgb,var(--color-utility-success-700)_22%,var(--color-border-primary))]",
  blue: "bg-primary text-utility-blue-700 border-[color:color-mix(in_srgb,var(--color-utility-blue-700)_22%,var(--color-border-primary))]",
  indigo:
    "bg-primary text-utility-indigo-700 border-[color:color-mix(in_srgb,var(--color-utility-indigo-700)_22%,var(--color-border-primary))]",
  purple:
    "bg-primary text-utility-purple-700 border-[color:color-mix(in_srgb,var(--color-utility-purple-700)_22%,var(--color-border-primary))]",
  pink: "bg-primary text-utility-pink-700 border-[color:color-mix(in_srgb,var(--color-utility-pink-700)_22%,var(--color-border-primary))]",
  orange:
    "bg-primary text-utility-orange-700 border-[color:color-mix(in_srgb,var(--color-utility-orange-700)_22%,var(--color-border-primary))]",
};

export const badgeColorClasses: Record<BadgeColor, string> = {
  gray: `${pillColorClasses.gray} rounded-[5px]`,
  brand: `${pillColorClasses.brand} rounded-[5px]`,
  error: `${pillColorClasses.error} rounded-[5px]`,
  warning: `${pillColorClasses.warning} rounded-[5px]`,
  success: `${pillColorClasses.success} rounded-[5px]`,
  blue: `${pillColorClasses.blue} rounded-[5px]`,
  indigo: `${pillColorClasses.indigo} rounded-[5px]`,
  purple: `${pillColorClasses.purple} rounded-[5px]`,
  pink: `${pillColorClasses.pink} rounded-[5px]`,
  orange: `${pillColorClasses.orange} rounded-[5px]`,
};

export const badgeModernClasses: Record<BadgeColor, string> = {
  gray: `${pillOutlineClasses.gray} shadow-xs rounded-[5px]`,
  brand: `${pillOutlineClasses.brand} shadow-xs rounded-[5px]`,
  error: `${pillOutlineClasses.error} shadow-xs rounded-[5px]`,
  warning: `${pillOutlineClasses.warning} shadow-xs rounded-[5px]`,
  success: `${pillOutlineClasses.success} shadow-xs rounded-[5px]`,
  blue: `${pillOutlineClasses.blue} shadow-xs rounded-[5px]`,
  indigo: `${pillOutlineClasses.indigo} shadow-xs rounded-[5px]`,
  purple: `${pillOutlineClasses.purple} shadow-xs rounded-[5px]`,
  pink: `${pillOutlineClasses.pink} shadow-xs rounded-[5px]`,
  orange: `${pillOutlineClasses.orange} shadow-xs rounded-[5px]`,
};

export const sizeClasses: Record<BadgeSize, string> = {
  xs: "px-1.5 py-px text-micro leading-4 tracking-[0.005em]",
  sm: "px-2 py-0.5 text-xs leading-4",
  md: "px-2.5 py-0.5 text-xs leading-[18px]",
  lg: "px-3 py-1 text-sm leading-5",
};

export const badgeDotColorClasses: Record<BadgeColor, string> = {
  gray: "bg-utility-gray-700",
  brand: "bg-[color:var(--comma-badge-brand-fg)]",
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
  "pill-color": (c) => `rounded-full ${pillColorClasses[c]}`,
  "pill-outline": (c) => `rounded-full border ${pillOutlineClasses[c]}`,
  "badge-color": (c) => badgeColorClasses[c],
  "badge-modern": (c) => `border ${badgeModernClasses[c]}`,
};
