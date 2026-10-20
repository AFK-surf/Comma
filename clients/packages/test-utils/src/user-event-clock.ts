import { userEvent } from "@testing-library/user-event";
import { vi } from "vitest";

type SetupOptions = NonNullable<Parameters<typeof userEvent.setup>[0]>;

/**
 * user-event waits `delay` milliseconds between steps with `setTimeout`, and
 * calls `advanceTimers` to move a fake clock past that wait. Its default does
 * not, so on the fake clock every interaction would wait forever. Each
 * user-event call here moves the test clock instead; options a test passes
 * still win.
 */
export function stepUserEventOnTestClock() {
  const patched = userEvent as typeof userEvent & { commaTestClock?: true };
  if (patched.commaTestClock) return;
  patched.commaTestClock = true;
  const original = { ...userEvent };
  const withClock = <T extends object | undefined>(options?: T) =>
    ({
      advanceTimers: (ms: number) => {
        if (vi.isFakeTimers()) vi.advanceTimersByTime(ms);
      },
      ...options,
    }) as SetupOptions & T;
  Object.assign(userEvent, {
    setup: (options?: SetupOptions) => original.setup(withClock(options)),
    click: (element: Element, options?: SetupOptions) =>
      original.click(element, withClock(options)),
    dblClick: (element: Element, options?: SetupOptions) =>
      original.dblClick(element, withClock(options)),
    tripleClick: (element: Element, options?: SetupOptions) =>
      original.tripleClick(element, withClock(options)),
    hover: (element: Element, options?: SetupOptions) =>
      original.hover(element, withClock(options)),
    unhover: (element: Element, options?: SetupOptions) =>
      original.unhover(element, withClock(options)),
    type: (
      element: Element,
      text: string,
      options?: Parameters<typeof userEvent.type>[2]
    ) => original.type(element, text, withClock(options)),
    keyboard: (text: string, options?: Parameters<typeof userEvent.keyboard>[1]) =>
      original.keyboard(text, withClock(options)),
    pointer: (
      input: Parameters<typeof userEvent.pointer>[0],
      options?: Parameters<typeof userEvent.pointer>[1]
    ) => original.pointer(input, withClock(options)),
    selectOptions: (
      select: Element,
      values: Parameters<typeof userEvent.selectOptions>[1],
      options?: SetupOptions
    ) => original.selectOptions(select, values, withClock(options)),
    deselectOptions: (
      select: Element,
      values: Parameters<typeof userEvent.deselectOptions>[1],
      options?: SetupOptions
    ) => original.deselectOptions(select, values, withClock(options)),
    upload: (element: HTMLElement, files: File | File[], options?: SetupOptions) =>
      original.upload(element, files, withClock(options)),
    copy: (options?: SetupOptions) => original.copy(withClock(options)),
    cut: (options?: SetupOptions) => original.cut(withClock(options)),
    paste: (data?: Parameters<typeof userEvent.paste>[0], options?: SetupOptions) =>
      original.paste(data, withClock(options)),
    // clear takes no setup options; run it on an instance that has the clock.
    clear: (element: Element) => original.setup(withClock()).clear(element),
    tab: ({ shift = false }: Parameters<typeof userEvent.tab>[0] = {}) =>
      original.keyboard(shift ? "{Shift>}{Tab}{/Shift}" : "{Tab}", withClock()),
  });
}
