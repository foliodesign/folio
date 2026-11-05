import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";

const { outputFiles } = await build({
  entryPoints: [new URL("../src/phone-fields.ts", import.meta.url).pathname],
  bundle: true,
  format: "esm",
  write: false,
});
const fields = await import(
  `data:text/javascript;base64,${Buffer.from(outputFiles[0].text).toString("base64")}`
);

const input = (value, attrs = {}, tagName = "INPUT") => ({
  tagName,
  value,
  getAttribute: (name) => attrs[name] ?? null,
});

test("numeric fields: numbers, signs and units; not hex, text, labels or other tags", () => {
  for (const value of [
    "-820",
    "1000",
    "12.5",
    "-90°",
    "50%",
    "0",
    ".5",
    "1,5",
    " 34 ",
  ])
    assert.equal(fields.numericField(input(value)), true, value);
  for (const value of [
    "000000",
    "D9D9D9",
    "FFFFFF80",
    "Mixed",
    "",
    "Auto",
    "100*2",
    "Rectangle",
  ])
    assert.equal(fields.numericField(input(value)), false, value);
  assert.equal(
    fields.numericField(input("12", { "aria-label": "Layer name" })),
    false,
  );
  assert.equal(
    fields.numericField(input("12", { placeholder: "Search" })),
    false,
  );
  assert.equal(
    fields.numericField(input("12", { class: "color_input--hex" })),
    false,
  );
  assert.equal(fields.numericField(input("12", { type: "checkbox" })), false);
  assert.equal(fields.numericField(input("12", {}, "TEXTAREA")), false);
  assert.equal(fields.numericField({ ...input("12"), readOnly: true }), false);
});

test("reveal: leaves a visible field alone, else puts it a third down the free space", () => {
  assert.equal(fields.revealDelta({ top: 200, bottom: 228 }, 100, 300), 0);
  // Below the visible bottom: scroll down.
  assert.equal(fields.revealDelta({ top: 600, bottom: 628 }, 150, 308), 407);
  // Above the sheet top: scroll up.
  assert.equal(fields.revealDelta({ top: 50, bottom: 78 }, 150, 308), -143);
});

const editable = (value, caret = value.length) => {
  const events = [];
  const el = {
    value,
    selectionStart: caret,
    selectionEnd: caret,
    events,
    setSelectionRange(start, end) {
      el.selectionStart = start;
      el.selectionEnd = end;
    },
    setRangeText(text, start, end) {
      el.value = el.value.slice(0, start) + text + el.value.slice(end);
      el.selectionStart = el.selectionEnd = start + text.length;
    },
    dispatchEvent(event) {
      events.push(event.type);
      return true;
    },
  };
  return el;
};
// Stands in for the browser's editing commands on one field.
const editing = (el) => ({
  execCommand(command, _ui, text) {
    if (command === "insertText")
      el.setRangeText(text, el.selectionStart, el.selectionEnd);
    else if (command === "delete")
      el.setRangeText("", el.selectionStart, el.selectionEnd);
    else return false;
    el.events.push("input");
    return true;
  },
});

test("insert: the standard insertText command, or a range edit plus an input event", () => {
  const a = editable("100", 3);
  fields.insertText(a, "*", editing(a));
  assert.equal(a.value, "100*");
  const b = editable("100", 1);
  fields.insertText(b, "%", { execCommand: () => false });
  assert.equal(b.value, "1%00");
  assert.deepEqual(b.events, ["input"]);
  const c = editable("5");
  fields.insertText(c, ".", {});
  assert.equal(c.value, "5.");
  assert.deepEqual(fields.keyText, {
    minus: "-",
    plus: "+",
    times: "*",
    divide: "/",
    percent: "%",
    point: ".",
  });
});

test("sign: adds or removes a leading minus and keeps the caret on its digit", () => {
  const a = editable("820", 2);
  fields.toggleSign(a, editing(a));
  assert.equal(a.value, "-820");
  assert.equal(a.selectionEnd, 3);
  fields.toggleSign(a, editing(a));
  assert.equal(a.value, "820");
  assert.equal(a.selectionEnd, 2);
  const b = editable("-5");
  fields.toggleSign(b, { execCommand: () => false });
  assert.equal(b.value, "5");
  assert.equal(b.selectionEnd, 1);
});
