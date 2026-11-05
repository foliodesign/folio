// Debug-only, called explicitly by native in FolioDiagnostics. Never installed as a user script.
// Structure only. Labels use an exact UI vocabulary; all other strings are redacted.
export const captureDOMStructure = async (tools: boolean) => {
  const labels = new Set([
    "Move",
    "Hand",
    "Hand tool",
    "Scale",
    "Frame",
    "Section",
    "Slice",
    "Rectangle",
    "Line",
    "Arrow",
    "Ellipse",
    "Pen",
    "Pencil",
    "Text",
    "Comment",
    "Actions",
    "Design",
    "Dev",
    "Dev Mode",
    "Design mode",
    "Draw",
    "Draw mode",
    "Inspect",
    "Plugins",
    "Switch to Dev Mode",
    "Switch to Design",
    "Minimize UI",
    "Measurement",
    "Annotation",
  ]);
  const label = (value: string | null) =>
    value === null
      ? null
      : labels.has(value)
        ? value
        : value.startsWith("Expand UI")
          ? "Expand UI [redacted]"
          : "[redacted]";
  // CSS-module/atomic classes are structural. Arbitrary user-provided tokens/IDs are omitted.
  const classes = (el: Element) =>
    Array.from(el.classList)
      .slice(0, 32)
      .map((value) =>
        /^(?:[a-z][a-z0-9_]*--[A-Za-z0-9_-]+|x[a-z0-9]{4,16}|gpu-view-content|view|container-view|selected)$/.test(
          value,
        )
          ? value
          : "[redacted]",
      );
  const testID = (el: Element) => {
    const value = el.getAttribute("data-testid");
    return value === null
      ? null
      : /^(?:Hand tool-tool|hand-tool|[A-Z][A-Za-z]+-(?:tool|chevron)|[a-zA-Z][a-zA-Z_.-]*(?:panel|Panel|toolbelt|mode|Mode|tab|Tab)[a-zA-Z_.-]*|navigation-bar(?:-top-section)?)$/.test(
            value,
          )
        ? value
        : "[redacted]";
  };
  const fields = [
    "position",
    "display",
    "width",
    "min-width",
    "max-width",
    "height",
    "min-height",
    "max-height",
    "left",
    "right",
    "top",
    "bottom",
    "flex",
    "flex-basis",
    "flex-grow",
    "align-self",
    "overflow",
    "background-color",
    "color",
    "border-radius",
    "box-shadow",
  ];
  const safeCSS = (value: string) => {
    const remaining = value
      .replace(/#[0-9a-f]{3,8}\b/gi, "0")
      .replace(/(?<=\d)(?:px|pt|rem|em|vh|vw|vmin|vmax)\b/gi, "")
      .replace(
        /\b(?:rgba?|hsla?|oklab|oklch|lab|lch|color|srgb|display-p3|px|pt|rem|em|vh|vw|vmin|vmax|auto|none|absolute|fixed|relative|static|sticky|flex|inline-flex|block|inline|grid|hidden|visible|scroll|clip|normal|stretch|start|end|center|inset|transparent|currentcolor|black|white)\b/gi,
        "",
      );
    return value.length <= 200 && /^[\d\s.,()%+-]*$/.test(remaining)
      ? value
      : "[redacted]";
  };
  const describe = (el: Element, compact = false) => {
    let inToolbar = false;
    for (
      let parent: Element | null = el;
      parent;
      parent = parent.parentElement
    ) {
      if (parent.getAttribute("data-testid") === "positioned-design-toolbelt") {
        inToolbar = true;
        break;
      }
    }
    const properties = inToolbar
      ? fields
      : fields.filter(
          (name) =>
            ![
              "background-color",
              "color",
              "border-radius",
              "box-shadow",
            ].includes(name),
        );
    const rawLabel = el.getAttribute("aria-label");
    const uiLabel =
      inToolbar ||
      rawLabel === "Minimize UI" ||
      rawLabel?.startsWith("Expand UI")
        ? label(rawLabel)
        : rawLabel === null
          ? null
          : "[redacted]";
    const css = getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    const variables: Record<string, string> = {};
    for (
      let i = 0;
      !compact && i < css.length && Object.keys(variables).length < 60;
      i++
    ) {
      const name = css.item(i);
      if (
        (el === document.documentElement ||
          el.matches('[data-testid="positioned-design-toolbelt"]') ||
          /^--(?:x-width|x-height|left-panel-width|right-panel-width|left-rail-width)$/.test(
            name,
          )) &&
        /^--[a-zA-Z-]*(?:width|height|size|radius|color|colour|bg|background)[a-zA-Z-]*$/.test(
          name,
        )
      )
        variables[name] = safeCSS(css.getPropertyValue(name).trim());
    }
    return {
      tag: el.tagName.toLowerCase(),
      iconPathFingerprint:
        el.tagName.toLowerCase() === "path" &&
        el.closest('[data-testid="positioned-design-toolbelt"]')
          ? (() => {
              const path = el.getAttribute("d") ?? "";
              let hash = 2166136261;
              for (let i = 0; i < path.length && i < 8192; i++)
                hash = Math.imul(hash ^ path.charCodeAt(i), 16777619);
              return (hash >>> 0).toString(16);
            })()
          : null,
      id: ["root", "react-page", "canvas"].includes(el.id)
        ? el.id
        : el.id
          ? "[redacted]"
          : "",
      classes: classes(el),
      testid: testID(el),
      role: labelRole(el.getAttribute("role")),
      states: Object.fromEntries(
        [
          "aria-pressed",
          "aria-checked",
          "aria-selected",
          "aria-expanded",
          "data-state",
        ].map((name) => {
          const value = el.getAttribute(name);
          return [
            name,
            value === null ||
            [
              "true",
              "false",
              "mixed",
              "on",
              "off",
              "active",
              "inactive",
              "checked",
              "unchecked",
            ].includes(value)
              ? value
              : "[redacted]",
          ];
        }),
      ),
      checked:
        inToolbar && el.matches('input[type="radio"]')
          ? (el as HTMLInputElement).checked
          : null,
      uiLabel,
      buttonLabel: el.matches('button,[role="button"]') ? uiLabel : null,
      rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      inline: compact
        ? {}
        : Object.fromEntries(
            properties.map((name) => [
              name,
              safeCSS((el as HTMLElement).style?.getPropertyValue(name) ?? ""),
            ]),
          ),
      css: compact
        ? {}
        : Object.fromEntries(
            properties.map((name) => [
              name,
              safeCSS(css.getPropertyValue(name)),
            ]),
          ),
      variables,
    };
  };
  const labelRole = (value: string | null) =>
    value === null ||
    [
      "button",
      "tab",
      "tablist",
      "tabpanel",
      "toolbar",
      "switch",
      "radio",
      "radiogroup",
      "dialog",
      "menu",
      "menuitem",
      "separator",
      "presentation",
      "none",
    ].includes(value)
      ? value
      : "[redacted]";
  const snapshot = (toolsOnly = false) => {
    const toolbar = document.querySelector(
      '[data-testid="positioned-design-toolbelt"]',
    );
    const targets = new Set<Element>([document.documentElement, document.body]);
    // The observed not-found document has this root but none of the editor targets.
    // Capture bounded structure only; labels/text/accounts retain the same redaction.
    const unavailableRoot =
      !toolbar && !document.querySelector("canvas, .gpu-view-content")
        ? document.querySelector("#react-page")
        : null;
    if (unavailableRoot) targets.add(unavailableRoot);
    for (const selector of toolsOnly
      ? ['[data-testid="positioned-design-toolbelt"]']
      : [
          '[data-testid="positioned-design-toolbelt"]',
          '[data-testid="properties-panel"]',
          '[class*="properties_panel--"]',
          '[class*="dev_mode"]',
          '[class*="devMode"]',
          '[class*="inspect_panel"]',
          '[class*="right_panel"]',
          '[class*="left_panel_container--"]',
          '[data-testid*="panel"]',
          '[data-testid*="Panel"]',
          '[data-testid="navigation-bar"]',
          ".gpu-view-content > canvas",
        ])
      for (const el of document.querySelectorAll(selector)) targets.add(el);
    const nodes: (ReturnType<typeof describe> & {
      index: number;
      parent: number | null;
    })[] = [];
    const seen = new Set<Element>();
    const indices = new Map<Element, number>();
    const visit = (el: Element, parent: number | null, depth: number) => {
      if (seen.has(el) || nodes.length >= (toolsOnly ? 600 : 800)) return;
      seen.add(el);
      const index = nodes.length;
      indices.set(el, index);
      nodes.push({ ...describe(el, toolsOnly), ...{ index, parent } });
      if (depth > 0)
        for (const child of el.children) visit(child, index, depth - 1);
    };
    for (const target of targets) {
      // Ancestors expose width-owning wrappers without exporting unrelated document trees.
      const chain: Element[] = [];
      for (
        let el: Element | null = target, i = 0;
        el && i < 6;
        el = el.parentElement, i++
      )
        chain.unshift(el);
      for (const [i, el] of chain.entries())
        visit(el, i ? (indices.get(chain[i - 1]!) ?? null) : null, 0);
      for (const child of target.children)
        visit(
          child,
          indices.get(target) ?? null,
          target === toolbar
            ? 18
            : target === unavailableRoot
              ? 6
              : target === document.body || target === document.documentElement
                ? 0
                : 4,
        );
    }
    // Evidence is saved along with a conservative mode label. No page URL is read/exported.
    const row = toolbar?.querySelector(
      '[class*="toolbelt_left_side--visibleCarouselRow--"]',
    );
    const mode = row?.querySelector(
      '[data-testid="Measurement-tool"],[data-testid="Annotation-tool"]',
    )
      ? "dev"
      : row?.querySelector(
            '[data-testid="Frame-tool"],[data-testid="Rectangle-tool"]',
          )
        ? "design"
        : "unknown";
    return {
      mode,
      modeSource: "visible-tool-row",
      viewport: {
        width: innerWidth,
        height: innerHeight,
        scale: devicePixelRatio,
      },
      nodes,
      limitReached: nodes.length >= (toolsOnly ? 600 : 800),
    };
  };
  const result = {
    schema: 1,
    focus: document.activeElement
      ? describe(document.activeElement, true)
      : null,
    baseline: snapshot(),
    modes: [] as ReturnType<typeof snapshot>[],
    tools: [] as { key: string; structure: ReturnType<typeof snapshot> }[],
    toolCheck: "not-requested",
  };
  if (tools) {
    const target = () =>
      document.activeElement ?? document.body ?? document.documentElement;
    const toolbar = () =>
      document.querySelector('[data-testid="positioned-design-toolbelt"]');
    const editing = () => {
      const focused = document.activeElement;
      // Figma's verified mode radios are controls, not document/property text editors.
      if (
        focused?.matches('input[type="radio"]') &&
        focused.closest('[data-testid="toolbelt-mode-segmented-control"]')
      )
        return false;
      const editor = focused?.closest(
        'input,textarea,[contenteditable="true"],[role="textbox"]',
      );
      if (!editor) return false;
      // The physical capture found Figma's 1 px focus proxy at y=-200. It is
      // not a visible text field; standard shortcuts target it just as native does.
      const rect = editor.getBoundingClientRect();
      const css = getComputedStyle(editor);
      return (
        rect.width > 1 &&
        rect.height > 1 &&
        rect.right > 0 &&
        rect.bottom > 0 &&
        rect.left < innerWidth &&
        rect.top < innerHeight &&
        css.display !== "none" &&
        css.visibility !== "hidden"
      );
    };
    const key = (name: string, shift = false) => {
      const destination = target();
      if (editing() || !destination?.isConnected || !toolbar()?.isConnected)
        return false;
      for (const type of ["keydown", "keyup"])
        destination.dispatchEvent(
          new KeyboardEvent(type, {
            key: shift ? name.toUpperCase() : name,
            shiftKey: shift,
            code: `Key${name.toUpperCase()}`,
            keyCode: name.toUpperCase().charCodeAt(0),
            which: name.toUpperCase().charCodeAt(0),
            bubbles: true,
            cancelable: true,
            composed: true,
          }),
        );
      return true;
    };
    result.toolCheck =
      toolbar() && target() && !editing()
        ? "dispatched-not-acceptance"
        : "skipped-editor-or-no-toolbar";
    const previousPanel = globalThis.__folio?.phonePanel?.().state;
    if (toolbar() && target() && !editing())
      try {
        // Exercise the existing phone sheet, then restore its prior choice below.
        if (previousPanel !== "right" && previousPanel !== "both")
          globalThis.__folio?.phonePanel?.("right");
        await new Promise((resolve) => setTimeout(resolve, 200));
        result.baseline = snapshot();
        for (let i = 0; i < 2; i++) {
          if (!key("d", true)) break;
          await new Promise((resolve) => setTimeout(resolve, 1500));
          result.modes.push(snapshot());
        }
        for (const name of ["h", "k"]) {
          if (!key(name)) break;
          await new Promise((resolve) => setTimeout(resolve, 700));
          result.tools.push({
            key: name.toUpperCase(),
            structure: snapshot(true),
          });
        }
      } finally {
        if (key("v")) {
          await new Promise((resolve) => setTimeout(resolve, 700));
          result.tools.push({ key: "V", structure: snapshot(true) });
        } else result.toolCheck = "return-to-move-skipped-editor-or-detached";
        if (previousPanel !== "right" && previousPanel !== "both") {
          globalThis.__folio?.phonePanel?.("none");
          if (previousPanel === "left")
            globalThis.__folio?.phonePanel?.("left");
        }
      }
  }
  return JSON.stringify(result);
};
Object.assign(globalThis, { __folioCaptureDOMStructure: captureDOMStructure });
