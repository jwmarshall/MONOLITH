// Entrance state is client-only and sticky across LiveView patches. Business
// content stays server-owned; only its inert gate and this layout attribute change.
export default {
  mounted() {
    this.document = this.el.ownerDocument
    this.view = this.document.defaultView
    this.root = this.el.closest("#workspace")
    this.isFocused = () => this.root.querySelector("#workspace-pane").getAttribute("aria-pressed") === "true"
    this.focusRevision = 0
    this.navigationRevision = null
    this.cancelHeading = () => {
      this.focusRevision++
      this.view.cancelAnimationFrame(this.headingFrame)
    }
    this.onNavigationStart = () => { this.navigationRevision = this.focusRevision }
    this.onNavigationStop = () => { this.navigationRevision = null }
    this.onComplete = () => {
      this.js().setAttribute(this.el, "data-entered", "true")
      const content = this.el.querySelector("#workspace-content")
      this.js().removeAttribute(content, "inert")
      // Lock now belongs to the sidebar, within the same working-plane gate.
      const active = this.el.ownerDocument.activeElement
      if (this.isFocused() && (active?.id === "workspace-pane" || active === this.document.body)) {
        content.querySelector("[data-workspace-heading]")?.focus({preventScroll: true})
      }
    }
    this.onFocus = event => {
      // Assistive technology and programmatic control focus need not emit a
      // pointer/key event. They still supersede a queued destination heading.
      if (event?.target?.matches?.("a[href], button, input, select, textarea, summary, [contenteditable='true']")) {
        this.cancelHeading()
      }
      const root = this.el.closest("#workspace")
      this.js().exec(root.getAttribute("data-workspace-focus"))
    }
    this.handleEvent("workspace:focus-heading", () => {
      // A pushed event belongs to the navigation that requested it, not to
      // whichever control or focal plane is active when its response arrives.
      if (this.navigationRevision !== null && this.navigationRevision !== this.focusRevision) return
      const revision = this.focusRevision
      this.view.cancelAnimationFrame(this.headingFrame)
      this.headingFrame = this.view.requestAnimationFrame(() => {
        if (revision === this.focusRevision && this.isFocused()) {
          this.el.querySelector("[data-workspace-heading]")?.focus({preventScroll: true})
        }
      })
    })
    this.onEscape = event => {
      if (event.key !== "Escape" || this.document.querySelector("dialog[open]")) return
      if (this.el.querySelector(".workspace-shell")?.dataset.navigation === "expanded") return
      // Search inputs otherwise clear their draft as Escape's browser default.
      event.preventDefault()
      this.js().exec(this.root.getAttribute("data-workspace-reset"))
    }
    this.document.addEventListener("keydown", this.cancelHeading, true)
    this.document.addEventListener("pointerdown", this.cancelHeading, true)
    this.document.addEventListener("input", this.cancelHeading, true)
    this.root.addEventListener("monolith:brand-reset", this.cancelHeading)
    this.root.addEventListener("monolith:destination-focus-cancel", this.cancelHeading)
    this.view.addEventListener("phx:page-loading-start", this.onNavigationStart)
    this.view.addEventListener("phx:page-loading-stop", this.onNavigationStop)
    this.view.addEventListener("keydown", this.onEscape)
    this.el.addEventListener("monolith:brand-complete", this.onComplete)
    this.el.addEventListener("focusin", this.onFocus)
    // A server-authorized return skips only the visual entrance, once per mount.
    if (this.el.getAttribute("data-enter-on-return") === "true") {
      this.onComplete()
      this.onFocus()
    } else if (this.el.getAttribute("data-enter-on-unlock") === "true") {
      // A successful password POST starts the introduction without another click.
      // This consumed session marker never grants access or skips the inert gate.
      this.onFocus()
    }
  },

  destroyed() {
    this.view.cancelAnimationFrame(this.headingFrame)
    this.document.removeEventListener("keydown", this.cancelHeading, true)
    this.document.removeEventListener("pointerdown", this.cancelHeading, true)
    this.document.removeEventListener("input", this.cancelHeading, true)
    this.root.removeEventListener("monolith:brand-reset", this.cancelHeading)
    this.root.removeEventListener("monolith:destination-focus-cancel", this.cancelHeading)
    this.view.removeEventListener("phx:page-loading-start", this.onNavigationStart)
    this.view.removeEventListener("phx:page-loading-stop", this.onNavigationStop)
    this.view.removeEventListener("keydown", this.onEscape)
    this.el.removeEventListener("monolith:brand-complete", this.onComplete)
    this.el.removeEventListener("focusin", this.onFocus)
  },
}
