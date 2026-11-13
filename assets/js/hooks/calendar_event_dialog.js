// Local read-only disclosure. Provider content is always assigned as text, and
// the server + client both restrict the optional Calendar destination.
export default {
  mounted() {
    this.document = this.el.ownerDocument
    this.view = this.document.defaultView
    this.dialog = this.el.querySelector("[data-calendar-dialog]")
    this.onClick = event => {
      const trigger = event.target.closest("[data-calendar-event-open]")
      if (!trigger || !this.el.contains(trigger)) return
      this.opener = trigger
      this.openerIdentity = trigger.closest(".calendar-event")?.id
      const data = trigger.dataset
      for (const [name, value] of [["title", data.eventTitle], ["account", data.eventAccount], ["calendar", data.eventCalendar], ["time", trigger.closest(".calendar-event")?.querySelector("[data-calendar-time-text]")?.textContent]]) {
        this.dialog.querySelector(`[data-calendar-dialog-${name}]`).textContent = value || "Unavailable"
      }
      const link = this.dialog.querySelector("[data-calendar-dialog-link]")
      let safe = false
      try {
        const url = new URL(data.eventUrl)
        safe = url.protocol === "https:" && ["calendar.google.com", "www.google.com"].includes(url.hostname) && !url.username && !url.password && !url.port && (url.pathname === "/calendar" || url.pathname.startsWith("/calendar/"))
      } catch { /* Missing destinations stay unavailable. */ }
      link.hidden = !safe
      if (safe) link.href = data.eventUrl
      else link.removeAttribute("href")
      this.dialog.setAttribute("data-modal", "")
      this.dialog.showModal()
      this.js().setAttribute(this.dialog, "open", "")
      this.js().setAttribute(this.dialog, "data-modal", "")
      this.dialog.querySelector("button")?.focus({preventScroll: true})
    }
    this.onEscape = event => {
      if (event.key !== "Escape" || !this.dialog.open) return
      event.preventDefault()
      event.stopImmediatePropagation()
      this.dialog.close()
    }
    this.onClose = () => {
      this.js().removeAttribute(this.dialog, "open")
      this.js().removeAttribute(this.dialog, "data-modal")
      this.document.dispatchEvent(new this.view.Event("monolith:modal-closed"))
      const sameOccurrence = this.opener?.isConnected &&
        this.opener.closest(".calendar-event")?.id === this.openerIdentity
      const target = sameOccurrence ? this.opener : this.document.querySelector("[data-workspace-heading]")
      target?.focus({preventScroll: true})
      this.opener = null
      this.openerIdentity = null
    }
    this.el.addEventListener("click", this.onClick)
    this.view.addEventListener("keydown", this.onEscape, true)
    this.dialog.addEventListener("close", this.onClose)
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.view.removeEventListener("keydown", this.onEscape, true)
    this.dialog.removeEventListener("close", this.onClose)
    if (this.dialog.open) this.dialog.close()
    this.dialog.removeAttribute("data-modal")
    this.opener = null
  },
}
