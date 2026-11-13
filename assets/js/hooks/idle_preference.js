export const IDLE_KEY = "monolith:idle-minutes"
export function idleMinutes(value, fallback = 3) {
  const number = Number(value)
  return Number.isInteger(number) && number >= 1 && number <= 60 ? number : fallback
}
export function savedIdleMinutes(view, fallback = 3) {
  try { return idleMinutes(view.localStorage.getItem(IDLE_KEY), fallback) }
  catch { return fallback }
}
export default {
  mounted() {
    this.view = this.el.ownerDocument.defaultView
    this.input = this.el.querySelector("[name=minutes]")
    this.status = this.el.querySelector("[data-idle-status]")
    this.input.value = savedIdleMinutes(this.view, idleMinutes(this.el.dataset.defaultMinutes))
    this.onSubmit = event => {
      event.preventDefault()
      if (!this.el.reportValidity()) return
      const minutes = idleMinutes(this.input.value)
      let persisted = true
      try { this.view.localStorage.setItem(IDLE_KEY, String(minutes)) }
      catch { persisted = false }
      this.view.dispatchEvent(new this.view.CustomEvent("monolith:idle-preference", {detail: {minutes}}))
      this.status.textContent = persisted ? "Scenery preference saved in this browser." : "Applied for this page. Browser storage is unavailable; your preference couldn’t be saved."
    }
    this.el.addEventListener("submit", this.onSubmit)
  },
  destroyed() { this.el.removeEventListener("submit", this.onSubmit) },
}
