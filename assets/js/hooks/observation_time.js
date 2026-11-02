export function observationText(timestamp, failed, now = Date.now()) {
  const at = Date.parse(timestamp)
  if (!Number.isFinite(at)) return "Unread count update unavailable"
  const seconds = Math.max(0, Math.floor((now - at) / 1000))
  const age = seconds < 60 ? "just now"
    : seconds < 3600 ? `${Math.floor(seconds / 60)} min ago`
    : seconds < 86400 ? `${Math.floor(seconds / 3600)} hr ago`
    : `${Math.floor(seconds / 86400)} ${seconds < 172800 ? "day" : "days"} ago`
  return `${failed || seconds >= 180 ? "Stale · last checked" : "Checked"} ${age}`
}

export default {
  mounted() {
    this.updateObservation = () => {
      const {observedAt, failed} = this.el.dataset
      this.el.textContent = observationText(observedAt, failed === "true")
      this.el.title = observedAt
    }
    this.updateObservation()
    this.observationTimer = setInterval(this.updateObservation, 30_000)
    this.el.ownerDocument.addEventListener("visibilitychange", this.updateObservation)
  },
  updated() { this.updateObservation() },
  destroyed() {
    clearInterval(this.observationTimer)
    this.el.ownerDocument.removeEventListener("visibilitychange", this.updateObservation)
  },
}
