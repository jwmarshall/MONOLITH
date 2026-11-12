// Entrance state is client-only and sticky across LiveView patches. Business
// content stays server-owned; only its inert gate and this layout attribute change.
export default {
  mounted() {
    this.onComplete = () => {
      this.js().setAttribute(this.el, "data-entered", "true")
      const content = this.el.querySelector("#workspace-content")
      this.js().removeAttribute(content, "inert")
      const controls = this.el.querySelector("#workspace-controls")
      if (controls) this.js().removeAttribute(controls, "inert")
      const active = this.el.ownerDocument.activeElement
      if (active?.id === "workspace-pane" || active === this.el.ownerDocument.body) {
        content.querySelector("[data-workspace-heading]")?.focus({preventScroll: true})
      }
    }
    this.onFocus = () => {
      const root = this.el.closest("#workspace")
      this.js().exec(root.getAttribute("data-workspace-focus"))
    }
    this.handleEvent("workspace:focus-heading", () => {
      this.el.querySelector("[data-workspace-heading]")?.focus({preventScroll: true})
    })
    this.el.addEventListener("monolith:brand-complete", this.onComplete)
    this.el.addEventListener("focusin", this.onFocus)
    // A server-authorized return skips only the visual entrance, once per mount.
    if (this.el.getAttribute("data-enter-on-return") === "true") {
      this.onComplete()
      this.onFocus()
    }
  },

  destroyed() {
    this.el.removeEventListener("monolith:brand-complete", this.onComplete)
    this.el.removeEventListener("focusin", this.onFocus)
  },
}
