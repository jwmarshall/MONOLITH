// The original SVG stays underneath. Only show a successfully decoded local
// image; failed/partial loads must never replace the fallback with a broken icon.
export function observeStageImage(image, setLoaded) {
  const onLoad = () => setLoaded(image.naturalWidth > 0 ? "true" : "false")
  const onError = () => setLoaded("false")
  image.addEventListener("load", onLoad)
  image.addEventListener("error", onError)
  // Cached images can finish before the observer is attached.
  if (image.complete) onLoad()
  return () => {
    image.removeEventListener("load", onLoad)
    image.removeEventListener("error", onError)
  }
}

export default {
  mounted() {
    this.stopObserving = observeStageImage(this.el,
      value => this.js().setAttribute(this.el, "data-loaded", value))
  },

  destroyed() {
    this.stopObserving()
  },
}
