import "./bridge";

// Maintainer (2026-11-20): Folio is not a video player. Every video on the page plays inline,
// without native controls, Picture in Picture or fullscreen: Figma's tutorial clips, prototype
// background videos, anything. Standard media attributes only; no Figma script is touched.
type FullscreenVideo = HTMLVideoElement & { webkitExitFullscreen?: () => void };
const runtime = globalThis.__folio;
if (runtime && !runtime.disposeInlineMedia) {
  const pin = (video: HTMLVideoElement) => {
    if (!video.playsInline) video.playsInline = true;
    if (!video.hasAttribute("webkit-playsinline"))
      video.setAttribute("webkit-playsinline", "");
    if (!video.disablePictureInPicture) video.disablePictureInPicture = true;
    if (video.controls) video.controls = false;
  };
  const scan = (node: Node) => {
    if (node instanceof HTMLVideoElement) pin(node);
    else if ("querySelectorAll" in node)
      (node as ParentNode).querySelectorAll("video").forEach(pin);
  };
  const observer = new MutationObserver((records) => {
    for (const record of records)
      if (record.type === "attributes") {
        if (record.target instanceof HTMLVideoElement) pin(record.target);
      } else record.addedNodes.forEach(scan);
  });
  observer.observe(document, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["controls", "playsinline", "webkit-playsinline"],
  });
  scan(document);
  // Backstop: a video that still reaches native fullscreen comes straight back inline and keeps
  // playing if it was playing.
  const back = (video: FullscreenVideo) => {
    const playing = !video.paused;
    pin(video);
    video.webkitExitFullscreen?.();
    if (playing) void video.play().catch(() => {});
  };
  const videoFullscreen = (event: Event) => {
    if (event.target instanceof HTMLVideoElement) back(event.target);
  };
  const elementFullscreen = () => {
    const element = document.fullscreenElement;
    if (element instanceof HTMLVideoElement) {
      void document.exitFullscreen().catch(() => {});
      pin(element);
    }
  };
  const play = (event: Event) => {
    if (event.target instanceof HTMLVideoElement) pin(event.target);
  };
  const listeners: [string, EventListener][] = [
    ["webkitbeginfullscreen", videoFullscreen],
    ["fullscreenchange", elementFullscreen],
    ["play", play],
  ];
  for (const [name, listener] of listeners)
    document.addEventListener(name, listener, true);
  runtime.disposeInlineMedia = () => {
    observer.disconnect();
    for (const [name, listener] of listeners)
      document.removeEventListener(name, listener, true);
    delete runtime.disposeInlineMedia;
  };
}
export {};
