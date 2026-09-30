import { render, screen } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { Text } from "../Text";

const compactAliases = [
  { size: "micro", className: "text-micro" },
  { size: "mini", className: "text-mini" },
  { size: "small", className: "text-small" },
  { size: "regular", className: "text-regular" },
  { size: "large", className: "text-large" },
  { size: "title3", className: "text-title-3" },
  { size: "title2", className: "text-title-2" },
  { size: "title1", className: "text-title-1" },
] as const;

describe("Text", () => {
  it.each(compactAliases)(
    "preserves the $size alias alongside semantic color classes",
    ({ size, className }) => {
      render(
        <Text data-testid={`text-${size}`} size={size} className="text-primary">
          Sample
        </Text>
      );

      expect(screen.getByTestId(`text-${size}`)).toHaveClass(
        className,
        "text-primary",
        "font-regular"
      );
    }
  );
});
