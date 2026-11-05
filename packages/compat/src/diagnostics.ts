export {};
interface GPUAdapter {
  info?: {
    vendor?: string;
    architecture?: string;
    device?: string;
    description?: string;
  };
}
interface GPU {
  requestAdapter: () => Promise<GPUAdapter | null>;
}
const runtime = globalThis.__folio;
if (runtime && !runtime.capture) {
  let active = true;
  let capturing = false;
  const limited = (value: unknown): string =>
    typeof value === "string" ? value.slice(0, 256) : "unavailable";
  const glInfo = (kind: "webgl" | "webgl2") => {
    const canvas = document.createElement("canvas"); // Detached, never alters the page DOM.
    const gl = canvas.getContext(kind);
    if (
      !(
        (typeof WebGLRenderingContext !== "undefined" &&
          gl instanceof WebGLRenderingContext) ||
        (typeof WebGL2RenderingContext !== "undefined" &&
          gl instanceof WebGL2RenderingContext)
      )
    ) {
      return { available: false, renderer: "unavailable", maxTextureSize: 0 };
    }
    const debug = gl.getExtension("WEBGL_debug_renderer_info");
    const result = {
      available: true,
      renderer: debug
        ? limited(gl.getParameter(debug.UNMASKED_RENDERER_WEBGL))
        : "not exposed",
      maxTextureSize: Number(gl.getParameter(gl.MAX_TEXTURE_SIZE)),
    };
    gl.getExtension("WEBGL_lose_context")?.loseContext();
    return result;
  };
  runtime.capture = async () => {
    if (!active || capturing) return;
    capturing = true;
    try {
      const gpu = (navigator as Navigator & { gpu?: GPU }).gpu;
      let adapterResult = "unavailable";
      let adapterInfo = "unavailable";
      if (gpu?.requestAdapter) {
        let timeout: ReturnType<typeof setTimeout> | undefined;
        try {
          const result = await Promise.race([
            gpu
              .requestAdapter()
              .then((adapter) => ({ adapter, timedOut: false })),
            new Promise<{ adapter: null; timedOut: true }>((resolve) => {
              timeout = setTimeout(
                () => resolve({ adapter: null, timedOut: true }),
                4000,
              );
            }),
          ]);
          const adapter = result.adapter;
          adapterResult = result.timedOut
            ? "timed out"
            : adapter
              ? "available"
              : "null";
          if (adapter?.info)
            adapterInfo = [
              adapter.info.vendor,
              adapter.info.architecture,
              adapter.info.device,
              adapter.info.description,
            ]
              .map(limited)
              .join(" / ")
              .slice(0, 1024);
        } catch {
          adapterResult = "requestAdapter error";
        } finally {
          if (timeout !== undefined) clearTimeout(timeout);
        }
      }
      const media: Record<string, boolean> = {};
      for (const feature of ["pointer", "any-pointer"])
        for (const value of ["none", "coarse", "fine"])
          media[`${feature}:${value}`] =
            typeof matchMedia === "function" &&
            matchMedia(`(${feature}: ${value})`).matches;
      for (const feature of ["hover", "any-hover"])
        for (const value of ["none", "hover"])
          media[`${feature}:${value}`] =
            typeof matchMedia === "function" &&
            matchMedia(`(${feature}: ${value})`).matches;
      if (active)
        runtime.post("folioDiagnostics", {
          userAgent: navigator.userAgent,
          gpuPresent: Boolean(gpu),
          adapterResult,
          adapterInfo,
          webgl: glInfo("webgl"),
          webgl2: glInfo("webgl2"),
          devicePixelRatio,
          viewportWidth: innerWidth,
          viewportHeight: innerHeight,
          maxTouchPoints: navigator.maxTouchPoints,
          media,
          ...(runtime.focusRevealGuardStats
            ? { focusRevealGuard: runtime.focusRevealGuardStats() }
            : {}),
          ...(runtime.trackpadPinchStats
            ? { trackpadPinch: runtime.trackpadPinchStats() }
            : {}),
        });
    } finally {
      capturing = false;
    }
  };
  runtime.disposeDiagnostics = () => {
    active = false;
    delete runtime.capture;
    delete runtime.disposeDiagnostics;
  };
}
