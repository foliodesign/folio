import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const script = await readFile(
  new URL(
    "../../../apps/ios/Folio/Resources/Compat/inline-media.js",
    import.meta.url,
  ),
  "utf8",
);

function harness() {
  const listeners = new Map();
  let observer;
  class Node {}
  class HTMLVideoElement extends Node {
    attributes = new Map([["controls", ""]]);
    paused = false;
    exits = 0;
    plays = 0;
    get playsInline() {
      return this.attributes.has("playsinline");
    }
    set playsInline(on) {
      if (on) this.attributes.set("playsinline", "");
      else this.attributes.delete("playsinline");
    }
    get controls() {
      return this.attributes.has("controls");
    }
    set controls(on) {
      if (on) this.attributes.set("controls", "");
      else this.attributes.delete("controls");
    }
    disablePictureInPicture = false;
    hasAttribute(name) {
      return this.attributes.has(name);
    }
    setAttribute(name, value) {
      this.attributes.set(name, value);
    }
    webkitExitFullscreen() {
      this.exits++;
    }
    play() {
      this.plays++;
      return Promise.resolve();
    }
  }
  const existing = new HTMLVideoElement();
  const document = new (class extends Node {
    fullscreenElement = null;
    exited = 0;
    querySelectorAll = () => [existing];
    addEventListener(name, fn) {
      listeners.set(name, fn);
    }
    removeEventListener(name) {
      listeners.delete(name);
    }
    exitFullscreen() {
      this.exited++;
      return Promise.resolve();
    }
  })();
  const context = vm.createContext({
    __folio: {},
    document,
    HTMLVideoElement,
    Node,
    MutationObserver: class {
      constructor(fn) {
        observer = fn;
      }
      observe() {}
      disconnect() {
        observer = undefined;
      }
    },
  });
  vm.runInContext(script, context);
  return {
    context,
    document,
    existing,
    HTMLVideoElement,
    listeners,
    mutate: (records) => observer?.(records),
  };
}

const pinned = (video) =>
  video.playsInline &&
  video.hasAttribute("webkit-playsinline") &&
  video.disablePictureInPicture &&
  !video.controls;

test("videos already on the page and added later play inline without controls", () => {
  const h = harness();
  assert.ok(pinned(h.existing));
  const added = new h.HTMLVideoElement();
  h.mutate([{ type: "childList", addedNodes: [added] }]);
  assert.ok(pinned(added));
  added.controls = true;
  h.mutate([{ type: "attributes", target: added }]);
  assert.ok(pinned(added));
});

test("a video that reaches native fullscreen comes back inline and keeps playing", () => {
  const h = harness();
  const video = new h.HTMLVideoElement();
  h.listeners.get("webkitbeginfullscreen")({ target: video });
  assert.equal(video.exits, 1);
  assert.equal(video.plays, 1);
  assert.ok(pinned(video));
  h.document.fullscreenElement = video;
  h.listeners.get("fullscreenchange")({ target: h.document });
  assert.equal(h.document.exited, 1);
  h.document.fullscreenElement = {};
  h.listeners.get("fullscreenchange")({ target: h.document });
  assert.equal(h.document.exited, 1);
});

test("dispose stops watching", () => {
  const h = harness();
  h.context.__folio.disposeInlineMedia();
  assert.equal(h.listeners.size, 0);
  assert.equal(h.context.__folio.disposeInlineMedia, undefined);
});
