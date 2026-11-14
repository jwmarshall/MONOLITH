// Navigation memory is ephemeral and scoped to one account/list context. No mail
// bodies, queries or navigation state are persisted in browser storage.
export default {
  mounted() {
    this.context = this.el.dataset.mailContext
    this.thread = this.el.dataset.mailThread
    this.account = this.el.dataset.mailAccount || ""
    this.inboxPending = Boolean(this.account && !this.thread)
    this.returnPosition = null
    this.readerPending = Boolean(this.thread)
    this.returnPending = false
    this.frame = null
    this.handoffCanceled = false
    this.cancelHandoff = () => {
      this.handoffCanceled = true
      this.readerPending = false
      this.returnPending = false
      this.inboxPending = false
      this.cancelFrame()
    }
    // Cancellation belongs to the pending navigation, not every future one.
    // History traversal has no mail-row/Back click to establish fresh intent.
    this.beginNavigation = event => {
      if (event.type === "popstate" || ["patch", "redirect"].includes(event.detail?.kind)) {
        this.cancelHandoff()
        this.handoffCanceled = false
      }
    }
    this.view = this.el.ownerDocument.defaultView
    this.view.addEventListener("popstate", this.beginNavigation, true)
    this.view.addEventListener("phx:page-loading-start", this.beginNavigation)
    this.rememberPosition = event => {
      const row = event.target.closest("[data-mail-open-thread]")
      if (row || event.target.closest("#mail-back")) this.handoffCanceled = false
      if (row && this.el.contains(row) && !this.thread) {
        this.returnPosition = {id: row.id, top: this.scroller().scrollTop}
      }
      // A new intentional control action must not lose focus to a pending load.
      if (!row && !event.target.closest("#mail-back")) this.cancelHandoff()
    }
    this.onFocus = event => {
      if (!this.handingOff && event.target.matches("a, button, input, select, textarea, summary, [tabindex]:not([data-workspace-heading])")) {
        this.cancelHandoff()
      }
    }
    this.el.addEventListener("click", this.rememberPosition, true)
    this.el.ownerDocument.addEventListener("keydown", this.cancelHandoff, true)
    this.el.ownerDocument.addEventListener("pointerdown", this.cancelHandoff, true)
    this.el.ownerDocument.addEventListener("input", this.cancelHandoff, true)
    this.el.ownerDocument.addEventListener("focusin", this.onFocus, true)
    this.updateReader()
  },

  scroller() {
    return this.el.closest(".workspace-content") || this.el.ownerDocument.scrollingElement
  },

  cancelFrame() {
    if (this.frame !== null) cancelAnimationFrame(this.frame)
    this.frame = null
  },

  updated() { this.updateReader() },

  updateReader() {
    const {mailContext: context, mailThread: thread, mailLoaded: loaded, mailAccount: account = ""} = this.el.dataset
    if (context !== this.context) {
      this.cancelFrame()
      this.context = context
      this.returnPosition = null
      this.returnPending = false
      this.readerPending = false
    }
    if (account !== this.account) {
      this.inboxPending = Boolean(account && !thread) && !this.handoffCanceled
      this.account = account
    }
    if (thread !== this.thread) {
      this.cancelFrame()
      this.readerPending = Boolean(thread) && !this.handoffCanceled
      this.inboxPending = false
      this.returnPending = !thread && Boolean(this.returnPosition) && !this.handoffCanceled
      this.thread = thread
    }
    if (this.inboxPending && this.el.querySelector("#mail-heading")) {
      this.inboxPending = false
      this.schedule(() => {
        const heading = this.el.querySelector("#mail-heading")
        heading?.focus({preventScroll: true})
        this.scroller().scrollTop = 0
      })
    }
    if (loaded !== "true") return

    if (this.readerPending && this.el.querySelector("#mail-conversation-heading")) {
      this.readerPending = false
      this.schedule(() => {
        const heading = this.el.querySelector("#mail-conversation-heading")
        const latest = this.el.querySelector('[data-mail-latest="true"]')
        const target = latest?.querySelector(":scope > summary") || heading
        // Keep the subject and account context visible when the latest summary
        // already fits. Long histories still bring that reply into view.
        this.scroller().scrollTop = 0
        target?.scrollIntoView({block: "nearest", behavior: "instant"})
        const context = this.el.querySelector(".mail-reader-context")
        if (context && target) {
          const overlap = context.getBoundingClientRect().bottom + 16 - target.getBoundingClientRect().top
          if (overlap > 0) this.scroller().scrollTop -= overlap
        }
        target?.focus({preventScroll: true})
      })
    } else if (this.returnPending && this.el.querySelector("#mail-threads")) {
      this.returnPending = false
      const position = this.returnPosition
      this.schedule(() => {
        const row = this.el.ownerDocument.getElementById(position.id)
        const target = row && this.el.contains(row) ? row : this.el.querySelector("#mail-heading")
        target?.focus({preventScroll: true})
        this.scroller().scrollTop = position.top
      })
    }
  },

  schedule(callback) {
    this.cancelFrame()
    const context = this.context, thread = this.thread
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      const pane = this.el.ownerDocument.getElementById("workspace-pane")
      // A delayed mail load must never wake Escape/idle scenery mode.
      if (pane?.getAttribute("aria-pressed") === "false") return
      if (this.el.dataset.mailContext === context && this.el.dataset.mailThread === thread) {
        this.handingOff = true
        try { callback() } finally { this.handingOff = false }
      }
    })
  },

  destroyed() {
    this.cancelFrame()
    this.el.removeEventListener("click", this.rememberPosition, true)
    this.el.ownerDocument.removeEventListener("keydown", this.cancelHandoff, true)
    this.el.ownerDocument.removeEventListener("pointerdown", this.cancelHandoff, true)
    this.el.ownerDocument.removeEventListener("input", this.cancelHandoff, true)
    this.el.ownerDocument.removeEventListener("focusin", this.onFocus, true)
    this.view.removeEventListener("popstate", this.beginNavigation, true)
    this.view.removeEventListener("phx:page-loading-start", this.beginNavigation)
    this.returnPosition = null
  },
}
