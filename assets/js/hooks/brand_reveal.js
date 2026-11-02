import {gsap} from "../../vendor/gsap/gsap.js"

// Only this decorative, phx-update="ignore" subtree belongs to GSAP.
// CSS owns the glass/background focal planes; LiveView owns application state.
export default {
  mounted() {
    const stroke = this.el.querySelector("#lovelace-monogram-stroke")
    const letters = this.el.querySelectorAll(".workspace-letter")
    const length = stroke.getTotalLength()

    this.active = false
    this.completed = false
    this.motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.context = gsap.context(() => {
      this.timeline = gsap.timeline({paused: true, onComplete: () => this.complete()})
        .fromTo(stroke,
          {strokeDasharray: length, strokeDashoffset: length},
          {strokeDashoffset: 0, duration: 1.35, ease: "power2.inOut", immediateRender: true},
          0.2)
        .fromTo(letters,
          {opacity: 0, rotationX: -90, yPercent: 60},
          {opacity: 1, rotationX: 0, yPercent: 0, duration: 0.6,
            stagger: 0.085, ease: "power3.out", immediateRender: true},
          1.35)
    }, this.el)

    this.onFocus = () => this.reveal()
    this.onReset = () => {
      this.active = false
      // Freeze in place while CSS fades the glass out. The next focus starts fresh.
      this.timeline.pause()
    }
    this.onMotionChange = () => {
      if (this.active && this.motionPreference.matches) this.timeline.progress(1).pause()
    }

    this.el.addEventListener("lovelace:brand-focus", this.onFocus)
    this.el.addEventListener("lovelace:brand-reset", this.onReset)
    this.motionPreference.addEventListener("change", this.onMotionChange)

    // Also handle focus established before the LiveView hook finished mounting.
    const pane = this.el.closest("#workspace").querySelector("#workspace-pane")
    if (pane.getAttribute("aria-pressed") === "true") this.reveal()
  },

  reveal() {
    // Pointer focus and click can fire together. Never restart an active reveal.
    if (this.active || this.completed) return
    this.active = true

    if (this.motionPreference.matches) this.timeline.progress(1).pause()
    else this.timeline.restart()
  },

  complete() {
    if (this.completed) return
    this.completed = true
    this.el.dispatchEvent(new CustomEvent("lovelace:brand-complete", {bubbles: true}))
  },

  destroyed() {
    this.el.removeEventListener("lovelace:brand-focus", this.onFocus)
    this.el.removeEventListener("lovelace:brand-reset", this.onReset)
    this.motionPreference.removeEventListener("change", this.onMotionChange)
    this.context.revert()
  },
}
