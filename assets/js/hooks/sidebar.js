// One native navigation column. Expanded state is browser-local and sticky
// through LiveView patches; no overlay, focus trap or application state copy.
export default {
  mounted() {
    this.view = this.el.ownerDocument.defaultView
    this.shell = this.el.closest(".workspace-shell")
    this.workspace = this.el.closest("#workspace")
    this.toggle = this.el.querySelector(".navigation-toggle")
    this.content = this.el.querySelector(".sidebar-content")
    this.expanded = false
    this.sync = () => {
      this.js().setAttribute(this.shell, "data-navigation", this.expanded ? "expanded" : "collapsed")
      this.js().setAttribute(this.toggle, "aria-expanded", String(this.expanded))
      this.js().setAttribute(this.toggle, "aria-label", this.expanded ? "Collapse sidebar" : "Expand sidebar")
      if (this.expanded) this.js().removeAttribute(this.content, "hidden")
      else this.js().setAttribute(this.content, "hidden", "")
    }
    this.collapse = focus => {
      this.expanded = false
      this.sync()
      if (focus) this.toggle.focus({preventScroll: true})
    }
    this.cancelDestination = () => {
      this.focusDestination = false
      // Cancel the independently pushed heading frame too. This also reaches
      // WorkspaceEntrance when sidebar Escape stops keyboard propagation.
      this.workspace.dispatchEvent(new this.view.Event("monolith:destination-focus-cancel"))
    }
    this.onClick = event => {
      if (event.target.closest(".navigation-toggle")) {
        this.expanded = !this.expanded
        this.sync()
      } else if (event.target.closest(".sidebar-content a[href]") && event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
        this.collapse(false)
        this.focusDestination = true
      }
    }
    this.onEscape = event => {
      if (event.key !== "Escape") return
      this.cancelDestination()
      if (this.el.ownerDocument.querySelector("dialog[open]")) return
      if (this.expanded) {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.collapse(true)
      }
    }
    this.onDestination = () => {
      if (!this.focusDestination) return
      this.cancelDestination()
      // Heading focus bubbles into WorkspaceEntrance, so it must not wake scenery.
      if (this.workspace.querySelector("#workspace-pane")?.getAttribute("aria-pressed") !== "true") return
      this.el.ownerDocument.querySelector("[data-workspace-heading]")?.focus({preventScroll: true})
    }
    this.el.addEventListener("click", this.onClick)
    this.view.addEventListener("keydown", this.onEscape, true)
    this.view.addEventListener("phx:page-loading-stop", this.onDestination)
    this.workspace.addEventListener("monolith:brand-reset", this.cancelDestination)
    this.el.ownerDocument.addEventListener("keydown", this.cancelDestination, true)
    this.el.ownerDocument.addEventListener("pointerdown", this.cancelDestination, true)
    this.el.ownerDocument.addEventListener("input", this.cancelDestination, true)
    this.sync()
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.view.removeEventListener("keydown", this.onEscape, true)
    this.view.removeEventListener("phx:page-loading-stop", this.onDestination)
    this.workspace.removeEventListener("monolith:brand-reset", this.cancelDestination)
    this.el.ownerDocument.removeEventListener("keydown", this.cancelDestination, true)
    this.el.ownerDocument.removeEventListener("pointerdown", this.cancelDestination, true)
    this.el.ownerDocument.removeEventListener("input", this.cancelDestination, true)
  },
}
