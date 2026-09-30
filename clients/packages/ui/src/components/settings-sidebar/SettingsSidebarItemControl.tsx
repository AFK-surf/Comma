import type { ReactNode } from "react";
import { Button as AriaButton, Focusable } from "react-aria-components";
import { cx, definedProps } from "../utils";

export interface SettingsSidebarItem {
  id: string;
  label: string;
  ariaLabel?: string;
  icon?: ReactNode;
  href?: string;
  className?: string;
  selected?: boolean;
  disabled?: boolean;
  shortcut?: ReactNode;
  trailing?: ReactNode;
  onPress?: () => void;
}

const settingsSidebarItemClassName = (item: SettingsSidebarItem) =>
  cx(
    "flex h-7 min-h-7 w-full max-w-[270px] items-center gap-sm overflow-hidden rounded-lg border-0 bg-transparent px-md py-none text-sm leading-5 tracking-[-0.14px] no-underline outline-none transition-colors duration-[50ms] focus-visible:shadow-focus-gray",
    item.selected
      ? "bg-sidebar-bg-item text-sidebar-text-highlight"
      : "text-sidebar-text-secondary hover:bg-sidebar-bg-item hover:text-sidebar-text-highlight",
    item.disabled && "cursor-not-allowed text-sidebar-icon-disabled",
    item.className
  );

const SidebarItemContent = ({ item }: { item: SettingsSidebarItem }) => (
  <>
    <span
      className={cx(
        "shrink-0 text-sidebar-icon-primary",
        item.disabled && "text-sidebar-icon-disabled"
      )}
    >
      {item.icon}
    </span>
    <span className="min-w-0 flex-1 truncate text-left">{item.label}</span>
    {item.shortcut ? (
      <span className="flex shrink-0 items-center gap-xxs text-sm leading-5 tracking-[-0.14px]">
        {item.shortcut}
      </span>
    ) : null}
    {item.trailing ? <span className="shrink-0">{item.trailing}</span> : null}
  </>
);

/** One category row of the settings rail: a link when it has an href, a button otherwise. */
export const SettingsSidebarItemControl = ({ item }: { item: SettingsSidebarItem }) => {
  const className = settingsSidebarItemClassName(item);
  const stateProps = {
    "data-selected": item.selected ? "true" : "false",
    "data-slot": "settings-sidebar-item",
  } as const;

  if (item.href) {
    return (
      <Focusable {...(item.disabled ? { isDisabled: true } : {})}>
        <a
          {...(item.ariaLabel ? { "aria-label": item.ariaLabel } : {})}
          aria-current={item.selected ? "page" : undefined}
          aria-disabled={item.disabled ? "true" : undefined}
          className={className}
          href={item.disabled ? undefined : item.href}
          onClick={(event) => {
            if (item.disabled) {
              event.preventDefault();
              return;
            }
            item.onPress?.();
          }}
          {...stateProps}
        >
          <SidebarItemContent item={item} />
        </a>
      </Focusable>
    );
  }

  return (
    <AriaButton
      {...(item.ariaLabel ? { "aria-label": item.ariaLabel } : {})}
      {...definedProps({ onPress: item.onPress, isDisabled: item.disabled })}
      {...(item.selected ? { "aria-current": "page" as const } : {})}
      className={className}
      {...stateProps}
    >
      <SidebarItemContent item={item} />
    </AriaButton>
  );
};
