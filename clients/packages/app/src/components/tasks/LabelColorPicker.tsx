import { useCommaMessages } from "@comma/i18n/react";
import { Button, MenuPopover, menuSurfaceClasses } from "@comma/ui";
import { useEffect, useState } from "react";
import {
  ColorArea,
  ColorField,
  ColorPicker,
  ColorSlider,
  ColorThumb,
  Dialog as AriaDialog,
  DialogTrigger,
  Input,
  Radio,
  RadioGroup,
  SliderTrack,
  parseColor,
  type Color,
} from "react-aria-components";
import { isCustomLabelColor, LABEL_PRESET_COLORS, LabelDot } from "./labelColor";

type EyeDropperApi = { open(): Promise<{ sRGBHex: string }> };
type EyeDropperWindow = Window & { EyeDropper?: new () => EyeDropperApi };

const CUSTOM_SEED = "#6172f3";

function CheckGlyph() {
  return (
    <svg aria-hidden fill="none" viewBox="0 0 16 16">
      <path
        d="M3.5 8.5l3 3 6-7"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="2"
      />
    </svg>
  );
}

function EyedropperGlyph() {
  return (
    <svg aria-hidden fill="none" viewBox="0 0 20 20">
      <path
        d="M12.5 4.5l3 3M10.5 6.5l3 3-6.25 6.25a1.5 1.5 0 0 1-1.06.44H4.5v-1.69c0-.4.16-.78.44-1.06L10.5 6.5zM12 5l2-2a1.41 1.41 0 0 1 2 2l-2 2"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="1.5"
      />
    </svg>
  );
}

/**
 * Label colour: a row of preset swatches, plus a custom picker (saturation /
 * brightness area, hue slider, eyedropper where the platform has one, hex
 * field). Presets commit on click; the custom picker commits when a drag ends
 * or a hex value is entered, so a drag does not stream writes.
 */
export function LabelColorPicker({
  color,
  disabled,
  label,
  onChange,
}: {
  color: string;
  disabled: boolean;
  label: string;
  onChange: (color: string) => void;
}) {
  const messages = useCommaMessages();
  const custom = isCustomLabelColor(color);
  const [customOpen, setCustomOpen] = useState(custom);
  const [draft, setDraft] = useState<Color>(() =>
    parseColor(custom ? color : CUSTOM_SEED).toFormat("hsb")
  );
  useEffect(() => {
    if (custom) setDraft(parseColor(color).toFormat("hsb"));
  }, [color, custom]);
  const eyeDropper = (window as EyeDropperWindow).EyeDropper;

  const commit = (next: Color) => {
    onChange(next.toString("hex").toLowerCase());
  };
  const pickFromScreen = async () => {
    if (!eyeDropper) return;
    try {
      const picked = parseColor((await new eyeDropper().open()).sRGBHex).toFormat(
        "hsb"
      );
      setDraft(picked);
      commit(picked);
    } catch {
      // The person dismissed the eyedropper; nothing to change.
    }
  };

  return (
    <DialogTrigger
      onOpenChange={(open) => {
        if (!open) setCustomOpen(custom);
      }}
    >
      <Button
        aria-label={label}
        hierarchy="tertiary-gray"
        iconLeading={<LabelDot className="size-2.5" color={color} />}
        iconOnly
        isDisabled={disabled}
        size="sm"
      />
      <MenuPopover
        className={`${menuSurfaceClasses} comma-label-picker`}
        placement="bottom start"
      >
        <AriaDialog
          aria-label={label}
          className="outline-none"
          data-testid="label-color-picker"
        >
          <RadioGroup
            aria-label={label}
            className="comma-label-picker-presets"
            onChange={(next) => {
              if (next === "custom") {
                setCustomOpen(true);
                return;
              }
              setCustomOpen(false);
              onChange(next);
            }}
            orientation="horizontal"
            value={custom ? "custom" : color}
          >
            {LABEL_PRESET_COLORS.map((preset) => (
              <Radio
                aria-label={preset}
                className="comma-label-swatch"
                data-color={preset}
                key={preset}
                value={preset}
              >
                {color === preset ? <CheckGlyph /> : null}
              </Radio>
            ))}
            <span aria-hidden className="comma-label-picker-divider" />
            <Radio
              aria-label={messages.settings_labels_custom_color()}
              className="comma-label-swatch comma-label-swatch-custom"
              data-testid="label-color-custom"
              {...(custom ? { style: { backgroundColor: color } } : {})}
              value="custom"
            >
              {custom ? <CheckGlyph /> : null}
            </Radio>
          </RadioGroup>
          {customOpen ? (
            <ColorPicker onChange={setDraft} value={draft}>
              <div
                className="comma-label-picker-custom"
                data-testid="label-color-custom-panel"
              >
                <ColorArea
                  className="comma-label-area"
                  colorSpace="hsb"
                  onChangeEnd={commit}
                  xChannel="saturation"
                  yChannel="brightness"
                >
                  <ColorThumb className="comma-label-thumb" />
                </ColorArea>
                <div className="comma-label-picker-row">
                  {eyeDropper ? (
                    <button
                      aria-label={messages.settings_labels_eyedropper()}
                      className="comma-label-eyedropper"
                      onClick={() => void pickFromScreen()}
                      type="button"
                    >
                      <EyedropperGlyph />
                    </button>
                  ) : null}
                  <ColorSlider
                    aria-label={messages.settings_labels_custom_color()}
                    channel="hue"
                    className="comma-label-hue"
                    onChangeEnd={commit}
                  >
                    <SliderTrack
                      className="comma-label-hue-track"
                      style={({ defaultStyle }) => defaultStyle}
                    >
                      <ColorThumb className="comma-label-thumb" />
                    </SliderTrack>
                  </ColorSlider>
                  <span
                    aria-hidden
                    className="comma-label-hex-swatch"
                    style={{ backgroundColor: draft.toString("hex") }}
                  />
                  <ColorField
                    aria-label={messages.settings_labels_hex()}
                    className="comma-label-hex"
                    onChange={(next) => {
                      if (!next) return;
                      const parsed = next.toFormat("hsb");
                      setDraft(parsed);
                      commit(parsed);
                    }}
                  >
                    <Input
                      className="comma-label-hex-input"
                      data-testid="label-color-hex"
                    />
                  </ColorField>
                </div>
              </div>
            </ColorPicker>
          ) : null}
        </AriaDialog>
      </MenuPopover>
    </DialogTrigger>
  );
}
