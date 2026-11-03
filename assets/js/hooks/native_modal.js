// Server removal closes the dialog on both save and cancel. Do not ignore the
// subtree: LiveView still owns validation, errors and the form's draft values.
export default {
  mounted() {
    this.document = this.el.ownerDocument
    this.window = this.document.defaultView
    this.returnFocus = this.el.dataset.returnFocus
    this.cancelPending = false
    this.onCancel = event => {
      event.preventDefault()
      event.stopPropagation()
      if (!this.cancelPending) {
        this.cancelPending = true
        this.pushEvent(this.el.dataset.cancelEvent, {})
      }
    }
    this.onKeydown = event => {
      if (event.key === "Escape" && this.el.open) this.onCancel(event)
    }
    // Capture before LiveView's window Escape command can reset the scenery.
    this.window.addEventListener("keydown", this.onKeydown, true)
    this.el.addEventListener("cancel", this.onCancel)
    this.el.showModal()
    // Keep the native open attribute sticky across form/background patches;
    // removing it would silently dismiss the top layer and its inertness.
    this.js().setAttribute(this.el, "open", "")
    this.el.querySelector(this.el.dataset.initialFocus)?.focus({preventScroll: true})
  },

  destroyed() {
    this.window.removeEventListener("keydown", this.onKeydown, true)
    this.el.removeEventListener("cancel", this.onCancel)
    if (this.el.open) this.el.close()
    // Wait for the patch to restore triggers hidden while editing (including
    // streamed cards). Rename returns to its visible management disclosure,
    // not the Rename button inside the now-collapsed menu.
    this.window.requestAnimationFrame(() => {
      this.document.dispatchEvent(new this.window.Event("lovelace:modal-closed"))
      if (this.document.querySelector("dialog[open]")) return
      const target = this.document.querySelector(this.returnFocus) ||
        this.document.querySelector("[data-workspace-heading]")
      target?.focus({preventScroll: true})
    })
  },
}
