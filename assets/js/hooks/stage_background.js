// The original SVG stays underneath. Only show a successfully decoded local
// image; failed/partial loads must never replace the fallback with a broken icon.
export default {
  mounted() {
    this.onLoad = () => {
      this.js().setAttribute(this.el, "data-loaded", this.el.naturalWidth > 0 ? "true" : "false")
    }
    this.onError = () => this.js().setAttribute(this.el, "data-loaded", "false")
    this.el.addEventListener("load", this.onLoad)
    this.el.addEventListener("error", this.onError)
    // Cached images can finish before the hook mounts.
    if (this.el.complete) this.onLoad()
  },

  destroyed() {
    this.el.removeEventListener("load", this.onLoad)
    this.el.removeEventListener("error", this.onError)
  },
}
