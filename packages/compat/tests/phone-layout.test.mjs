import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const scripts = await Promise.all(
  ["bridge", "phone-layout"].map((name) =>
    readFile(
      new URL(
        `../../../apps/ios/Folio/Resources/Compat/${name}.js`,
        import.meta.url,
      ),
      "utf8",
    ),
  ),
);

// Minimal DOM: compound selectors (tag, .class, [attr], [attr="v"], *=, ^=, $=) joined by
// descendant or child combinators, which is all phone-layout.ts queries with. Class names live
// in the "class" attribute.
const parse = (selector) => {
  const tag = /^[a-z]+/i.exec(selector)?.[0];
  const attrs = [
    ...selector.matchAll(/\[([\w-]+)(?:([*^$]?=)"([^"]*)")?\]/g),
  ].map(([, name, op, value]) => ({ name, op, value }));
  const classes = [
    ...selector.replace(/\[[^\]]*\]/g, "").matchAll(/\.([\w-]+)/g),
  ].map(([, name]) => name);
  return { tag, attrs, classes };
};
// Split on combinators outside brackets: ["a", ">", "b"] or ["a", " ", "b"].
const split = (selector) => {
  const parts = [];
  let current = "";
  let depth = 0;
  let combinator = null;
  for (const char of selector.trim()) {
    if (char === "[") depth += 1;
    if (char === "]") depth -= 1;
    if (depth === 0 && (char === " " || char === ">")) {
      if (current) parts.push(current);
      current = "";
      combinator = char === ">" || combinator === ">" ? ">" : " ";
      continue;
    }
    if (combinator && !current && parts.length) parts.push(combinator);
    combinator = null;
    current += char;
  }
  if (current) parts.push(current);
  return parts;
};
const matches = (el, selector) => {
  const parts = split(selector);
  if (!compound(el, parts.at(-1))) return false;
  let node = el;
  for (let i = parts.length - 2; i > 0; i -= 2) {
    const combinator = parts[i];
    const part = parts[i - 1];
    if (combinator === ">") {
      node = node.parentElement;
      if (!node || !compound(node, part)) return false;
    } else {
      do node = node.parentElement;
      while (node && !compound(node, part));
      if (!node) return false;
    }
  }
  return true;
};
const compound = (el, selector) => {
  const { tag, attrs, classes } = parse(selector);
  if (tag && el.tag !== tag) return false;
  const classList = (el.getAttribute("class") ?? "").split(/\s+/);
  if (!classes.every((name) => classList.includes(name))) return false;
  return attrs.every(({ name, op, value }) => {
    const actual = el.getAttribute(name);
    if (actual === null) return false;
    if (!op) return true;
    if (op === "=") return actual === value;
    if (op === "*=") return actual.includes(value);
    if (op === "^=") return actual.startsWith(value);
    return actual.endsWith(value);
  });
};
class El {
  constructor(tag, attrs = {}, rect = [0, 0, 0, 0], children = []) {
    this.tag = tag;
    this.attrs = { ...attrs };
    this.rect = rect;
    this.children = [];
    this.parentElement = null;
    this.parentNode = null;
    this.textContent = "";
    this.clicks = 0;
    this.style = {};
    for (const child of children) this.append(child);
  }
  get className() {
    return this.attrs.class ?? "";
  }
  get tagName() {
    return this.tag.toUpperCase();
  }
  contains(other) {
    for (let node = other; node; node = node.parentElement)
      if (node === this) return true;
    return false;
  }
  get isConnected() {
    let node = this;
    while (node.parentElement) node = node.parentElement;
    return node.root === true;
  }
  append(child) {
    child.parentElement = this;
    child.parentNode = this;
    this.children.push(child);
    return child;
  }
  appendChild(child) {
    child.parentNode = this;
  }
  remove() {
    if (this.parentElement) {
      const list = this.parentElement.children;
      list.splice(list.indexOf(this), 1);
    }
    this.parentElement = null;
    this.parentNode = null;
  }
  *descendants() {
    for (const child of this.children) {
      yield child;
      yield* child.descendants();
    }
  }
  querySelectorAll(selector) {
    return [...this.descendants()].filter((el) => matches(el, selector));
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] ?? null;
  }
  closest(selector) {
    for (let node = this; node; node = node.parentElement)
      if (matches(node, selector)) return node;
    return null;
  }
  getBoundingClientRect() {
    const [left, top, width, height] = this.rect;
    return {
      left,
      top,
      width,
      height,
      right: left + width,
      bottom: top + height,
    };
  }
  getAttribute(k) {
    return this.attrs[k] ?? null;
  }
  hasAttribute(k) {
    return k in this.attrs;
  }
  setAttribute(k, v) {
    this.attrs[k] = String(v);
  }
  removeAttribute(k) {
    delete this.attrs[k];
  }
  click() {
    this.clicks += 1;
    this.onclick?.();
  }
}

const designTools = [
  "Move",
  "Frame",
  "Rectangle",
  "Pen",
  "Text",
  "Comment",
  "Actions",
].map((id) => `${id}-tool`);

const toolButton = (name, pressed) =>
  new El("button", {
    "data-testid": `${name}-tool`,
    "aria-pressed": String(pressed),
    class: "toolbelt_button--topLevelButtonNew--rTT0F",
  });
// Shaped like the 2026-10-11 Web Inspector findings (portrait 402 × 694), no document content.
function figmaEditor({ expanded = true } = {}) {
  const body = new El("body");
  const hidden = new El(
    "div",
    { class: "toolbelt_left_side--hiddenCarouselRow--IHWwV" },
    [0, 0, 0, 0],
    [toolButton("Move", true), toolButton("Comment", false)],
  );
  const visible = new El(
    "div",
    { class: "toolbelt_left_side--visibleCarouselRow--5w3np" },
    [0, 640, 402, 36],
    ["Move", "Frame", "Rectangle", "Pen", "Text", "Comment", "Actions"].map(
      (name) => toolButton(name, name === "Move"),
    ),
  );
  visible.append(
    new El("button", {
      "data-testid": "SelectTools-chevron",
      "aria-pressed": "false",
    }),
  );
  const tools = body.append(
    new El(
      "div",
      {
        "data-testid": "positioned-design-toolbelt",
        class: "positioned_design_toolbelt--root--kfNki",
      },
      [0, 634, 402, 48],
      [hidden, visible],
    ),
  );
  const right = body.append(
    new El(
      "div",
      {
        "data-testid": "properties-panel",
        class: "properties_panel--drillDownContainer--sVtfc",
      },
      [161, 0, 241, 694],
      [
        new El("div"),
        new El(
          "div",
          { "data-testid": "propertiesPanelContainer.resizablePanel" },
          [0, 0, 8, 694],
        ),
      ],
    ),
  );
  const minimizeButton = new El("button", {
    "aria-label": "Minimize UI",
    class: "icon_button_32--iconButton---s-Jz",
  });
  const expandButton = new El("button", {
    "aria-label": "Expand UI for file named Example",
    class: "toggle_expanded_sidebar_button--button--0-Uff",
  });
  const editor = {
    body,
    tools,
    right,
    visible,
    minimizeButton,
    expandButton,
    rail: null,
    left: null,
    leftSize: null,
    expanded: false,
    expand() {
      if (editor.expanded) return;
      editor.expanded = true;
      expandButton.remove();
      editor.rail = body.append(
        new El(
          "nav",
          { "data-testid": "navigation-bar", class: "x5lhr3w" },
          [0, 0, 49, 694],
          [new El("div", { "data-testid": "navigation-bar-top-section" })],
        ),
      );
      editor.leftSize = new El(
        "div",
        { class: "left_panel_container--sizeContainer--Lqb7I" },
        [49, 0, 240, 694],
        [minimizeButton],
      );
      editor.left = body.append(
        new El(
          "div",
          { class: "left_panel_container--positionContainer--gHtFH" },
          [49, 0, 240, 694],
          [editor.leftSize],
        ),
      );
      right.setAttribute(
        "class",
        "properties_panel--drillDownContainer--sVtfc",
      );
    },
    minimize() {
      if (!editor.expanded) return;
      editor.expanded = false;
      editor.rail.remove();
      editor.left.remove();
      minimizeButton.remove();
      body.append(expandButton);
      right.setAttribute(
        "class",
        "properties_panel--drillDownContainer--sVtfc properties_panel--propertiesPanelCollapsed--fy4t5",
      );
    },
    press(name) {
      for (const button of visible.children)
        if (button.getAttribute("data-testid")?.endsWith("-tool"))
          button.setAttribute(
            "aria-pressed",
            String(button.getAttribute("data-testid") === `${name}-tool`),
          );
    },
  };
  minimizeButton.onclick = () => editor.minimize();
  expandButton.onclick = () => editor.expand();
  // Start minimized, then expand, so the DOM matches Figma's expanded order.
  body.append(expandButton);
  right.setAttribute(
    "class",
    "properties_panel--drillDownContainer--sVtfc properties_panel--propertiesPanelCollapsed--fy4t5",
  );
  if (expanded) editor.expand();
  return editor;
}

function harness(editor, pathname = "/design/abc/File") {
  const root = new El("html");
  root.root = true;
  const head = root.append(new El("head"));
  root.append(editor.body);
  const style = new El("style");
  const styles = [style];
  let styleCreated = false;
  const messages = [];
  let now = 0;
  let nextTimer = 0;
  const timers = new Map();
  const observers = [];
  const listeners = new Map();
  const documentListeners = new Map();
  const commands = [];
  const context = vm.createContext({
    innerWidth: 402,
    innerHeight: 694,
    performance: { now: () => now },
    location: {
      protocol: "https:",
      port: "",
      hostname: "www.figma.com",
      pathname,
    },
    document: {
      head,
      documentElement: root,
      createElement: () => {
        if (!styleCreated) {
          styleCreated = true;
          return style;
        }
        const extra = new El("style");
        styles.push(extra);
        return extra;
      },
      querySelector: (s) => root.querySelector(s),
      querySelectorAll: (s) => root.querySelectorAll(s),
      activeElement: null,
      addEventListener: (name, callback) =>
        documentListeners.set(name, callback),
      removeEventListener: (name) => documentListeners.delete(name),
      execCommand: (...args) => {
        commands.push(args);
        return true;
      },
    },
    getComputedStyle: (el) => ({
      overflowY: el.className.includes("scroll") ? "auto" : "visible",
    }),
    webkit: {
      messageHandlers: {
        folio: {
          postMessage: (m) => messages.push(JSON.parse(JSON.stringify(m))),
        },
      },
    },
    setTimeout: (callback, delay) => {
      const id = ++nextTimer;
      timers.set(id, { callback, at: now + delay });
      return id;
    },
    requestAnimationFrame: (callback) => {
      const id = ++nextTimer;
      timers.set(id, { callback, at: now + 16 });
      return id;
    },
    cancelAnimationFrame: (id) => timers.delete(id),
    clearTimeout: (id) => timers.delete(id),
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: (name) => listeners.delete(name),
    MutationObserver: class {
      constructor(callback) {
        this.callback = callback;
        this.target = null;
        observers.push(this);
      }
      observe(target) {
        this.target = target;
      }
      disconnect() {
        this.target = null;
      }
    },
  });
  for (const script of scripts) vm.runInContext(script, context);
  const advance = (ms) => {
    const end = now + ms;
    while (true) {
      const next = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
      if (!next || next[1].at > end) break;
      now = next[1].at;
      timers.delete(next[0]);
      next[1].callback();
    }
    now = end;
  };
  return {
    runtime: context.__folio,
    style,
    styles,
    context,
    timers,
    observers,
    advance,
    // A DOM change seen by every connected observer.
    mutate() {
      for (const observer of observers)
        if (observer.target) observer.callback([]);
    },
    // Native resized the web view.
    resize(width) {
      context.innerWidth = width;
      listeners.get("resize")?.();
    },
    last: () =>
      messages.filter((m) => m.name === "folioPhoneState").at(-1)?.payload,
    field: () =>
      messages.filter((m) => m.name === "folioPhoneField").at(-1)?.payload,
    // A standard DOM event on the document (focusin, focusout, pointerdown).
    dispatch: (name, target) => documentListeners.get(name)?.({ target }),
    documentListeners,
    commands,
    messages,
  };
}
const marker = (el) => el?.getAttribute("data-folio-phone") ?? null;

test("canvas first: minimizes Figma once, hides the rail and tool bar, reports Move", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  assert.equal(editor.minimizeButton.clicks, 1);
  assert.equal(editor.expanded, false);
  h.advance(300);
  assert.equal(editor.minimizeButton.clicks, 1);
  assert.equal(marker(editor.tools), "tools");
  assert.match(
    h.style.textContent,
    /"tools"\],\[data-folio-phone="tools"\] \*\{visibility:hidden/,
  );
  assert.match(h.style.textContent, /"rail"\]\{display:none/);
  assert.doesNotMatch(h.style.textContent, /position:fixed/);
  assert.deepEqual(
    { ...h.last() },
    {
      panel: "none",
      tool: "move",
      mode: "design",
      visibleTools: designTools,
      minimize: true,
      overlay: false,
      left: 0,
      right: 0,
      panelLeft: 0,
      panelRight: 0,
    },
  );
  assert.equal(h.runtime.phonePanel().state, "none");
});

test("active tool follows the visible row only and stays within the fixed ids", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  editor.press("Rectangle");
  h.mutate();
  h.advance(300);
  assert.equal(h.last().tool, "rectangle");
  editor.press("Actions");
  h.mutate();
  // A blank report waits out the 500 ms hold.
  h.advance(800);
  assert.equal(h.last().tool, "none");
  editor.press("Nope");
  editor.visible.children[0].setAttribute("data-testid", "constructor-tool");
  editor.visible.children[0].setAttribute("aria-pressed", "true");
  h.mutate();
  // A blank report waits out the 500 ms hold.
  h.advance(800);
  assert.equal(h.last().tool, "none");
});

test("Layers expands Figma natively, shows a full-width sheet, and closing minimizes again", () => {
  const editor = figmaEditor({ expanded: false });
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  assert.equal(editor.expandButton.clicks, 0);
  const opened = h.runtime.phonePanel("left", 0.4);
  assert.deepEqual(
    { ...opened },
    { state: "left", missing: false, tool: "move", mode: "design" },
  );
  assert.equal(editor.expandButton.clicks, 1);
  h.advance(300);
  assert.equal(marker(editor.left), "left");
  assert.equal(marker(editor.leftSize), "leftSize");
  assert.equal(marker(editor.rail), "rail");
  assert.match(h.style.textContent, /"left"\]\{position:fixed/);
  assert.match(
    h.style.textContent,
    /top:416px!important;bottom:0!important;height:auto/,
  );
  assert.match(h.style.textContent, /"leftSize"\]\{width:100%/);
  assert.match(h.style.textContent, /"right"\]\{display:none/);
  assert.equal(editor.minimizeButton.clicks, 0);
  assert.equal(h.last().panel, "left");

  assert.equal(h.runtime.phonePanel("right").state, "right");
  assert.match(h.style.textContent, /"right"\]\{position:fixed/);
  assert.match(h.style.textContent, /resizablePanel"\]\{display:none/);

  assert.equal(h.runtime.phonePanel("right").state, "none");
  assert.equal(editor.minimizeButton.clicks, 1);
  assert.equal(editor.expanded, false);
  h.advance(300);
  assert.deepEqual(
    { ...h.last() },
    {
      panel: "none",
      tool: "move",
      mode: "design",
      visibleTools: designTools,
      minimize: true,
      overlay: false,
      left: 0,
      right: 0,
      panelLeft: 0,
      panelRight: 0,
    },
  );
});

test("a user who expands through Figma is not fought: Layers sheet, no re-minimize", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  h.advance(5000);
  editor.expand();
  h.mutate();
  h.advance(300);
  assert.equal(editor.minimizeButton.clicks, 1);
  assert.deepEqual(
    { ...h.last() },
    {
      panel: "left",
      tool: "move",
      mode: "design",
      visibleTools: designTools,
      minimize: false,
      overlay: false,
      left: 0,
      right: 0,
      panelLeft: 0,
      panelRight: 0,
    },
  );
  h.advance(10000);
  assert.equal(editor.minimizeButton.clicks, 1);
  // Figma's own Minimize inside the sheet hands the choice back to Folio.
  editor.minimize();
  h.mutate();
  h.advance(300);
  assert.deepEqual(
    { ...h.last() },
    {
      panel: "none",
      tool: "move",
      mode: "design",
      visibleTools: designTools,
      minimize: true,
      overlay: false,
      left: 0,
      right: 0,
      panelLeft: 0,
      panelRight: 0,
    },
  );
});

test("native seed false keeps Figma expanded after reload and shows Layers", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, false);
  // Later calls with a stale native flag do not override the page's state.
  h.runtime.setPhoneLayout(true, true);
  assert.equal(editor.minimizeButton.clicks, 0);
  assert.equal(h.last().panel, "left");
});

test("minimize attempts are bounded when Figma ignores the click", () => {
  const editor = figmaEditor();
  editor.minimizeButton.onclick = undefined;
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  for (let i = 0; i < 20; i++) {
    h.mutate();
    h.advance(1000);
  }
  assert.equal(editor.minimizeButton.clicks, 5);
});

test("Figma's chord is the fallback when its Minimize button is not found", () => {
  const editor = figmaEditor();
  editor.minimizeButton.remove();
  const h = harness(editor);
  let chords = 0;
  h.runtime.minimizePhoneUI = () => (chords += 1);
  h.runtime.setPhoneLayout(true, true);
  assert.equal(chords, 1);
});

test("missing panels report missing; Home and off restore everything", () => {
  const home = harness(figmaEditor(), "/files/recents");
  home.runtime.setPhoneLayout(true, true);
  assert.equal(home.runtime.phonePanel("left").state, "off");

  const editor = figmaEditor();
  editor.minimizeButton.remove();
  editor.expandButton.remove();
  editor.rail.remove();
  editor.left.remove();
  editor.right.setAttribute(
    "class",
    "properties_panel--drillDownContainer--sVtfc properties_panel--propertiesPanelCollapsed--fy4t5",
  );
  editor.right.setAttribute("data-testid", "other");
  editor.right.setAttribute("class", "other");
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  assert.equal(h.runtime.phonePanel("left").missing, true);
  h.runtime.setPhoneLayout(false);
  assert.equal(marker(editor.tools), null);
  assert.equal(h.style.parentNode, null);
  assert.equal(h.runtime.phonePanel().state, "off");
  assert.equal(h.last().panel, "off");
});

test("an expand that never mounts the panel gives up and minimizes again", () => {
  const editor = figmaEditor({ expanded: false });
  editor.expandButton.onclick = () => {
    editor.expand();
    editor.left.remove();
    editor.body.append(editor.minimizeButton);
  };
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  assert.equal(h.runtime.phonePanel("left").state, "left");
  h.advance(5000);
  assert.equal(h.last().panel, "none");
  assert.equal(editor.minimizeButton.clicks, 1);
});

for (const dispose of [false, true]) {
  test(`observers and timers stop on ${dispose ? "disposal" : "disable"}`, () => {
    const editor = figmaEditor();
    const h = harness(editor);
    h.runtime.setPhoneLayout(true, true);
    h.mutate();
    assert.ok(h.timers.size > 0);
    if (dispose) h.runtime.disposePhoneLayout();
    else h.runtime.setPhoneLayout(false);
    assert.equal(h.timers.size, 0);
    assert.ok(h.observers.every((observer) => observer.target === null));
    assert.equal(h.style.parentNode, null);
    assert.equal(marker(editor.tools), null);
  });
}

test("another file in the same page starts fresh rather than as a user choice", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  h.advance(5000);
  h.context.location.pathname = "/design/def/Other";
  editor.expand();
  h.mutate();
  h.advance(300);
  assert.equal(h.last().minimize, true);
  assert.equal(editor.minimizeButton.clicks, 2);
});

// Canvas chain as measured on the iPhone: the third ancestor holds left 290 px, the fourth
// right 241 px, and the canvas has width 0 in portrait.
function withCanvas(editor) {
  const canvas = new El("canvas", {}, [290, 0, 0, 694]);
  const gpu = new El(
    "div",
    { class: "gpu-view-content" },
    [290, 0, 0, 694],
    [canvas],
  );
  const third = new El(
    "div",
    { class: "view container-view" },
    [290, 0, 0, 694],
    [new El("div", { class: "view" }, [290, 0, 0, 694], [gpu])],
  );
  third.style = { left: "290px" };
  const fourth = new El(
    "div",
    { class: "view container-view" },
    [0, 0, 161, 694],
    [third],
  );
  fourth.style = { right: "241px" };
  editor.body.append(
    new El(
      "div",
      { class: "fullscreen_view--page--x" },
      [0, 0, 402, 694],
      [fourth],
    ),
  );
  return canvas;
}

test("canvas beside panels: reports the reservation and lays the sheet over the visible region", () => {
  const editor = figmaEditor({ expanded: false });
  const canvas = withCanvas(editor);
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, true);
  // Widen during editor setup, before any sheet opens.
  h.advance(300);
  assert.equal(h.last().left, 290);
  h.runtime.phonePanel("left", 0.5);
  h.mutate();
  h.advance(300);
  assert.deepEqual(
    { ...h.last() },
    {
      panel: "left",
      tool: "move",
      mode: "design",
      visibleTools: designTools,
      minimize: true,
      overlay: false,
      left: 290,
      right: 241,
      panelLeft: 0,
      panelRight: 0,
    },
  );
  // Not widened yet: the sheet is full width.
  assert.match(
    h.style.textContent,
    /"left"\]\{position:fixed!important;left:0/,
  );
  // Native widens the view to 402 + 290 + 241; Figma's canvas now has real width.
  canvas.rect = [290, 0, 402, 694];
  h.resize(933);
  h.advance(700);
  assert.equal(h.last().left, 290);
  assert.equal(h.last().right, 241);
  assert.match(
    h.style.textContent,
    /"left"\]\{position:fixed!important;left:290px!important;right:auto!important;width:402px/,
  );
  // A menu centred on the wide window is moved back into the visible region.
  const menu = editor.body.append(
    new El("div", { role: "menu" }, [600, 100, 200, 300]),
  );
  h.mutate();
  h.advance(300);
  assert.equal(menu.getAttribute("data-folio-shift"), "1");
  assert.match(
    h.style.textContent,
    /\[data-folio-shift="1"\]\{translate:-209px 97px/,
  );
  // Closing the sheet is CSS only: no native frame or Figma minimize transition.
  menu.remove();
  h.mutate();
  h.advance(300);
  h.runtime.phonePanel("left");
  h.advance(300);
  assert.deepEqual(
    { ...h.last() },
    {
      panel: "none",
      tool: "move",
      mode: "design",
      visibleTools: designTools,
      minimize: true,
      overlay: false,
      left: 290,
      right: 241,
      panelLeft: 0,
      panelRight: 0,
    },
  );
  assert.equal(editor.minimizeButton.clicks, 0);
  assert.equal(menu.getAttribute("data-folio-shift"), null);
});

test("landscape side panels: each side opens on its own and only the native overscan changes", () => {
  const editor = figmaEditor();
  const canvas = withCanvas(editor);
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, true, false, true);
  h.resize(750 + 290 + 241);
  canvas.rect = [290, 0, 750, 330];
  h.advance(1000);
  // Both closed: the whole reservation is off-screen, no panel is hidden or restyled.
  assert.equal(h.last().panel, "none");
  assert.equal(h.last().left, 290);
  assert.equal(h.last().right, 241);
  assert.doesNotMatch(h.style.textContent, /"left"\]\{display:none/);
  assert.doesNotMatch(h.style.textContent, /position:fixed/);
  const css = h.style.textContent;
  // Layers: only the rail stays off-screen, the panel keeps Figma's place and width.
  assert.equal(h.runtime.phonePanel("left").state, "left");
  assert.equal(h.last().left, 49);
  assert.equal(h.last().right, 241);
  // Properties joins it independently; the right side comes fully on-screen.
  assert.equal(h.runtime.phonePanel("right").state, "both");
  assert.deepEqual([h.last().left, h.last().right], [49, 0]);
  assert.equal(h.runtime.phonePanel("left").state, "right");
  assert.deepEqual([h.last().left, h.last().right], [290, 0]);
  assert.equal(h.runtime.phonePanel("right").state, "none");
  assert.deepEqual([h.last().left, h.last().right], [290, 241]);
  // Toggles never restyle panels, minimize Figma or re-measure.
  assert.equal(h.style.textContent, css);
  assert.equal(editor.minimizeButton.clicks, 0);
  assert.equal(editor.expanded, true);
  // Back to portrait: an open side becomes the sheet.
  h.runtime.phonePanel("right");
  h.runtime.setPhoneLayout(true, true, true, false, false);
  h.advance(300);
  assert.equal(h.last().panel, "right");
  assert.deepEqual([h.last().left, h.last().right], [290, 241]);
  assert.match(h.style.textContent, /"left"\]\{display:none/);
  // And landscape again: the sheet becomes its side.
  h.runtime.setPhoneLayout(true, true, true, false, true);
  h.advance(300);
  assert.equal(h.last().panel, "right");
  assert.deepEqual([h.last().left, h.last().right], [290, 0]);
});

test("landscape side panels: the canvas content stays put when Layers opens or closes", () => {
  const editor = figmaEditor();
  const canvas = withCanvas(editor);
  const wheels = [];
  canvas.dispatchEvent = (event) => wheels.push(event);
  const h = harness(editor);
  h.context.WheelEvent = class {
    constructor(type, init) {
      Object.assign(this, init, { type });
    }
  };
  h.runtime.setPhoneLayout(true, true, true, false, true);
  h.resize(750 + 290 + 241);
  canvas.rect = [290, 0, 750, 330];
  h.advance(1000);
  assert.equal(wheels.length, 0);
  // Native applies the reported overscan: the web view width is visible width + overscan.
  const apply = () => h.resize(750 + h.last().left + h.last().right);
  // Layers opens: the canvas's left edge moves right by the panel's measured width (290 − 49);
  // once the web view has its new width, one wheel pans the content back by exactly that.
  h.runtime.phonePanel("left");
  assert.equal(wheels.length, 0);
  apply();
  h.advance(20);
  assert.equal(wheels.length, 1);
  assert.equal(wheels[0].type, "wheel");
  assert.deepEqual(
    [
      wheels[0].deltaX,
      wheels[0].deltaY,
      wheels[0].deltaMode,
      wheels[0].ctrlKey,
    ],
    [241, 0, 0, undefined],
  );
  // Over the visible canvas, between the open panel and the right edge.
  assert.ok(wheels[0].clientX > 290 && wheels[0].clientX < 290 + 750);
  // Properties on the right moves no canvas edge: no wheel, in either order.
  h.runtime.phonePanel("right");
  apply();
  h.advance(20);
  assert.equal(wheels.length, 1);
  // Layers closes with Properties open: the reverse pan.
  h.runtime.phonePanel("left");
  apply();
  h.advance(20);
  assert.equal(wheels.length, 2);
  assert.equal(wheels[1].deltaX, -241);
  h.runtime.phonePanel("right");
  apply();
  h.advance(20);
  assert.equal(wheels.length, 2);
  // Open and close before native resizes: the moves cancel out, nothing is sent.
  h.runtime.phonePanel("left");
  h.runtime.phonePanel("left");
  apply();
  h.advance(20);
  assert.equal(wheels.length, 2);
  // A resize that never comes does not leave a stale pan for a later rotation.
  h.runtime.phonePanel("left");
  h.advance(2000);
  apply();
  h.advance(20);
  assert.equal(wheels.length, 2);
  // Open side panels are reported for centring native's tool pill between them.
  assert.deepEqual([h.last().panelLeft, h.last().panelRight], [241, 0]);
  h.runtime.phonePanel("right");
  assert.deepEqual([h.last().panelLeft, h.last().panelRight], [241, 241]);
});

test("selecting on the canvas never blinks the pill: tooltips, badges and brief remounts are held", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, true);
  withCanvas(editor);
  h.mutate();
  h.advance(1000);
  const steady = JSON.stringify(h.last());
  const count = h.messages.length;
  // Selection: a size badge (tooltip role) and other DOM appear; Figma remounts its tool bar
  // row for a moment, so the active tool, mode and tool list read blank.
  const badge = editor.body.append(
    new El("div", { role: "tooltip" }, [300, 200, 60, 20]),
  );
  const row = editor.visible;
  row.remove();
  h.mutate();
  h.advance(300);
  editor.tools.append(row);
  h.mutate();
  h.advance(300);
  // A menu that flashes for one frame is not a popover either.
  const flash = editor.body.append(
    new El("div", { role: "menu" }, [100, 100, 200, 200]),
  );
  h.mutate();
  h.advance(60);
  flash.remove();
  h.mutate();
  h.advance(1000);
  badge.remove();
  h.mutate();
  h.advance(1000);
  assert.equal(JSON.stringify(h.last()), steady);
  assert.equal(h.messages.length, count);
  // A real popover still hides the pill, after a short hold, and releases it when closed.
  const menu = editor.body.append(
    new El("div", { role: "menu" }, [100, 100, 200, 200]),
  );
  h.mutate();
  h.advance(600);
  assert.equal(h.last().overlay, true);
  menu.remove();
  h.mutate();
  h.advance(800);
  assert.equal(h.last().overlay, false);
});

test("landscape side panels need the wide layout; without it landscape keeps the sheet", () => {
  const editor = figmaEditor();
  withCanvas(editor);
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, false, false, true);
  h.runtime.phonePanel("left", 0.5);
  h.runtime.phonePanel("right", 0.5);
  h.advance(300);
  assert.equal(h.last().panel, "right");
  assert.equal(h.last().left, 0);
});

test("canvas beside panels off: no reservation is reported", () => {
  const editor = figmaEditor({ expanded: false });
  withCanvas(editor);
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, false);
  h.runtime.phonePanel("left", 0.5);
  h.mutate();
  h.advance(300);
  assert.equal(h.last().panel, "left");
  assert.equal(h.last().left, 0);
  assert.equal(h.last().right, 0);
});

test("overlay insertion never measures or updates native overscan, even with changed canvas geometry", () => {
  const editor = figmaEditor();
  const canvas = withCanvas(editor);
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, true);
  h.resize(933);
  canvas.rect = [290, 0, 402, 694];
  h.advance(1000);
  h.runtime.phonePanel("right");
  let count = h.messages.length;
  const picker = editor.body.append(
    new El("div", { role: "dialog" }, [10, 100, 240, 400]),
  );
  let reads = 0;
  canvas.getBoundingClientRect = () => {
    reads++;
    throw new Error("overlay insertion measured canvas");
  };
  h.observers[0].callback([{ type: "childList", addedNodes: [picker] }]);
  h.advance(1000);
  assert.equal(reads, 0);
  // Only the fixed overlay flag changes, so native can hide the grab bar.
  assert.equal(h.messages.length, count + 1);
  assert.equal(h.last().overlay, true);
  count = h.messages.length;
  assert.equal(editor.minimizeButton.clicks, 0);
  assert.match(h.style.textContent, /translate:361px 47px/);
  // Even a renderer/resize notification cannot change the frame while a dialog is open.
  canvas.parentElement.parentElement.parentElement.style.left = "310px";
  h.mutate();
  h.resize(933);
  h.advance(1000);
  assert.equal(h.messages.length, count);
  assert.equal(h.last().left, 290);
  assert.equal(h.runtime.phonePanel("right").state, "right");
  assert.equal(editor.minimizeButton.clicks, 0);
  assert.equal(h.last().overlay, true);
});

test("identical and sub-pixel reservation measurements send no native update", () => {
  const editor = figmaEditor();
  const canvas = withCanvas(editor);
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, true);
  h.resize(933);
  canvas.rect = [290, 0, 402, 694];
  h.advance(1000);
  const count = h.messages.length;
  for (const left of ["290px", "290.2px", "289.8px", "290.6px", "290px"]) {
    canvas.parentElement.parentElement.parentElement.style.left = left;
    h.mutate();
    h.advance(1000);
  }
  assert.equal(h.messages.length, count);
  assert.equal(h.last().left, 290);
});

test("sheet open, switch and close retain the renderer and its native reservation", () => {
  const editor = figmaEditor();
  const canvas = withCanvas(editor);
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, true);
  h.resize(933);
  canvas.rect = [290, 0, 402, 694];
  h.advance(1000);
  for (const side of ["left", "right", "right", "left", "left"]) {
    h.runtime.phonePanel(side);
    h.advance(1000);
    assert.equal(h.last().left, 290);
    assert.equal(h.last().right, 241);
    assert.equal(editor.expanded, true);
    assert.equal(editor.minimizeButton.clicks, 0);
  }
});

test("dialog centring stays fixed across mutations and follows keyboard-visible bounds", () => {
  const editor = figmaEditor();
  withCanvas(editor);
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, true);
  h.resize(933);
  h.advance(1000);
  const picker = editor.body.append(
    new El("div", { role: "dialog" }, [10, 100, 240, 400]),
  );
  h.mutate();
  h.advance(16);
  assert.match(h.style.textContent, /translate:361px 47px/);
  // Model the actual DOM rect including the CSS translation.
  picker.rect = [371, 147, 240, 400];
  h.mutate();
  h.advance(1000);
  assert.match(h.style.textContent, /translate:361px 47px/);
  h.context.visualViewport = {
    height: 300,
    width: 933,
    offsetLeft: 0,
    offsetTop: 0,
  };
  h.resize(933);
  h.advance(1000);
  assert.match(h.style.textContent, /translate:361px -92px/);
  assert.match(h.style.textContent, /max-height:284px!important;overflow:auto/);
});

test("captured mode radios decide by checked property, ignoring unrelated controls", () => {
  const editor = figmaEditor();
  const segment = editor.tools.append(
    new El("fieldset", {
      "data-testid": "toolbelt-mode-segmented-control",
    }),
  );
  const design = segment.append(
    new El("input", {
      "data-testid": "toolbelt-mode-option-design",
      type: "radio",
    }),
  );
  const dev = segment.append(
    new El("input", {
      "data-testid": "toolbelt-mode-option-handoff",
      type: "radio",
    }),
  );
  design.checked = true;
  dev.checked = false;
  editor.body.append(
    new El("button", {
      "data-testid": "dev-mode-toggle",
      "aria-pressed": "true",
    }),
  );
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  assert.equal(h.last().mode, "design");
  design.checked = false;
  dev.checked = true;
  h.mutate();
  h.advance(300);
  assert.equal(h.last().mode, "dev");
  assert.equal(h.runtime.phonePanel().mode, "dev");
  design.checked = true;
  h.mutate();
  // A blank report waits out the 500 ms hold.
  h.advance(800);
  assert.equal(h.last().mode, "unknown");
  design.checked = dev.checked = false;
  h.mutate();
  // A blank report waits out the 500 ms hold.
  h.advance(800);
  assert.equal(h.last().mode, "unknown");
});

test("Dev Mode: without a stated control, the visible tool row decides", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  assert.equal(h.last().mode, "design");
  // A control without any state is ignored.
  editor.tools.append(new El("button", { "data-testid": "dev-mode-toggle" }));
  for (const button of [...editor.visible.children])
    if (
      /^(Frame|Rectangle|Pen|Text)-tool$/.test(
        button.getAttribute("data-testid") ?? "",
      )
    )
      button.remove();
  editor.visible.append(toolButton("Measurement", false));
  editor.visible.append(toolButton("Annotation", false));
  h.mutate();
  h.advance(300);
  assert.equal(h.last().mode, "dev");
  // Dev tools in a hidden carousel row say nothing.
  for (const button of [...editor.visible.children])
    if (
      /^(Measurement|Annotation)-tool$/.test(
        button.getAttribute("data-testid") ?? "",
      )
    )
      button.remove();
  editor.tools.children[0].append(toolButton("Measurement", false));
  h.mutate();
  // A blank report waits out the 500 ms hold.
  h.advance(800);
  assert.equal(h.last().mode, "unknown");
  h.runtime.setPhoneLayout(false);
  assert.equal(h.last().mode, "unknown");
});

test("sheet fields: numeric inputs get a number keyboard, focus reveals, keys type, blur restores", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, false, true);
  h.runtime.phonePanel("right", 0.5);
  h.advance(300);
  const input = (attrs, value, rect) => {
    const el = new El("input", attrs, rect);
    el.value = value;
    return el;
  };
  const scroller = editor.right.append(
    new El("div", { class: "properties_panel--scroll" }, [0, 150, 402, 544]),
  );
  scroller.scrollHeight = 1000;
  scroller.clientHeight = 300;
  scroller.scrollTop = 0;
  const x = scroller.append(
    input({ class: "raw_components--textInput" }, "-820", [20, 600, 180, 28]),
  );
  const hex = scroller.append(input({}, "000000", [20, 640, 180, 28]));
  const name = scroller.append(
    input({ "aria-label": "Layer name" }, "12", [20, 680, 180, 28]),
  );
  const angle = scroller.append(input({}, "-90°", [20, 720, 180, 28]));
  h.mutate();
  h.advance(300);
  assert.equal(x.getAttribute("inputmode"), "decimal");
  assert.equal(angle.getAttribute("inputmode"), "decimal");
  assert.equal(hex.getAttribute("inputmode"), null);
  assert.equal(name.getAttribute("inputmode"), null);
  // A field outside the sheet (the canvas text editor) is never touched.
  const outside = editor.body.append(input({}, "5", [0, 0, 10, 10]));
  h.dispatch("pointerdown", outside);
  h.dispatch("focusin", outside);
  assert.equal(outside.getAttribute("inputmode"), null);
  assert.equal(h.field(), undefined);

  h.context.document.activeElement = x;
  h.dispatch("focusin", x);
  assert.deepEqual({ ...h.field() }, { numeric: true });
  // Focus alone moves nothing: the sheet waits for native's keyboard call.
  h.advance(1000);
  assert.equal(scroller.scrollTop, 0);
  assert.match(
    h.style.textContent,
    /top:347px!important;bottom:0!important;height:auto!important;/,
  );
  // Native, as the keyboard starts to move: 334 px overlap, sheet floor 0.85. The sheet jumps
  // to its final place without a transition, top-anchored in px at the same height native
  // puts the grab bar (694 × 0.15 = 104), its height ending on the keyboard (694 − 334 − 104),
  // and the field is scrolled in the same call (visible bottom 360 − 52 for the key row).
  h.runtime.phoneKeyboard(334, 0.85);
  assert.match(
    h.style.textContent,
    /top:104px!important;bottom:auto!important;height:256px!important;transition:none!important/,
  );
  assert.equal(scroller.scrollTop, 441);
  // The panel's colour bleeds from the sheet down behind the keyboard: a shadow offset and
  // spread by the overlap (top 104 to 694 + 334), the sheet's own box unchanged.
  assert.match(
    h.style.textContent,
    /box-shadow:0 -1px 0 rgba\(0,0,0,\.25\),0 334px 0 334px var\(--color-bg,#2c2c2c\)!important/,
  );
  // A dropdown the focused field opens stays anchored to it, even past the visible area; a
  // modal dialog is still centred.
  const list = editor.body.append(
    new El("div", { role: "listbox" }, [20, 330, 240, 300]),
  );
  h.mutate();
  h.advance(16);
  assert.equal(list.getAttribute("data-folio-shift"), null);
  const modal = editor.body.append(
    new El("div", { "aria-modal": "true" }, [20, 600, 240, 300]),
  );
  h.mutate();
  h.advance(16);
  assert.notEqual(modal.getAttribute("data-folio-shift"), null);
  modal.remove?.();
  list.remove?.();
  // Keyboard-only viewport changes never re-measure or re-run anything.
  h.context.visualViewport = {
    height: 360,
    width: 402,
    offsetLeft: 0,
    offsetTop: 0,
  };
  h.resize(402);
  h.advance(1000);
  assert.equal(scroller.scrollTop, 441);
  assert.match(
    h.style.textContent,
    /top:104px!important;bottom:auto!important;height:256px/,
  );
  assert.deepEqual({ ...h.field() }, { numeric: true });

  assert.equal(h.runtime.phoneFieldKey("minus"), true);
  assert.equal(h.runtime.phoneFieldKey("times"), true);
  assert.equal(h.runtime.phoneFieldKey("alert(1)"), false);
  assert.deepEqual(
    h.commands.map((c) => [...c]),
    [
      ["insertText", false, "-"],
      ["insertText", false, "*"],
    ],
  );

  // The next field, with the keyboard up, is revealed at once and keeps the field state.
  h.dispatch("focusout", x);
  h.context.document.activeElement = angle;
  h.dispatch("focusin", angle);
  assert.equal(scroller.scrollTop, 441 + 561);
  h.advance(300);
  assert.deepEqual({ ...h.field() }, { numeric: true });
  // A real blur: native puts the sheet back at once as the keyboard starts to hide.
  h.dispatch("focusout", angle);
  h.context.document.activeElement = null;
  h.runtime.phoneKeyboard(0, 0);
  assert.match(
    h.style.textContent,
    /top:347px!important;bottom:0!important;height:auto!important;/,
  );
  assert.doesNotMatch(h.style.textContent, /334px 0 334px/);
  h.advance(300);
  assert.deepEqual({ ...h.field() }, { numeric: false });
  // Bad values are clamped or ignored.
  h.runtime.phoneKeyboard("x", 5);
  assert.match(
    h.style.textContent,
    /top:104px!important;bottom:0!important;height:auto/,
  );
  h.runtime.phoneKeyboard(0, 0);
  assert.equal(h.runtime.phoneFieldKey("minus"), false);

  h.runtime.setPhoneLayout(true, true, false, false);
  assert.equal(x.getAttribute("inputmode"), null);
  delete h.context.visualViewport;
  h.runtime.setPhoneLayout(false);
  assert.equal(h.documentListeners.size, 0);
});

test("sheet fields: the switch off leaves inputs alone but still reveals focus", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, false, false);
  h.runtime.phonePanel("right", 0.5);
  h.advance(300);
  const x = editor.right.append(new El("input", {}, [20, 300, 180, 28]));
  x.value = "10";
  h.mutate();
  h.advance(300);
  h.context.document.activeElement = x;
  h.dispatch("focusin", x);
  assert.equal(x.getAttribute("inputmode"), null);
  assert.deepEqual({ ...h.field() }, { numeric: false });
  assert.equal(h.runtime.phoneFieldKey("minus"), false);
});

// Loading UI has neither the editor canvas nor its tool belt. Its own centre must
// stay in the native visible region, even when an SPA leaves cached reservations.
test("loading and editor remounts never reuse overscan before the editor exists", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, true);
  h.advance(300);
  assert.deepEqual([h.last().left, h.last().right], [0, 0]);
  const canvas = withCanvas(editor);
  h.mutate();
  h.advance(300);
  assert.deepEqual([h.last().left, h.last().right], [290, 241]);
  canvas.remove();
  h.mutate();
  h.advance(300);
  assert.deepEqual([h.last().left, h.last().right], [0, 0]);
  withCanvas(editor);
  editor.tools.remove();
  h.mutate();
  h.advance(300);
  assert.deepEqual([h.last().left, h.last().right], [0, 0]);
  editor.body.append(editor.tools);
  h.mutate();
  h.advance(300);
  assert.deepEqual([h.last().left, h.last().right], [290, 241]);
});

test("an open sheet survives removal and replacement of its Figma panel", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, true);
  h.runtime.phonePanel("right");
  const old = editor.right;
  old.remove();
  h.mutate();
  h.advance(300);
  assert.equal(h.last().panel, "right");
  const replacement = editor.body.append(
    new El("div", {
      "data-testid": "properties-panel",
      class: "properties_panel--drillDownContainer--sVtfc",
    }),
  );
  h.mutate();
  h.advance(300);
  assert.equal(h.last().panel, "right");
  assert.equal(marker(replacement), "right");
  assert.match(h.style.textContent, /"right"\]\{position:fixed/);
  assert.equal(marker(old), null);
});

test("visible tools are ordered fixed ids from the active row, never hidden modes or content", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  assert.deepEqual(h.last().visibleTools, designTools);
  editor.visible.children.splice(0);
  for (const name of [
    "Move",
    "Hand tool",
    "Comment",
    "Measurement",
    "Annotation",
    "private-name",
    "Measurement",
  ])
    editor.visible.append(toolButton(name, name === "Move"));
  h.mutate();
  h.advance(300);
  assert.deepEqual(h.last().visibleTools, [
    "Move-tool",
    "Hand tool-tool",
    "Comment-tool",
    "Measurement-tool",
    "Annotation-tool",
  ]);
  h.runtime.setPhoneLayout(false);
  assert.deepEqual(h.last().visibleTools, []);
});

test("captured Dev width owner fills the sheet, and returning to Design preserves the sheet", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true, true);
  h.runtime.phonePanel("right");
  editor.right.removeAttribute("data-testid");
  editor.right.style.width = "321px";
  const position = editor.right.append(
    new El(
      "div",
      {
        "data-testid": "dev-handoff-right-panel",
        class: "properties_panel--panelPosition--NHDoF",
      },
      [290, 347, 321, 347],
    ),
  );
  position.style.width = "321px";
  position.append(
    new El("div", {
      class:
        "properties_panel--panelContainer--LGS1e dev_handoff_right_panel_container--panelContainer--qzeWF",
    }),
  );
  h.mutate();
  h.advance(300);
  assert.equal(h.last().panel, "right");
  assert.match(
    h.style.textContent,
    /dev-handoff-right-panel"\]\{width:100%!important;min-width:0/,
  );
  editor.right.remove();
  h.mutate();
  h.advance(300);
  assert.equal(h.last().panel, "right");
  const design = editor.body.append(
    new El(
      "div",
      {
        "data-testid": "properties-panel",
        class: "properties_panel--drillDownContainer--sVtfc",
      },
      [290, 347, 402, 347],
    ),
  );
  h.mutate();
  h.advance(300);
  assert.equal(marker(design), "right");
  assert.equal(h.last().panel, "right");
  assert.match(h.style.textContent, /"right"\]\{position:fixed/);
});

test("captured H/K/V button ids report the actual active tool", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  const button = editor.visible.children[0];
  for (const [id, key] of [
    ["Hand tool-tool", "hand"],
    ["Scale-tool", "scale"],
    ["Move-tool", "move"],
  ]) {
    button.setAttribute("data-testid", id);
    button.setAttribute("aria-pressed", "true");
    h.mutate();
    h.advance(300);
    assert.equal(h.last().tool, key);
    assert.equal(h.last().visibleTools[0], id);
  }
});

test("Dev row reports Measurement and Annotation as the active tool", () => {
  const editor = figmaEditor();
  const h = harness(editor);
  h.runtime.setPhoneLayout(true, true);
  editor.visible.children.splice(0);
  for (const name of ["Move", "Measurement", "Annotation", "Comment"])
    editor.visible.append(toolButton(name, name === "Move"));
  for (const [name, key] of [
    ["Measurement", "measurement"],
    ["Annotation", "annotation"],
    ["Move", "move"],
  ]) {
    editor.press(name);
    h.mutate();
    h.advance(300);
    assert.equal(h.last().tool, key);
  }
  assert.deepEqual(h.last().visibleTools, [
    "Move-tool",
    "Measurement-tool",
    "Annotation-tool",
    "Comment-tool",
  ]);
});

test("sheet drag translates a fixed box immediately and commits height on release", () => {
  for (const side of ["left", "right"]) {
    const h = harness(figmaEditor());
    h.runtime.setPhoneLayout(true, true, false, true);
    h.runtime.phonePanel(side, 0.5);
    h.advance(300);
    assert.equal(h.runtime.phoneSheetDrag("begin", 0.5), true);
    const box = h.style.textContent;
    assert.match(box, /top:347px!important;bottom:auto!important;height:590px/);
    const dragStyle = h.styles[1];
    const messages = h.messages.length;
    const timers = h.timers.size;
    for (const fraction of [0.6, 0.85, 0.25, 0.7]) {
      assert.equal(h.runtime.phoneSheetDrag("move", fraction), true);
      assert.equal(h.style.textContent, box, "no panel relayout during moves");
      const delta = Math.round(694 * (1 - fraction)) - 347;
      assert.match(
        dragStyle.textContent,
        new RegExp(`translate3d\\(0,${delta}px,0\\)`),
      );
    }
    assert.equal(
      h.messages.length,
      messages,
      "no native state/overscan round trip",
    );
    assert.equal(h.timers.size, timers, "no deferred frame or scan per move");
    h.observers[0].callback([{ target: dragStyle, addedNodes: [] }]);
    assert.equal(
      h.timers.size,
      timers,
      "own transform writes do not rescan Figma",
    );
    h.mutate();
    h.advance(300);
    assert.equal(
      h.style.textContent,
      box,
      "DOM scans keep the fixed drag geometry",
    );
    assert.equal(h.runtime.phoneSheetDrag("end", 0.7), true);
    assert.equal(dragStyle.textContent, "");
    assert.equal(dragStyle.parentNode, null);
    assert.match(
      h.style.textContent,
      /top:208px!important;bottom:0!important;height:auto/,
    );
    assert.doesNotMatch(h.style.textContent, /will-change/);
  }
});

test("sheet drag validates samples, clamps endpoints and clears on keyboard/disable/side mode", () => {
  const h = harness(figmaEditor());
  assert.equal(h.runtime.phoneSheetDrag("begin", 0.5), false);
  h.runtime.setPhoneLayout(true, true, false, true);
  h.runtime.phonePanel("right", 0.5);
  h.advance(300);
  assert.equal(h.runtime.phoneSheetDrag("begin", NaN), false);
  assert.equal(h.runtime.phoneSheetDrag("bogus", 0.5), false);
  h.runtime.phoneSheetDrag("begin", 0.5);
  h.runtime.phoneSheetDrag("end", 9);
  assert.match(h.style.textContent, /top:104px/);
  h.runtime.phoneSheetDrag("end", -1);
  assert.match(h.style.textContent, /top:521px/);
  h.runtime.phoneSheetDrag("begin", 0.5);
  h.runtime.phoneKeyboard(300, 0.8);
  assert.equal(h.styles[1].textContent, "");
  assert.match(
    h.style.textContent,
    /top:139px!important;bottom:auto!important;height:255px/,
  );
  assert.equal(h.runtime.phoneSheetDrag("move", 0.6), false);
  h.runtime.phoneSheetDrag("begin", 0.6);
  h.runtime.setPhoneLayout(false);
  assert.equal(h.styles[1].textContent, "");
  assert.equal(h.runtime.phoneSheetDrag("move", 0.6), false);
  h.runtime.setPhoneLayout(true, true, true, true, true);
  assert.equal(h.runtime.phoneSheetDrag("begin", 0.6), false);
  h.runtime.disposePhoneLayout();
  assert.equal(h.runtime.phoneSheetDrag, undefined);
});
