// Server-owned dialogs close on removal. Credential dialogs stay mounted and
// open/close locally; their ordinary POST forms never send secrets over LiveView.
export default {
  mounted() {
    this.document = this.el.ownerDocument
    this.window = this.document.defaultView
    this.returnFocus = this.el.dataset.returnFocus
    this.cancelPending = false
    this.onCancel = event => {
      event.preventDefault()
      event.stopPropagation()
      if (!this.el.dataset.cancelEvent) {
        this.onClose()
      } else if (!this.cancelPending) {
        this.cancelPending = true
        this.pushEvent(this.el.dataset.cancelEvent, {})
      }
    }
    this.onKeydown = event => {
      if (event.key === "Escape" && this.el.open) this.onCancel(event)
    }
    this.onOpen = () => {
      if (this.el.open) return
      this.el.showModal()
      this.js().setAttribute(this.el, "open", "")
      if (this.el.dataset.openOnMount === "false") this.js().setAttribute(this.el, "data-modal", "")
      this.el.querySelector(this.el.dataset.initialFocus)?.focus({preventScroll: true})
    }
    this.onClose = () => {
      if (!this.el.open) return
      this.el.close()
      this.js().removeAttribute(this.el, "open")
      this.js().removeAttribute(this.el, "data-modal")
      this.restoreFocus()
    }
    // Capture before LiveView's window Escape command can reset the scenery.
    this.window.addEventListener("keydown", this.onKeydown, true)
    this.el.addEventListener("cancel", this.onCancel)
    this.el.addEventListener("monolith:modal-open", this.onOpen)
    this.el.addEventListener("monolith:modal-close", this.onClose)
    // Keep native modal state sticky across unrelated LiveView patches.
    if (this.el.dataset.openOnMount !== "false") this.onOpen()
  },

  destroyed() {
    this.window.removeEventListener("keydown", this.onKeydown, true)
    this.el.removeEventListener("cancel", this.onCancel)
    this.el.removeEventListener("monolith:modal-open", this.onOpen)
    this.el.removeEventListener("monolith:modal-close", this.onClose)
    if (this.el.open) {
      this.el.close()
      this.restoreFocus()
    }
  },

  restoreFocus() {
    // Wait for patches to restore an always-visible opener.
    this.window.requestAnimationFrame(() => {
      this.document.dispatchEvent(new this.window.Event("monolith:modal-closed"))
      if (this.document.querySelector("dialog[open]")) return
      const trigger = this.document.querySelector(this.returnFocus)
      const target = trigger && !trigger.disabled ? trigger :
        this.document.querySelector("[data-workspace-heading]")
      target?.focus({preventScroll: true})
    })
  },
}
