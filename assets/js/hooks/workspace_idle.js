// Keep idle state outside server assigns: a LiveView patch is not user activity.
// Execute the shared HEEx commands so aria-pressed stays sticky across patches.
const activityEvents = ["pointerdown", "click", "keydown", "wheel", "scroll", "touchstart", "touchmove"]
const wakeEvents = new Set(["pointerdown", "click", "keydown", "touchstart"])

export default {
  mounted() {
    this.document = this.el.ownerDocument
    this.window = this.document.defaultView
    this.lastActivity = this.window.Date.now()
    this.idle = false

    this.onActivity = event => {
      // A throttled timer may not have run yet after tab/system sleep.
      this.expireIfNeeded()
      this.lastActivity = this.window.Date.now()
      if (wakeEvents.has(event.type) && !(event.type === "keydown" && event.key === "Escape")) {
        if (this.idle || this.el.querySelector("#workspace-pane").getAttribute("aria-pressed") !== "true") {
          this.command("focus")
        }
        this.idle = false
      }
      this.schedule()
    }
    this.onVisibility = () => {
      this.expireIfNeeded()
      this.schedule()
    }
    this.onModalClosed = () => {
      this.lastActivity = this.window.Date.now()
      this.schedule()
    }
    this.document.addEventListener("lovelace:modal-closed", this.onModalClosed)

    // Capture scroll (which doesn't bubble) and input without preventing its
    // normal action or moving keyboard focus. Mouse movement is never observed.
    for (const event of activityEvents) {
      this.document.addEventListener(event, this.onActivity, {capture: true, passive: true})
    }
    this.document.addEventListener("visibilitychange", this.onVisibility)
    this.schedule()
  },

  duration() {
    const minutes = Number(this.el.dataset.idleMinutes)
    return (Number.isFinite(minutes) && minutes > 0 ? minutes : 3) * 60_000
  },

  command(name) {
    this.js().exec(this.el.getAttribute(`data-workspace-${name}`))
  },

  modalOpen() {
    // Presence also covers the patch before the dialog's hook calls showModal.
    return !!this.el.querySelector("dialog[data-modal]")
  },

  expireIfNeeded() {
    if (this.modalOpen()) return
    if (!this.idle && this.window.Date.now() - this.lastActivity >= this.duration()) {
      this.idle = true
      // This command sets aria-pressed=false AND resets the independent brand.
      // CSS visually defocuses content; never call DOM blur(): the next key
      // should still reach the existing control, sharpening it before input.
      this.command("reset")
    }
  },

  schedule() {
    this.window.clearTimeout(this.timer)
    if (this.idle || this.modalOpen()) return
    const remaining = this.duration() - (this.window.Date.now() - this.lastActivity)
    this.timer = this.window.setTimeout(() => {
      this.expireIfNeeded()
      this.schedule()
    }, Math.min(Math.max(remaining, 1), 2_147_483_647))
  },

  updated() {
    // New background/status/config markup must not renew the activity timestamp.
    this.expireIfNeeded()
    this.schedule()
  },

  destroyed() {
    this.window.clearTimeout(this.timer)
    for (const event of activityEvents) {
      this.document.removeEventListener(event, this.onActivity, true)
    }
    this.document.removeEventListener("visibilitychange", this.onVisibility)
    this.document.removeEventListener("lovelace:modal-closed", this.onModalClosed)
  },
}
