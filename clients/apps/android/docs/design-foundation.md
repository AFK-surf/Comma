# Shared design tokens

Screens share `token_*` colors in `values/colors_tokens.xml` and `values-night/colors_tokens.xml`. Android selects the palette from the system theme. Eight-digit color values use **AARRGGBB**.

Status foregrounds map to `foreground.successPrimary` and `foreground.errorPrimary`. Attention has no semantic foreground entry. Its palette source is **Yellow/500** in light mode and **Yellow/400** in dark mode. Error foreground and error text are separate tokens.

Task labels use the `token_label_*` colors, with the same values in both themes. Call `DesignLabelColors.resolve(context, label.color)` to get an Android color integer. Lowercase preset names resolve through these resources. Six-digit `#rrggbb` values keep their RGB with full opacity. Null, empty, unknown or malformed values resolve to the gray label token. Short hex and hex with alpha are not accepted.

The only bundled Inter file is `res/font/inter_variable.ttf`, with its OFL license in `assets/licenses/Inter-OFL.txt`. Get a cached typeface with `DesignFonts.inter(context)`, or pass a weight from 100 to 900.

Use `DesignTypography.applyTo(view, DesignTypography.Level.REGULAR)` to apply the shared font, size, line height and letter spacing. `DesignTypography.size(level)` also supports custom text layout. All sizes and line heights are in sp. `DesignTypography.promoteOneStep` moves the whole scale up one level. Set it before you bind screens, and reapply typography to existing views after you change it. Use `size(level, promote = false)` for the unshifted size.

Use `DesignMotion` for millisecond durations and `PathInterpolator` curves. For example, set the duration of an animator to `DesignMotion.durationMillis(DesignMotion.stateChange)` and its interpolator to `DesignMotion.softInOut`. Resolve durations and `pressScale()` when feedback starts, so the system setting that disables animations takes effect. Stream text reveals use opacity, without spring motion.

Use springs for translation, scale, rotation and size. `DesignMotion` provides the spring tokens as stiffness and damping ratio. The `createForce(finalPosition)` of each token returns a new mutable `SpringForce`. Durations and curves stay available for opacity, color and streaming text.

Keep one `DesignSpring(target, property, token)` per animated property and call `animateTo(finalPosition)` on the main thread. It uses `SpringAnimation.animateToFinalPosition` to keep motion when the target changes. For a gesture handoff, pass `initialVelocity` in property units per second (px/s for translation). Omit it for ordinary retargets. When the system disables animations, it cancels motion and writes the endpoint synchronously. Call `cancel()` before you drag or detach the view. Custom fractional properties can set `minimumVisibleChange`, for example `0.001f` for progress. Values are not clamped to 0 to 1.

Launcher icons are flavor resources: dev has an orange gradient, staging a blue gradient, and prod a white background with a black mark. Each flavor has regular and round adaptive icons plus a monochrome layer. The 20×20 source vector maps to the centered 66dp region of a 108dp layer. Backgrounds are full-bleed, without an embedded mask or bitmap border.

To render the six launcher previews, install Pillow and CairoSVG in a local environment and run `python scripts/render-launcher-icons.py --output <preview-directory>`.
