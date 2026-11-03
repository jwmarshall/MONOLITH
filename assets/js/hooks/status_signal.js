// CSS owns motion (including live preference changes). This hook only positions
// and dismisses hover/focus details; it never owns provider or LiveView state.
const StatusSignal = {
  mounted() {
    this.trigger = this.el.dataset.embedded === "true" ? this.el.closest("a") || this.el : this.el
    this.tooltip = this.el.querySelector(".status-tooltip")
    if (!this.tooltip) return
    this.window = this.el.ownerDocument.defaultView
    this.dismiss = event => {
      if (event.key !== "Escape" || this.window.getComputedStyle(this.tooltip).display === "none") return
      this.el.setAttribute("data-tooltip-dismissed", "")
      // Dismissing a status detail must not also enter scenery mode.
      event.stopPropagation()
    }
    this.reset = () => this.el.removeAttribute("data-tooltip-dismissed")
    this.position = () => {
      const signal = this.el.getBoundingClientRect()
      const boundary = this.el.closest("#workspace-content")?.getBoundingClientRect()
      const left = Math.max(8, (boundary?.left || 0) + 8)
      const right = Math.min(this.window.innerWidth - 8, (boundary?.right || this.window.innerWidth) - 8)
      const width = Math.min(280, Math.max(1, right - left))
      const offset = Math.max(left - signal.left, Math.min(0, right - signal.left - width))
      this.el.style.setProperty("--status-tooltip-width", `${width}px`)
      this.el.style.setProperty("--status-tooltip-left", `${offset}px`)
      this.el.removeAttribute("data-tooltip-above")
      if (signal.bottom + this.tooltip.getBoundingClientRect().height > Math.min(this.window.innerHeight, boundary?.bottom || this.window.innerHeight) - 8) {
        this.el.setAttribute("data-tooltip-above", "")
      }
    }
    this.focus = () => { this.reset(); this.position() }
    this.leave = () => {
      if (this.el.ownerDocument.activeElement !== this.trigger) this.reset()
    }
    // Hover details can be open while focus is elsewhere. Capture before the
    // shell's window-level Escape, but consume only an actually open detail.
    this.window.addEventListener("keydown", this.dismiss, true)
    this.trigger.addEventListener("blur", this.reset)
    this.trigger.addEventListener("focus", this.focus)
    this.el.addEventListener("pointerenter", this.position)
    this.el.addEventListener("pointerleave", this.leave)
    this.window.addEventListener("resize", this.position)
    this.position()
  },
  updated() {
    // A status can change from icon-only activity to visible recovery text.
    this.destroyed()
    this.mounted()
  },
  destroyed() {
    if (!this.tooltip) return
    this.window.removeEventListener("keydown", this.dismiss, true)
    this.trigger.removeEventListener("blur", this.reset)
    this.trigger.removeEventListener("focus", this.focus)
    this.el.removeEventListener("pointerenter", this.position)
    this.el.removeEventListener("pointerleave", this.leave)
    this.window.removeEventListener("resize", this.position)
  },
}
export default StatusSignal
