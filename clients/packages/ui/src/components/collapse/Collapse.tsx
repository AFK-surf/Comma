import * as Collapsible from "@radix-ui/react-collapsible";
import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ComponentPropsWithoutRef,
  type ReactNode,
} from "react";
import { cx, definedProps } from "../utils";

const CollapseSkipEnterContext = createContext(false);

const resolveInitialOpen = (open?: boolean, defaultOpen?: boolean) =>
  open ?? defaultOpen ?? false;

export type CollapseProps = {
  open?: boolean;
  defaultOpen?: boolean;
  onOpenChange?: (open: boolean) => void;
  children: ReactNode;
  className?: string;
};

export type CollapseContentProps = ComponentPropsWithoutRef<
  typeof Collapsible.Content
> & {
  /** Styles the height container only — avoid padding here. */
  containerClassName?: string;
};

export const Collapse = ({
  open,
  defaultOpen,
  onOpenChange,
  children,
  className,
}: CollapseProps) => {
  const [skipEnterAnimation, setSkipEnterAnimation] = useState(() =>
    resolveInitialOpen(open, defaultOpen)
  );

  useEffect(() => {
    if (open === false) {
      setSkipEnterAnimation(false);
    }
  }, [open]);

  const handleOpenChange = (next: boolean) => {
    if (!next) {
      setSkipEnterAnimation(false);
    }
    onOpenChange?.(next);
  };

  return (
    <CollapseSkipEnterContext.Provider value={skipEnterAnimation}>
      <Collapsible.Root
        {...definedProps({ open, defaultOpen })}
        onOpenChange={handleOpenChange}
        className={className}
      >
        {children}
      </Collapsible.Root>
    </CollapseSkipEnterContext.Provider>
  );
};

export const CollapseContent = ({
  className,
  containerClassName,
  children,
  ...props
}: CollapseContentProps) => {
  const skipEnterAnimation = useContext(CollapseSkipEnterContext);

  return (
    <Collapsible.Content
      className={cx("collapse-container", containerClassName)}
      data-skip-enter={skipEnterAnimation ? "" : undefined}
      {...props}
    >
      <div className="collapse-content-wrapper">
        <div className={cx("collapse-content", className)}>{children}</div>
      </div>
    </Collapsible.Content>
  );
};
