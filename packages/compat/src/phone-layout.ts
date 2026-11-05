import "./bridge";
import {
  insertText,
  keyText,
  numericField,
  revealDelta,
  toggleSign,
} from "./phone-fields";

// Maintainer exception (2026-10-10, revised 2026-10-11), iPhone; extended 2026-10-19 to narrow
// iPad windows (below PhoneExperiencePolicy.compactWindowWidth). Figma's desktop editor
// does not fit a phone, and its renderer reserves sidebar space that CSS cannot reclaim
// (verified with Web Inspector on an iPhone 16 Pro). So Folio:
// - puts Figma in its own minimized UI (a plain click on Figma's Minimize UI button, or the
//   standard ⇧⌘\ chord when the button is not found), which gives the canvas the whole view;
// - shows one panel as a bottom sheet; the wide layout keeps Figma expanded even when
//   sheets are closed, so sheet toggles never resize the renderer;
// - hides Figma's navigation rail and floating tool bar (kept in the DOM) and reports the active
//   tool and the Design/Dev Mode state to native as fixed ids, so Folio's pill can show them.
// - "Canvas beside panels" (experimental, 2026-10-12): while the layout is active Figma stays
//   expanded and its renderer reserves rail and sidebar space, which leaves no canvas on a
//   phone. Folio measures that reservation from the canvas geometry and reports it; native then
//   makes the web view wider by exactly that much and shifts it left, so Figma's own canvas area
//   lands on the screen. The sheet is placed over the visible part, and menus or dialogs that
//   land off-screen are translated back into it.
// - Sheet fields (2026-10-12): while a sheet is open native keeps the web view at full height
//   under the keyboard and, as the keyboard starts to move, sends its final overlap and a
//   minimum sheet fraction (`phoneKeyboard`). The sheet jumps once to its final place (bottom
//   on the keyboard, top raised to that minimum) and a focused field is scrolled into view in
//   the same frame; nothing animates or settles later. Figma's renderer is never resized for
//   the keyboard. With "Number keyboard for
//   numeric fields" on, inputs
//   whose value is a number get inputmode="decimal", and native's key row types − + × ÷ % . ±
//   through the standard insertText command.
// - Side panels (2026-10-12, iPhone landscape with "Canvas beside panels"): no sheet. Layers
//   and Properties stay where Figma puts them, at its own widths, each opened and closed on its
//   own. A closed side is simply pushed off-screen by native (its reservation joins the
//   overscan), so toggling changes only the native frame; no panel style is touched. Figma keeps
//   its viewport origin at the canvas's left edge, which moves on screen with Layers; one
//   standard wheel event of exactly that move pans the canvas back, so its content stays put.
// - Keyboard bleed (2026-10-12): with the keyboard up the sheet ends on it, and a box shadow in
//   the panel's own colour fills the rest down to the bottom, behind the keyboard's translucent
//   parts, so no canvas shows between sheet and keyboard.
// Presentation and input only: one stylesheet, data-folio-phone markers, the inputmode
// attribute and Figma's own UI toggles. No Figma script, request or data is touched. Installed
// on every device but inert until native enables it for a compact-layout file tab; never in
// Safe mode or auth children.
type Panel = "left" | "right" | "none";
type Side = "left" | "right";
type Figma = "min" | "expanded" | "unknown";
type Role = "rail" | "tools" | "left" | "leftSize" | "right";
type Mode = "design" | "dev" | "unknown";
// Fixed tool-test ids mapped to Folio's active tool keys. Physical H/K/V capture
// on 2026-10-12 verified "Hand tool-tool", "Scale-tool" and "Move-tool", all with
// aria-pressed=true in the visible carousel row. Hidden duplicates are excluded.
const tools = new Map([
  ["Move", "move"],
  ["Hand tool", "hand"],
  ["Scale", "scale"],
  ["Frame", "frame"],
  ["Section", "section"],
  ["Slice", "slice"],
  ["Rectangle", "rectangle"],
  ["Line", "line"],
  ["Arrow", "arrow"],
  ["Ellipse", "ellipse"],
  ["Pen", "pen"],
  ["Pencil", "pencil"],
  ["Text", "text"],
  ["Comment", "comment"],
  // Dev Mode row, verified ids on 2026-10-12; their aria-pressed marker is assumed to match.
  ["Measurement", "measurement"],
  ["Annotation", "annotation"],
]);
// Verified on the iPhone 16 Pro, 2026-10-12. The segment uses native radio
// inputs: design is Design, handoff is Dev. illustration/metronome are other modes.
// Read the checked property, which changes without an aria-pressed attribute.
const runtime = globalThis.__folio;
if (runtime && !runtime.setPhoneLayout) {
  const attribute = "data-folio-phone";
  // Verified test ids first, then class-name fragments. Each entry is one compound selector.
  const selectors = {
    rail: ['[data-testid="navigation-bar"]'],
    railTop: ['[data-testid="navigation-bar-top-section"]'],
    tools: [
      '[data-testid="positioned-design-toolbelt"]',
      '[class*="positioned_design_toolbelt--root--"]',
      '[data-testid="design-toolbelt-wrapper"]',
      '[class*="toolbelt--root--"]',
    ],
    leftSize: ['[class*="left_panel_container--sizeContainer--"]'],
    right: [
      '[data-testid="properties-panel"]',
      '[class*="properties_panel--drillDownContainer--"]',
    ],
    minimize: ['button[aria-label="Minimize UI"]'],
    // The Expand UI label continues with the file name: match the prefix, never read it.
    expand: [
      'button[aria-label^="Expand UI"]',
      '[class*="toggle_expanded_sidebar_button--button--"]',
    ],
    canvas: [
      ".gpu-view-content > canvas",
      '[class*="fullscreen_view--page--"] canvas',
    ],
    // Common overlay landmarks kept inside the visible region in the wide viewport.
    overlays: [
      '[role="dialog"]',
      '[aria-modal="true"]',
      '[role="menu"]',
      '[role="listbox"]',
      '[role="tooltip"]',
      // Colour picker class fallbacks are not yet verified on the locked phone.
      '[class*="color_picker_modal--colorPickerModal--"]',
      '[class*="color_picker--root--"]',
    ],
  };
  const first = (list: string[], root: ParentNode = document) => {
    for (const selector of list) {
      const el = root.querySelector(selector);
      if (el) return el;
    }
    return null;
  };
  const collapsed = (el: Element) =>
    String(el.className).includes("propertiesPanelCollapsed");

  let enabled = false;
  let seeded = false;
  // Native switch "Canvas beside panels": report the reservation and lay out for the wide view.
  let wide = false;
  // iPhone landscape with the wide layout: Figma's side panels at their own places.
  let sidesWanted = false;
  const sidesOn = () => wide && sidesWanted;
  const open = new Set<Side>();
  // Renderer reservation left and right of the canvas (CSS px), last measured while expanded.
  let reserve: [number, number] = [0, 0];
  // Part of the left reservation before the Layers panel (the rail, which Folio hides).
  let railReserve = 0;
  let measurementDirty = true;
  let measureAfter = 0;
  const shifts = new Map<Element, [number, number]>();
  let settle: ReturnType<typeof setTimeout> | undefined;
  let frame: number | undefined;
  // Folio keeps Figma minimized unless the user expanded it through Figma's own control.
  let minimize = true;
  let panel: Panel = "none";
  let pending: Panel = "none";
  let pendingUntil = 0;
  let sheet = 0.5;
  // A drag lays out the panel once at its maximum height. Only its composited translation
  // changes until release. The viewport clips the unused lower part without resizing Figma.
  let sheetDrag: { element: Element; top: number; height: number } | undefined;
  const stopSheetDrag = () => {
    sheetDrag = undefined;
    dragStyle.remove();
    dragStyle.textContent = "";
  };
  let figma: Figma = "unknown";
  let ownUntil = 0;
  let attempts = 0;
  let lastAttempt = -Infinity;
  let tool = "none";
  let mode: Mode = "unknown";
  let posted = "";
  let path = "";
  let timer: ReturnType<typeof setTimeout> | undefined;
  let watchedTools: Element | undefined;
  let watchedCanvas: Element | undefined;
  // Sheet fields: the native switch and the focused sheet input. The keyboard state comes from
  // native: its overlap (CSS px) and the minimum sheet fraction while it is up.
  let numberKeyboard = false;
  let field: HTMLInputElement | null = null;
  let keyboard = 0;
  let raised = 0;
  let fieldPosted = "";
  let releaseTimer: ReturnType<typeof setTimeout> | undefined;
  let layoutSize = "";
  // Landscape Layers toggle: CSS px the canvas's left edge moved on screen, panned back once the
  // web view has its new width.
  let pan = 0;
  let panUntil = 0;
  // What native shows: transient blanks (a remounting tool bar, an unknown mode) and overlay
  // flicker wait out a short hold, so selection changes never move or rebuild the pill.
  let shownTool = "none";
  let shownMode: Mode = "unknown";
  let shownTools: string[] = [];
  let shownOverlay = false;
  const since = { tool: -1, mode: -1, tools: -1, overlay: -1 };
  let holdTimer: ReturnType<typeof setTimeout> | undefined;
  // Inputs given inputmode="decimal", with their own prior inputmode to restore.
  const marked = new Map<Element, string | null>();
  const found = new Map<Role, Element>();
  const style = document.createElement("style");
  const dragStyle = document.createElement("style");
  style.setAttribute(attribute, "style");
  const eligible = () =>
    location.protocol === "https:" &&
    (!location.port || location.port === "443") &&
    ["figma.com", "www.figma.com"].includes(location.hostname) &&
    /^\/(design|file)\//.test(location.pathname);

  // Geometry guards apply only to fallbacks, and only before Folio hides the element.
  const bottomBar = (el: Element) => {
    const r = el.getBoundingClientRect();
    return r.top > innerHeight * 0.6 && r.height >= 24 && r.height <= 120;
  };
  const edgeRail = (el: Element) => {
    const r = el.getBoundingClientRect();
    return (
      r.left <= 8 &&
      r.width > 0 &&
      r.width <= 96 &&
      r.height >= innerHeight * 0.45
    );
  };
  const locate = (role: Role): Element | null => {
    switch (role) {
      case "rail": {
        const rail = first(selectors.rail);
        if (rail) return rail;
        const parent = first(selectors.railTop)?.parentElement;
        return parent && edgeRail(parent) ? parent : null;
      }
      case "tools": {
        for (const [index, selector] of selectors.tools.entries()) {
          const el = document.querySelector(selector);
          if (el && (index === 0 || bottomBar(el))) return el;
        }
        return null;
      }
      case "left": {
        for (const el of document.querySelectorAll(
          '[class*="left_panel_container--positionContainer--"]',
        ))
          if (first(selectors.leftSize, el)) return el;
        return first(selectors.leftSize)?.parentElement ?? null;
      }
      case "leftSize": {
        const left = found.get("left");
        return left ? first(selectors.leftSize, left) : null;
      }
      case "right":
        return first(selectors.right);
    }
  };
  const roles: Role[] = ["rail", "tools", "left", "leftSize", "right"];
  const resolve = () => {
    for (const role of roles) {
      const old = found.get(role);
      if (old?.isConnected && old.getAttribute(attribute) === role) continue;
      if (old) {
        old.removeAttribute(attribute);
        found.delete(role);
      }
      const el = locate(role);
      if (!el) continue;
      el.setAttribute(attribute, role);
      found.set(role, el);
    }
  };
  const has = (side: Panel) => {
    if (side === "none") return false;
    const el = found.get(side);
    return !!el && (side === "left" || !collapsed(el));
  };
  // Figma's own controls tell its state; rail and collapsed properties are the fallback.
  const figmaState = (): Figma => {
    if (first(selectors.minimize)) return "expanded";
    if (first(selectors.expand)) return "min";
    if (found.has("rail")) return "expanded";
    const right = found.get("right");
    return right && collapsed(right) ? "min" : "unknown";
  };
  // One plain click on Figma's button, or its standard ⇧⌘\ chord when the button is missing.
  // Bounded: at most five tries, 1.5 s apart, until the next explicit Folio action.
  const toggle = (to: Figma) => {
    const now = performance.now();
    if (attempts >= 5) return;
    if (now - lastAttempt < 1500) {
      schedule(1500 - (now - lastAttempt));
      return;
    }
    attempts += 1;
    lastAttempt = now;
    ownUntil = now + 3000;
    const button = first(to === "min" ? selectors.minimize : selectors.expand);
    if (button && typeof (button as HTMLElement).click === "function")
      (button as HTMLElement).click();
    else runtime.minimizePhoneUI?.();
    schedule(300);
  };
  // Renderer-owned geometry: the canvas rect when it has width, else (portrait, width 0) its
  // ancestors' inline left/right offsets, as verified on the iPhone. Numbers only, clamped.
  const px = (value: string | undefined) => {
    const n = value?.endsWith("px") ? parseFloat(value) : 0;
    return Number.isFinite(n) ? n : 0;
  };
  const clampPx = (n: number) => Math.round(Math.min(1200, Math.max(0, n)));
  const ancestors = () => {
    const list: HTMLElement[] = [];
    let el = first(selectors.canvas)?.parentElement;
    for (let i = 0; el && i < 6; i++, el = el.parentElement)
      list.push(el as HTMLElement);
    return list;
  };
  const measure = (): [number, number] | null => {
    const canvas = first(selectors.canvas);
    if (!canvas) return null;
    // Prefer the renderer's reservation declarations. A popover or an intermediate
    // native resize can change the canvas rect without changing those reservations.
    let left = 0;
    let right = 0;
    for (const el of ancestors()) {
      left += px(el.style?.left);
      right += px(el.style?.right);
    }
    if (left + right > 0) return [clampPx(left), clampPx(right)];
    const r = canvas.getBoundingClientRect();
    return r.width >= 1
      ? [clampPx(r.left), clampPx(innerWidth - r.right)]
      : null;
  };
  // Where the Layers panel starts: its own rect when laid out, else the left reservation
  // minus the panel's inline width (it is display:none in sheet mode).
  const measureRail = (left: number) => {
    const r = found.get("left")?.getBoundingClientRect();
    if (r && r.width > 0) return clampPx(Math.min(left, r.left));
    const inner = found.get("leftSize") as HTMLElement | undefined;
    const width = px(inner?.style?.width);
    return width > 0 ? clampPx(Math.max(0, left - width)) : left;
  };
  // Layout width native adds left and right of the visible region. Sheet mode pushes the
  // whole reservation off-screen; side panels keep an open side's own part on-screen.
  const overscan = (): [number, number] => {
    if (!found.has("tools") || !first(selectors.canvas)) return [0, 0];
    const [left, right] = reserve;
    if (!sidesOn()) return [left, right];
    return [
      open.has("left") ? railReserve : left,
      open.has("right") ? 0 : right,
    ];
  };
  // On-screen width (CSS px) of the open landscape side panels.
  const sidePanels = (): [number, number] =>
    sidesOn()
      ? [
          open.has("left") ? Math.max(0, reserve[0] - railReserve) : 0,
          open.has("right") ? reserve[1] : 0,
        ]
      : [0, 0];
  // Visible region inside the web view, or null when native has not widened it (yet).
  const region = (): [number, number] | null => {
    if (!wide) return null;
    const [left, right] = overscan();
    const width = innerWidth - left - right;
    return left + right > 0 && width >= 160 ? [left, width] : null;
  };
  // Only public DOM structure/geometry. Never read values or document contents.
  const overlays = () => {
    const candidates = new Set<Element>();
    for (const selector of selectors.overlays)
      for (const el of document.querySelectorAll(selector)) {
        const r = el.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) candidates.add(el);
      }
    return [...candidates].filter((el) => {
      for (let parent = el.parentElement; parent; parent = parent.parentElement)
        if (candidates.has(parent)) return false;
      return !roles.some((role) => found.get(role) === el);
    });
  };
  // Only real popovers hide native chrome: menus, listboxes, dialogs and the colour picker that
  // are laid out. Tooltips and selection badges never count.
  const popoverOpen = () =>
    overlays().some((el) => el.getAttribute("role") !== "tooltip");
  // One CSS translation per overlay lifetime. Repeated DOM mutations never re-anchor it
  // or change WebKit geometry. Visual viewport tracks the keyboard's visible rectangle.
  const shiftOverlays = () => {
    const area = region() ?? [0, innerWidth];
    const viewport = globalThis.visualViewport;
    const left = area[0] + (viewport?.offsetLeft ?? 0);
    const width = Math.min(area[1], viewport?.width ?? area[1]);
    const top = viewport?.offsetTop ?? 0;
    const height = viewport?.height ?? innerHeight;
    const next = new Map<Element, [number, number]>();
    for (const el of overlays()) {
      const old = shifts.get(el);
      if (old) {
        next.set(el, old);
        continue;
      }
      const modal =
        el.getAttribute("aria-modal") === "true" ||
        String(el.className).includes("color_picker");
      // A dropdown a focused sheet field opened (variables, units) stays anchored to it.
      if (field && !modal) continue;
      const r = el.getBoundingClientRect();
      const dialog = modal || el.getAttribute("role") === "dialog";
      const overflow =
        r.left < left ||
        r.right > left + width ||
        r.top < top ||
        r.bottom > top + height;
      if (!dialog && !overflow) continue;
      next.set(el, [
        Math.round(left + (width - Math.min(r.width, width - 16)) / 2 - r.left),
        Math.round(
          top + (height - Math.min(r.height, height - 16)) / 2 - r.top,
        ),
      ]);
    }
    for (const el of shifts.keys())
      if (!next.has(el)) el.removeAttribute("data-folio-shift");
    shifts.clear();
    for (const [el, delta] of next) shifts.set(el, delta);
  };
  // Fixed tool ids only. Hidden carousel rows are other modes, not available tools.
  const visibleTools = () => {
    const root = found.get("tools");
    if (!root) return [];
    const ids = new Set<string>();
    for (const row of root.querySelectorAll(
      '[class*="toolbelt_left_side--visibleCarouselRow--"]',
    ))
      for (const button of row.querySelectorAll(
        'button[data-testid$="-tool"]',
      )) {
        const id = button.getAttribute("data-testid") ?? "";
        if (tools.has(id.slice(0, -5)) || id === "Actions-tool") ids.add(id);
      }
    return [...ids];
  };
  const readTool = () => {
    const root = found.get("tools");
    if (!root) return "none";
    const pressed = 'button[data-testid$="-tool"][aria-pressed="true"]';
    const rows = root.querySelectorAll(
      '[class*="toolbelt_left_side--visibleCarouselRow--"]',
    );
    // Hidden carousel rows duplicate the buttons, Move pressed included; ignore them.
    const buttons = rows.length
      ? Array.from(rows).flatMap((row) =>
          Array.from(row.querySelectorAll(pressed)),
        )
      : Array.from(root.querySelectorAll(pressed)).filter(
          (button) => !button.closest('[class*="hiddenCarouselRow"]'),
        );
    for (const button of buttons) {
      const id = button.getAttribute("data-testid")?.slice(0, -5) ?? "";
      const key = tools.get(id);
      if (key) return key;
    }
    return "none";
  };
  const readMode = (): Mode => {
    const root = found.get("tools");
    if (!root) return "unknown";
    const design = root.querySelector(
      'input[data-testid="toolbelt-mode-option-design"]',
    ) as HTMLInputElement | null;
    const dev = root.querySelector(
      'input[data-testid="toolbelt-mode-option-handoff"]',
    ) as HTMLInputElement | null;
    if (design || dev) {
      if (design?.checked && !dev?.checked) return "design";
      if (dev?.checked && !design?.checked) return "dev";
      return "unknown";
    }
    // Verified visible rows, excluding the duplicate hidden carousels.
    const shown = visibleTools();
    if (shown.includes("Measurement-tool") || shown.includes("Annotation-tool"))
      return "dev";
    if (shown.includes("Frame-tool") || shown.includes("Rectangle-tool"))
      return "design";
    return "unknown";
  };
  const visiblePanel = (): Panel => (panel !== "none" ? panel : pending);
  const sidesState = () =>
    open.size === 2
      ? "both"
      : open.has("left")
        ? "left"
        : open.has("right")
          ? "right"
          : "none";
  const state = () =>
    !enabled || !eligible() ? "off" : sidesOn() ? sidesState() : visiblePanel();
  const post = () => {
    const panelState = state();
    // Figma can mount loading UI before the renderer and tool belt exist.
    // Keep its loading viewport unshifted, including SPA transitions.
    const report =
      wide &&
      enabled &&
      eligible() &&
      found.has("tools") &&
      !!first(selectors.canvas);
    const [left, right] = overscan();
    const [panelLeft, panelRight] = report ? sidePanels() : [0, 0];
    const payload = {
      panel: panelState,
      tool: enabled ? shownTool : "none",
      mode: enabled ? shownMode : "unknown",
      visibleTools: enabled ? shownTools : [],
      minimize,
      // A Figma popover is open: native hides the grab bar and the pill so they cannot cut in.
      overlay: report && shownOverlay,
      left: report ? left : 0,
      right: report ? right : 0,
      // Landscape: on-screen width of the open side panels, so native centres the pill between.
      panelLeft,
      panelRight,
    };
    const text = JSON.stringify(payload);
    if (text === posted) return;
    posted = text;
    runtime.post("folioPhoneState", payload);
  };
  // The sheet's top and visible bottom in CSS px from the top of the web view: the same numbers
  // native places the grab bar from (fraction × browser height). Top-anchored with an explicit
  // height, so nothing depends on how WebKit treats the bottom of fixed elements under the
  // keyboard.
  const sheetTop = () =>
    Math.round(innerHeight * (1 - Math.max(sheet, raised)));
  const sheetBottom = () => Math.max(sheetTop() + 1, innerHeight - keyboard);
  const sheetBox = () =>
    sheetDrag
      ? `top:${sheetDrag.top}px!important;bottom:auto!important;height:${sheetDrag.height}px!important;will-change:transform!important;`
      : keyboard > 0
        ? `top:${sheetTop()}px!important;bottom:auto!important;height:${sheetBottom() - sheetTop()}px!important;`
        : `top:${sheetTop()}px!important;bottom:0!important;height:auto!important;`;
  // The panel's own background, or Figma's background token when the panel paints none.
  const panelColour = (el: Element | undefined) => {
    const colour = el
      ? (globalThis.getComputedStyle?.(el).backgroundColor ?? "")
      : "";
    return /^(rgb|#)/.test(colour) && !/^rgba\(.*,\s*0\)$/.test(colour)
      ? colour
      : "var(--color-bg,#2c2c2c)";
  };
  // With the keyboard up, a shadow in the panel's colour, offset and spread by the keyboard
  // overlap, covers from the sheet's top to the bottom of the web view (behind the keyboard)
  // without changing the sheet's own box, so its scrolling and the reveal maths stay as they are.
  const sheetShadow = (el: Element | undefined) =>
    "box-shadow:0 -1px 0 rgba(0,0,0,.25)" +
    (keyboard > 0
      ? `,0 ${keyboard}px 0 ${keyboard}px ${panelColour(el)}`
      : "") +
    "!important}";
  const css = () => {
    if (
      sheetDrag &&
      (sidesOn() || panel === "none" || found.get(panel) !== sheetDrag.element)
    )
      stopSheetDrag();
    const sel = (role: Role) => `[${attribute}="${role}"]`;
    // The tool bar stays laid out and in the DOM so its pressed state stays readable.
    let text =
      `${sel("tools")},${sel("tools")} *{visibility:hidden!important;pointer-events:none!important}` +
      `${sel("rail")}{display:none!important}`;
    // Side panels stay as Figma lays them out; closed sides are off-screen natively.
    const hidden = sidesOn()
      ? []
      : (["left", "right"] as const).filter((r) => r !== panel);
    if (hidden.length)
      text += `${hidden.map(sel).join(",")}{display:none!important}`;
    if (panel !== "none" && !sidesOn()) {
      // In the wide viewport the sheet covers only the visible region, the canvas's own area.
      const area = region();
      const across = area
        ? `left:${area[0]}px!important;right:auto!important;width:${area[1]}px!important;`
        : "left:0!important;right:0!important;width:100%!important;";
      text +=
        `${sel(panel)}{position:fixed!important;${across}` +
        sheetBox() +
        "transition:none!important;" +
        "min-width:0!important;" +
        "max-width:none!important;max-height:none!important;margin:0!important;" +
        "transform:none!important;z-index:100!important;overflow:auto!important;" +
        "border-radius:0!important;" +
        sheetShadow(found.get(panel));
      if (panel === "left")
        text += `${sel("leftSize")}{width:100%!important;min-width:0!important;max-width:none!important}`;
      else
        text +=
          `${sel("right")} [data-testid="propertiesPanelContainer.resizablePanel"]{display:none!important}` +
          `${sel("right")} [data-testid="dev-handoff-right-panel"]{width:100%!important;min-width:0!important;max-width:none!important}`;
    }
    let index = 0;
    for (const [el, [dx, dy]] of shifts) {
      el.setAttribute("data-folio-shift", String(++index));
      const width = region()?.[1] ?? innerWidth;
      const height = globalThis.visualViewport?.height ?? innerHeight;
      text +=
        `[data-folio-shift="${index}"]{translate:${dx}px ${dy}px!important;` +
        `max-width:${Math.max(1, width - 16)}px!important;` +
        `max-height:${Math.max(1, height - 16)}px!important;overflow:auto!important}`;
    }
    if (style.textContent !== text) style.textContent = text;
    const root = document.head ?? document.documentElement;
    if (root && style.parentNode !== root) root.appendChild(style);
  };
  const clear = () => {
    stopSheetDrag();
    releaseField();
    unmarkAll();
    for (const el of found.values()) el.removeAttribute(attribute);
    found.clear();
    for (const el of shifts.keys()) el.removeAttribute("data-folio-shift");
    shifts.clear();
    canvasObserver.disconnect();
    watchedCanvas = undefined;
    style.remove();
    toolObserver.disconnect();
    watchedTools = undefined;
  };
  const scan = () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    if (!enabled || !eligible()) {
      panel = pending = "none";
      open.clear();
      figma = "unknown";
      tool = "none";
      mode = "unknown";
      pan = 0;
      resetHold();
      clear();
      post();
      return;
    }
    if (location.pathname !== path) {
      // Another file: its first Figma state is not a user choice.
      path = location.pathname;
      figma = "unknown";
      panel = pending = "none";
      attempts = 0;
      lastAttempt = -Infinity;
      reserve = [0, 0];
      railReserve = 0;
      open.clear();
      pan = 0;
      resetHold();
      measurementDirty = true;
    }
    resolve();
    const belt = found.get("tools");
    if (belt !== watchedTools) {
      toolObserver.disconnect();
      watchedTools = belt;
      if (belt)
        toolObserver.observe(belt, {
          attributes: true,
          subtree: true,
          attributeFilter: [
            "aria-pressed",
            "aria-checked",
            "aria-selected",
            "data-state",
            "class",
          ],
        });
    }
    const now = performance.now();
    const nextMode = readMode();
    if (mode !== "unknown" && nextMode !== mode) {
      // A mode switch replaces Figma's panels and can briefly look minimized.
      // Preserve the sheet intent instead of treating that remount as a user close.
      ownUntil = Math.max(ownUntil, now + 3000);
    }
    const next = figmaState();
    if (next !== figma) {
      // A change Folio did not cause is the user's choice through Figma's own controls.
      if (now >= ownUntil && figma !== "unknown" && next !== "unknown") {
        minimize = next === "min";
        if (minimize) panel = pending = "none";
      }
      if (next !== "unknown") figma = next;
    }
    if (pending !== "none") {
      if (has(pending)) {
        panel = pending;
        pending = "none";
      } else if (now > pendingUntil) {
        pending = "none";
      } else schedule(250);
    }
    if (panel !== "none" && !has(panel)) {
      pending = panel;
      pendingUntil = now + 5000;
      panel = "none";
      schedule(250);
    }
    for (const side of open) if (!has(side)) open.delete(side);
    // The renderer re-writes its inline offsets after a resize; watch them while expanded.
    const canvas = first(selectors.canvas) ?? undefined;
    if (canvas !== watchedCanvas) {
      canvasObserver.disconnect();
      watchedCanvas = canvas;
      measurementDirty = true;
      if (canvas)
        for (const el of ancestors())
          canvasObserver.observe(el, {
            attributes: true,
            attributeFilter: ["style"],
          });
    }
    const overlayOpen = overlays().length > 0;
    if (measurementDirty && now < measureAfter) schedule(measureAfter - now);
    if (
      figma === "expanded" &&
      measurementDirty &&
      now >= measureAfter &&
      !overlayOpen
    ) {
      measurementDirty = false;
      const measured = measure();
      if (
        measured &&
        measured[0] + measured[1] > 0 &&
        (Math.abs(measured[0] - reserve[0]) > 1 ||
          Math.abs(measured[1] - reserve[1]) > 1)
      )
        reserve = measured;
      if (measured && measured[0] > 0) railReserve = measureRail(reserve[0]);
    }
    // Keep Figma's renderer and native frame stable across sheet toggles. Widen once
    // when the editor mounts, rather than resizing on every open/close.
    if (wide && figma === "min" && !overlayOpen) toggle("expanded");
    if (
      !wide &&
      !overlayOpen &&
      figma === "expanded" &&
      visiblePanel() === "none"
    ) {
      // Expanded with no sheet: Folio's default minimizes again; a user who expanded through
      // Figma gets the Layers sheet rather than a canvas squeezed between hidden panels.
      if (minimize) toggle("min");
      else if (has("left")) panel = "left";
    }
    tool = readTool();
    mode = nextMode;
    hold(now, popoverOpen());
    if (field && !inSheet(field)) releaseField();
    markFields();
    shiftOverlays();
    css();
    post();
  };
  // A blank value (tool none, mode unknown, no tools) replaces a shown one only after 500 ms;
  // the overlay flag turns on after 120 ms and off after 200 ms.
  const hold = (now: number, popover: boolean) => {
    const settle = <T>(
      key: keyof typeof since,
      shown: T,
      next: T,
      wait: number,
    ): T => {
      if (next === shown || wait === 0) {
        since[key] = -1;
        return next;
      }
      if (since[key] < 0) since[key] = now;
      const left = wait - (now - since[key]);
      if (left > 0) {
        // Its own timer, so a pending hold never delays a structure scan.
        if (holdTimer === undefined)
          holdTimer = setTimeout(() => {
            holdTimer = undefined;
            schedule(0);
          }, left);
        return shown;
      }
      since[key] = -1;
      return next;
    };
    shownTool = settle("tool", shownTool, tool, tool === "none" ? 500 : 0);
    shownMode = settle("mode", shownMode, mode, mode === "unknown" ? 500 : 0);
    const tools = visibleTools();
    shownTools =
      tools.join() === shownTools.join()
        ? shownTools
        : settle("tools", shownTools, tools, tools.length ? 0 : 500);
    shownOverlay = settle(
      "overlay",
      shownOverlay,
      popover,
      popover ? 120 : 200,
    );
  };
  const resetHold = () => {
    shownTool = "none";
    shownMode = "unknown";
    shownTools = [];
    shownOverlay = false;
    for (const key of Object.keys(since) as (keyof typeof since)[])
      since[key] = -1;
    if (holdTimer !== undefined) clearTimeout(holdTimer);
    holdTimer = undefined;
  };
  const schedule = (delay = 150) => {
    if (timer !== undefined || !enabled) return;
    timer = setTimeout(scan, delay);
  };
  // Structure changes re-resolve; the tool bar's pressed state updates the active tool.
  // Overlays get a quick pass on the next frame so a menu does not linger off-screen.
  const quick = () => {
    if (frame !== undefined || typeof requestAnimationFrame !== "function")
      return;
    frame = requestAnimationFrame(() => {
      frame = undefined;
      if (!enabled || !eligible()) return;
      shiftOverlays();
      css();
    });
  };
  const observer = new MutationObserver((records) => {
    // Our stylesheet text writes are not Figma structure changes. In particular, a transform
    // sample must not schedule a full panel/overlay scan and feed back into the drag.
    if (
      records.length &&
      records.every(
        (record) =>
          record.target === style ||
          record.target === dragStyle ||
          (record.addedNodes.length > 0 &&
            Array.from(record.addedNodes).every(
              (node) => node === style || node === dragStyle,
            )),
      )
    )
      return;
    quick();
    schedule(250);
  });
  const toolObserver = new MutationObserver(() => schedule(50));
  const canvasObserver = new MutationObserver(() => {
    measurementDirty = true;
    measureAfter = performance.now() + 200;
    schedule(200);
  });
  // A real viewport change (native widening or rotation): re-measure now and once settled.
  const resized = () => {
    // The keyboard only changes the visual viewport (the web view keeps its size while a
    // sheet is open), so only a real layout size change re-measures Figma's reservation.
    const size = `${innerWidth}x${innerHeight}`;
    const relayout = size !== layoutSize;
    layoutSize = size;
    if (relayout) stopSheetDrag();
    // Re-centre for keyboard/rotation, subtracting our previous translation once.
    for (const [el, [dx, dy]] of shifts) {
      const r = el.getBoundingClientRect();
      const area = region() ?? [0, innerWidth];
      const viewport = globalThis.visualViewport;
      shifts.set(el, [
        Math.round(
          area[0] +
            (viewport?.offsetLeft ?? 0) +
            (area[1] - Math.min(r.width, area[1] - 16)) / 2 -
            r.left +
            dx,
        ),
        Math.round(
          (viewport?.offsetTop ?? 0) +
            ((viewport?.height ?? innerHeight) -
              Math.min(r.height, (viewport?.height ?? innerHeight) - 16)) /
              2 -
            r.top +
            dy,
        ),
      ]);
    }
    css();
    if (field && sidesOn()) revealLater();
    if (!relayout) return;
    if (pan !== 0) panBack();
    measurementDirty = true;
    schedule(200);
    if (settle !== undefined) clearTimeout(settle);
    settle = setTimeout(() => {
      settle = undefined;
      schedule(0);
    }, 600);
  };
  // One standard wheel event over the visible canvas, after Figma's own resize handling: deltaX
  // in CSS px (positive pans the view right, so content moves left), like a trackpad scroll.
  const panBack = () => {
    const dx = pan;
    pan = 0;
    if (performance.now() > panUntil) return;
    const run = () => {
      const canvas = first(selectors.canvas);
      const area = region() ?? [0, innerWidth];
      if (!enabled || !sidesOn() || !canvas) return;
      canvas.dispatchEvent(
        new WheelEvent("wheel", {
          clientX: area[0] + area[1] / 2,
          clientY: innerHeight / 2,
          deltaX: dx,
          deltaY: 0,
          deltaMode: 0,
          bubbles: true,
          cancelable: true,
          composed: true,
        }),
      );
    };
    if (typeof requestAnimationFrame === "function") requestAnimationFrame(run);
    else run();
  };
  // ---- Sheet fields ----
  // The open sheet, or the open side panels in landscape.
  const openPanels = (): Element[] => {
    const sides: Panel[] = sidesOn() ? [...open] : [panel];
    return sides.flatMap((side) => {
      const el = side === "none" ? undefined : found.get(side);
      return el ? [el] : [];
    });
  };
  const panelOf = (el: Element) =>
    openPanels().find((p) => p === el || p.contains?.(el)) ?? null;
  const inSheet = (el: unknown): el is HTMLInputElement =>
    !!el && (el as Element).tagName === "INPUT" && !!panelOf(el as Element);
  const mark = (el: Element) => {
    if (marked.has(el)) return;
    marked.set(el, el.getAttribute("inputmode"));
    el.setAttribute("inputmode", "decimal");
  };
  const unmark = (el: Element) => {
    const prior = marked.get(el);
    marked.delete(el);
    if (prior === undefined) return;
    if (prior === null) el.removeAttribute("inputmode");
    else el.setAttribute("inputmode", prior);
  };
  const unmarkAll = () => {
    for (const el of [...marked.keys()]) unmark(el);
  };
  // Marks numeric inputs in the open sheet ahead of a tap, since WebKit picks the keyboard
  // when the field gains focus. A focused field keeps its mark while an expression is typed.
  const markFields = () => {
    const panels = openPanels();
    if (!numberKeyboard || !panels.length) {
      unmarkAll();
      return;
    }
    for (const el of [...marked.keys()])
      if (!el.isConnected || !panelOf(el)) unmark(el);
    for (const sheetEl of panels)
      for (const el of sheetEl.querySelectorAll("input")) {
        if (numericField(el as HTMLInputElement)) mark(el);
        else if (el !== field) unmark(el);
      }
  };
  const numericFocus = () => numberKeyboard && !!field && marked.has(field);
  const postField = () => {
    const payload = { numeric: enabled && numericFocus() };
    const text = JSON.stringify(payload);
    if (text === fieldPosted) return;
    fieldPosted = text;
    runtime.post("folioPhoneField", payload);
  };
  // Native's key row covers about 52 CSS px above the keyboard while a numeric field is focused.
  const rowAllowance = 52;
  // Scrolls the focused field into the visible part of the sheet at once, computed from the
  // sheet's final top and bottom.
  const reveal = () => {
    const sheetEl = field ? panelOf(field) : null;
    if (!enabled || !field || !sheetEl || !field.isConnected || !inSheet(field))
      return;
    // The field's own scroll container, up to the sheet itself (overflow:auto in Folio's CSS).
    let scroller: Element | null = null;
    for (let el = field.parentElement; el; el = el.parentElement) {
      const overflow = globalThis.getComputedStyle?.(el).overflowY ?? "";
      if (
        /(auto|scroll)/.test(overflow) &&
        el.scrollHeight > el.clientHeight + 1
      ) {
        scroller = el;
        break;
      }
      if (el === sheetEl) break;
    }
    if (!scroller) return;
    const now = sheetEl.getBoundingClientRect();
    // Side panels (landscape) keep their place; the web view itself ends at the keyboard.
    const viewport = globalThis.visualViewport;
    const top = sidesOn() ? now.top : sheetTop();
    const bottom = sidesOn()
      ? Math.min(
          innerHeight,
          viewport ? viewport.offsetTop + viewport.height : innerHeight,
        )
      : sheetBottom();
    const shift = top - now.top;
    const area = scroller.getBoundingClientRect();
    const box = field.getBoundingClientRect();
    const delta = revealDelta(
      { top: box.top + shift, bottom: box.bottom + shift },
      Math.max(top, area.top + shift),
      Math.min(
        bottom - (numericFocus() ? rowAllowance : 0),
        bottom - Math.max(0, now.bottom - area.bottom),
      ),
    );
    if (!delta) return;
    scroller.scrollTop += delta;
  };
  let revealTimer: ReturnType<typeof setTimeout> | undefined;
  const revealLater = () => {
    if (revealTimer !== undefined) clearTimeout(revealTimer);
    revealTimer = setTimeout(() => {
      revealTimer = undefined;
      reveal();
    }, 400);
  };
  const releaseField = () => {
    if (releaseTimer !== undefined) clearTimeout(releaseTimer);
    releaseTimer = undefined;
    field = null;
    postField();
  };
  const focusIn = (event: Event) => {
    const target = event.target;
    if (!enabled || !inSheet(target)) return;
    if (releaseTimer !== undefined) clearTimeout(releaseTimer);
    releaseTimer = undefined;
    if (numberKeyboard && numericField(target)) mark(target);
    field = target;
    postField();
    // With the keyboard already up (the next field), reveal now; otherwise native's
    // phoneKeyboard call places the sheet and reveals the field together.
    if (keyboard > 0) reveal();
    // Side panels: the web view shrinks for the keyboard; reveal once it has settled.
    else if (sidesOn()) revealLater();
  };
  // Moving to the next field keeps the field state; a real blur clears it.
  const focusOut = () => {
    if (!field) return;
    if (releaseTimer !== undefined) clearTimeout(releaseTimer);
    releaseTimer = setTimeout(() => {
      releaseTimer = undefined;
      if (!inSheet(document.activeElement)) releaseField();
    }, 300);
  };
  // Marks a numeric field before the tap focuses it, if the scan has not yet.
  const pointerDown = (event: Event) => {
    const target = event.target;
    if (enabled && numberKeyboard && inSheet(target) && numericField(target))
      mark(target);
  };
  const fieldEvents: [string, (event: Event) => void][] = [
    ["focusin", focusIn],
    ["focusout", focusOut],
    ["pointerdown", pointerDown],
    ["touchstart", pointerDown],
  ];
  runtime.phoneFieldKey = (key) => {
    const el = document.activeElement;
    if (!enabled || !numberKeyboard || el !== field || !inSheet(el))
      return false;
    const text =
      typeof key === "string" && Object.hasOwn(keyText, key)
        ? keyText[key]
        : undefined;
    if (key === "sign") toggleSign(el, document);
    else if (text) insertText(el, text, document);
    else return false;
    return true;
  };

  // Native, as the keyboard starts to move: its final overlap in CSS px and the minimum sheet
  // fraction while it is up (0 when down). Applied at once, in one style change.
  runtime.phoneKeyboard = (overlap, floor) => {
    const number = (n: unknown, max: number) =>
      typeof n === "number" && Number.isFinite(n)
        ? Math.min(max, Math.max(0, n))
        : 0;
    stopSheetDrag();
    keyboard = Math.round(number(overlap, innerHeight));
    raised = number(floor, 0.85);
    if (!enabled) return;
    css();
    if (field && keyboard > 0) reveal();
  };
  // Landscape and portrait carry the open panels over: a sheet becomes its side and back.
  const setSides = (wanted: boolean) => {
    const before = sidesOn();
    sidesWanted = wanted;
    if (before === sidesOn()) return;
    stopSheetDrag();
    if (sidesOn()) {
      open.clear();
      const shown = visiblePanel();
      if (shown !== "none") open.add(shown);
      panel = pending = "none";
    } else {
      panel = open.has("right") ? "right" : open.has("left") ? "left" : "none";
      open.clear();
    }
    releaseField();
    measurementDirty = true;
  };
  runtime.setPhoneLayout = (value, minimized, wideViewport, numbers, sides) => {
    if (typeof numbers === "boolean" && numbers !== numberKeyboard) {
      numberKeyboard = numbers;
      if (enabled) {
        markFields();
        postField();
      }
    }
    // Native seeds the tab's choice once per page; later the page's own state wins.
    if (!seeded && typeof minimized === "boolean") {
      minimize = minimized;
      seeded = true;
    }
    if (typeof wideViewport === "boolean" && wide !== wideViewport) {
      wide = wideViewport;
      measurementDirty = true;
      attempts = 0;
      lastAttempt = -Infinity;
    }
    if (typeof sides === "boolean") setSides(sides);
    if (value === enabled) {
      if (enabled) scan();
      return;
    }
    enabled = value;
    observer.disconnect();
    if (frame !== undefined) globalThis.cancelAnimationFrame?.(frame);
    frame = undefined;
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    if (settle !== undefined) clearTimeout(settle);
    settle = undefined;
    keyboard = raised = 0;
    layoutSize = `${innerWidth}x${innerHeight}`;
    attempts = 0;
    lastAttempt = -Infinity;
    globalThis.removeEventListener?.("resize", resized);
    globalThis.visualViewport?.removeEventListener("resize", resized);
    for (const [name, listener] of fieldEvents)
      document.removeEventListener?.(name, listener, true);
    if (enabled) {
      observer.observe(document, { childList: true, subtree: true });
      globalThis.addEventListener?.("resize", resized);
      globalThis.visualViewport?.addEventListener("resize", resized);
      for (const [name, listener] of fieldEvents)
        document.addEventListener?.(name, listener, {
          capture: true,
          passive: true,
        });
    }
    scan();
  };
  runtime.phoneSheetDrag = (phase, fraction) => {
    if (
      (phase !== "begin" && phase !== "move" && phase !== "end") ||
      typeof fraction !== "number" ||
      !Number.isFinite(fraction)
    )
      return false;
    if (!enabled || !eligible() || sidesOn() || panel === "none") {
      stopSheetDrag();
      return false;
    }
    const element = found.get(panel);
    if (
      !element ||
      !element.isConnected ||
      (sheetDrag && sheetDrag.element !== element)
    ) {
      stopSheetDrag();
      css();
      return false;
    }
    if (phase === "begin") {
      stopSheetDrag();
      sheetDrag = {
        element,
        top: sheetTop(),
        height: Math.max(1, Math.round(innerHeight * 0.85)),
      };
      css();
    }
    if (phase === "move" && !sheetDrag) return false;
    sheet = Math.min(0.85, Math.max(0.25, fraction));
    if (phase === "end") {
      stopSheetDrag();
      css();
      return true;
    }
    if (!sheetDrag) return false;
    // No DOM reads, Figma scan, top/height write or rAF queue on the move path.
    dragStyle.textContent = `[${attribute}="${panel}"]{transform:translate3d(0,${sheetTop() - sheetDrag.top}px,0)!important}`;
    const root = document.head ?? document.documentElement;
    if (root && dragStyle.parentNode !== root) root.appendChild(dragStyle);
    return true;
  };
  runtime.phonePanel = (side, fraction) => {
    // Explicit panel changes and refreshes end any old gesture before reapplying geometry.
    stopSheetDrag();
    if (typeof fraction === "number" && Number.isFinite(fraction)) {
      sheet = Math.min(0.85, Math.max(0.25, fraction));
    }
    if (!enabled || !eligible())
      return { state: "off", missing: false, tool: "none", mode: "unknown" };
    if (overlays().length > 0)
      return {
        state: state(),
        missing: false,
        tool: shownTool,
        mode: shownMode,
      };
    if (sidesOn() && (side === "left" || side === "right")) {
      // Independent sides: only the native frame changes (post reports the new overscan).
      scan();
      const before = overscan()[0];
      if (open.has(side)) open.delete(side);
      else if (has(side)) open.add(side);
      else
        return {
          state: state(),
          missing: true,
          tool: shownTool,
          mode: shownMode,
        };
      // The canvas's left edge moves on screen by the left overscan change; pan it back.
      pan += before - overscan()[0];
      panUntil = performance.now() + 1500;
      markFields();
      css();
      post();
    } else if (sidesOn() && side === "none") {
      open.clear();
      scan();
    } else if (side === "left" || side === "right" || side === "none") {
      scan();
      const target: Panel = side === visiblePanel() ? "none" : side;
      if (target === "none") {
        // Closing a wide-layout sheet is CSS only; the fallback minimizes again.
        panel = pending = "none";
        minimize = true;
        attempts = 0;
        lastAttempt = -Infinity;
        scan();
      } else if (has(target)) {
        panel = target;
        pending = "none";
      } else if (figma === "min") {
        panel = "none";
        pending = target;
        pendingUntil = performance.now() + 4000;
        attempts = 0;
        lastAttempt = -Infinity;
        toggle("expanded");
      } else
        return {
          state: state(),
          missing: true,
          tool: shownTool,
          mode: shownMode,
        };
      css();
      post();
    } else if (panel !== "none") css();
    return { state: state(), missing: false, tool: shownTool, mode: shownMode };
  };
  runtime.disposePhoneLayout = () => {
    runtime.setPhoneLayout?.(false);
    delete runtime.setPhoneLayout;
    delete runtime.phonePanel;
    delete runtime.phoneSheetDrag;
    delete runtime.phoneFieldKey;
    delete runtime.phoneKeyboard;
    delete runtime.disposePhoneLayout;
  };
}
