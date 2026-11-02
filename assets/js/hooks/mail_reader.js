// Navigation memory is ephemeral and scoped to one account/list context. No mail
// bodies, queries or navigation state are persisted in browser storage.
export default {
  mounted() {
    this.context = this.el.dataset.mailContext
    this.thread = this.el.dataset.mailThread
    this.returnPosition = null
    this.readerPending = Boolean(this.thread)
    this.returnPending = false
    this.frame = null
    this.cancelHandoff = () => {
      this.readerPending = false
      this.returnPending = false
      this.cancelFrame()
    }
    this.rememberPosition = event => {
      const row = event.target.closest("[data-mail-open-thread]")
      if (row && this.el.contains(row) && !this.thread) {
        this.returnPosition = {id: row.id, top: this.scroller().scrollTop}
      }
      // A new intentional control action must not lose focus to a pending load.
      if (!row && !event.target.closest("#mail-back")) this.cancelHandoff()
    }
    this.el.addEventListener("click", this.rememberPosition, true)
    this.el.ownerDocument.addEventListener("keydown", this.cancelHandoff, true)
    this.el.ownerDocument.addEventListener("pointerdown", this.cancelHandoff, true)
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
    const {mailContext: context, mailThread: thread, mailLoaded: loaded} = this.el.dataset
    if (context !== this.context) {
      this.cancelFrame()
      this.context = context
      this.returnPosition = null
      this.returnPending = false
      this.readerPending = false
    }
    if (thread !== this.thread) {
      this.cancelFrame()
      this.readerPending = Boolean(thread)
      this.returnPending = !thread && Boolean(this.returnPosition)
      this.thread = thread
    }
    if (loaded !== "true") return

    if (this.readerPending && this.el.querySelector("#mail-conversation-heading")) {
      this.readerPending = false
      this.schedule(() => {
        const heading = this.el.querySelector("#mail-conversation-heading")
        const latest = this.el.querySelector('[data-mail-latest="true"]')
        heading?.focus({preventScroll: true})
        // Keep earlier summaries accessible above, but begin at the latest reply.
        ;(latest || heading)?.scrollIntoView({block: "start", behavior: "instant"})
      })
    } else if (this.returnPending && this.el.querySelector("#mail-threads")) {
      this.returnPending = false
      const position = this.returnPosition
      this.returnPosition = null
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
      if (this.el.dataset.mailContext === context && this.el.dataset.mailThread === thread) callback()
    })
  },

  destroyed() {
    this.cancelFrame()
    this.el.removeEventListener("click", this.rememberPosition, true)
    this.el.ownerDocument.removeEventListener("keydown", this.cancelHandoff, true)
    this.el.ownerDocument.removeEventListener("pointerdown", this.cancelHandoff, true)
    this.returnPosition = null
  },
}
