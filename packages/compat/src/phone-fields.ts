// iPhone sheet fields (2026-10-12), used by phone-layout.ts. Pure helpers over standard DOM:
// which inputs are numeric property fields, where a focused field should scroll to, and how a
// key from Folio's native key row is typed. Values are read only to classify a field and never
// leave the page.

// A number with an optional sign and unit: "-820", "12.5", "50%", "-90°", "1,5".
const numberValue =
  /^[-+−]?(\d+([.,]\d*)?|[.,]\d+)\s*(%|°|px|pt|ms|s|x|deg)?$/i;
// Six or eight plain digits read as a hex colour ("000000", "FFFFFF" never matches anyway).
const hexLike = /^[0-9a-f]{6}([0-9a-f]{2})?$/i;
// Labels that mark a text, colour or search field even when its value looks numeric.
const textLabel =
  /hex|colou?r|search|name|font|url|link|mail|comment|note|description/i;

export interface FieldLike {
  tagName: string;
  value: string;
  readOnly?: boolean;
  disabled?: boolean;
  getAttribute(name: string): string | null;
}

/** A Figma numeric property input: a plain text input whose value parses as a number. */
export const numericField = (el: FieldLike): boolean => {
  if (el.tagName !== "INPUT" || el.readOnly || el.disabled) return false;
  const type = (el.getAttribute("type") ?? "text").toLowerCase();
  if (type !== "text" && type !== "number") return false;
  for (const name of ["aria-label", "placeholder", "name", "data-testid"])
    if (textLabel.test(el.getAttribute(name) ?? "")) return false;
  if (/hex|search/i.test(el.getAttribute("class") ?? "")) return false;
  const value = el.value.trim();
  return numberValue.test(value) && !hexLike.test(value);
};

/**
 * Scroll offset change that puts a field comfortably inside [top, bottom]: zero when it is
 * already inside with a margin, else its top lands a third of the way down the free space.
 */
export const revealDelta = (
  field: { top: number; bottom: number },
  top: number,
  bottom: number,
  margin = 8,
): number => {
  if (field.top >= top + margin && field.bottom <= bottom - margin) return 0;
  const free = Math.max(0, bottom - top - (field.bottom - field.top));
  return Math.round(field.top - (top + free / 3));
};

/** Native key row ids and the characters they type. Figma parses * and / as × and ÷. */
export const keyText: Record<string, string> = {
  minus: "-",
  plus: "+",
  times: "*",
  divide: "/",
  percent: "%",
  point: ".",
};

export interface EditableField {
  value: string;
  selectionStart: number | null;
  selectionEnd: number | null;
  setSelectionRange(start: number, end: number): void;
  setRangeText(text: string, start: number, end: number, mode: "end"): void;
  dispatchEvent(event: Event): boolean;
}

/**
 * Types text at the caret the way the keyboard would: the standard insertText editing command,
 * which fires beforeinput/input; a plain range edit plus an input event if the command fails.
 */
export const insertText = (
  el: EditableField,
  text: string,
  doc: {
    execCommand?: (command: string, ui: boolean, value: string) => boolean;
  },
): void => {
  try {
    if (doc.execCommand?.("insertText", false, text)) return;
  } catch {
    /* Fall through to the range edit. */
  }
  const start = el.selectionStart ?? el.value.length;
  const end = el.selectionEnd ?? start;
  el.setRangeText(text, start, end, "end");
  const init = { bubbles: true, inputType: "insertText", data: text };
  el.dispatchEvent(
    typeof InputEvent === "function"
      ? new InputEvent("input", init)
      : new Event("input", { bubbles: true }),
  );
};

/** ± : removes a leading minus or adds one, keeping the caret on the same digit. */
export const toggleSign = (
  el: EditableField,
  doc: {
    execCommand?: (command: string, ui: boolean, value: string) => boolean;
  },
): void => {
  const caret = el.selectionEnd ?? el.value.length;
  const negative = /^[-−]/.test(el.value);
  el.setSelectionRange(0, negative ? 1 : 0);
  if (negative) {
    let deleted = false;
    try {
      deleted = !!doc.execCommand?.("delete", false, "");
    } catch {
      deleted = false;
    }
    if (!deleted) {
      el.setRangeText("", 0, 1, "end");
      el.dispatchEvent(new Event("input", { bubbles: true }));
    }
  } else insertText(el, "-", doc);
  const next = Math.max(0, caret + (negative ? -1 : 1));
  el.setSelectionRange(next, next);
};
