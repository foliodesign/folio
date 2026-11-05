export const inputItems = [
  "finger tap",
  "one-finger drag",
  "two-finger pan",
  "pinch",
  "mouse click",
  "mouse drag",
  "mouse wheel",
  "trackpad scroll",
  "trackpad pinch",
  "Pencil tap",
  "Pencil drag",
  "Pencil hover",
  "keyboard modifiers",
  "keyboard shortcuts",
  "text field",
  "text-layer editing",
] as const;
export type InputItem = (typeof inputItems)[number];
export type Verdict = "NOT TESTED" | "PASS" | "FAIL";
export function summarize(results: Record<InputItem, Verdict>): string {
  return ["Touch", "Mouse", "Trackpad", "Pencil", "Keyboard", "Text"]
    .map((group) => {
      const items = inputItems.filter((item) => {
        if (group === "Touch")
          return [
            "finger tap",
            "one-finger drag",
            "two-finger pan",
            "pinch",
          ].includes(item);
        return item.toLowerCase().startsWith(group.toLowerCase());
      });
      return `${group} tests: ${items.map((item) => `${results[item]}: ${item}`).join("; ")}`;
    })
    .join("\n");
}
