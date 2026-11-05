// Fixed names only. Never send printable input or composing text to the bridge.
const namedKeys = new Set([
  "Enter",
  "Tab",
  "Escape",
  "Backspace",
  "Delete",
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "Home",
  "End",
  "PageUp",
  "PageDown",
  "Shift",
  "Control",
  "Alt",
  "Meta",
  "CapsLock",
  "Unidentified",
  "Dead",
]);
export function keyLabel(event: KeyboardEvent): string {
  if (event.key === " ") return "Space";
  if (event.metaKey && !event.altKey && !event.ctrlKey) {
    switch (event.key.toLowerCase()) {
      case "c":
        return "Cmd+C";
      case "v":
        return "Cmd+V";
      case "z":
        return event.shiftKey ? "Cmd+Shift+Z" : "Cmd+Z";
      case "y":
        if (!event.shiftKey) return "Cmd+Y";
        break;
      case "d":
        return "Cmd+D";
    }
  }
  return namedKeys.has(event.key) ? event.key : "<char>";
}
