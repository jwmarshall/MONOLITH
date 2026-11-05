import {gsap} from "../../vendor/gsap/gsap.js"

// Both static first-run pages and LiveView use this one decorative choreography.
// CSS owns the glass/background focal planes; server rendering owns application state.
const BrandAnimation = {
  initialize() {
    const stroke = this.el.querySelector("#lovelace-monogram-stroke")
    const letters = this.el.querySelectorAll(".workspace-letter")
    const length = stroke.getTotalLength()

    this.active = false
    this.completed = false
    this.exiting = false
    this.motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.context = gsap.context(() => {
      this.timeline = gsap.timeline({
        paused: true,
        onComplete: () => {
          if (this.active) this.complete()
        },
      })
        .fromTo(stroke,
          {strokeDasharray: length, strokeDashoffset: length},
          {strokeDashoffset: 0, duration: 1.35, ease: "power2.inOut", immediateRender: true},
          0.2)
        .fromTo(letters,
          {opacity: 0, rotationX: -90, yPercent: 60},
          {opacity: 1, rotationX: 0, yPercent: 0, duration: 0.6,
            stagger: 0.085, ease: "power3.out", immediateRender: true},
          1.35)
        .to({}, {duration: 0.25})
        .addLabel("exit")
        .call(() => { this.exiting = true })
        // Continue the flip upward, left-to-right, and erase from the opposite
        // end of the stroke instead of playing the entrance backward.
        .to(letters,
          {opacity: 0, rotationX: 90, yPercent: -60, duration: 0.6 / 1.8,
            stagger: 0.085 / 1.8, ease: "power3.in"},
          "exit")
        .to(stroke,
          {strokeDashoffset: -length, duration: 1.35 / 1.8, ease: "power2.inOut"},
          "exit+=0.55")
    }, this.el)

    this.onFocus = () => this.reveal()
    this.onReset = () => {
      this.active = false
      // Freeze in place while CSS fades the glass out. The next focus starts fresh.
      this.timeline.pause()
    }
    this.onMotionChange = () => {
      if (this.active && this.motionPreference.matches) this.finishWithoutMotion()
    }

    this.el.addEventListener("lovelace:brand-focus", this.onFocus)
    this.el.addEventListener("lovelace:brand-reset", this.onReset)
    this.motionPreference.addEventListener("change", this.onMotionChange)
  },

  reveal() {
    // Pointer focus and click can fire together. Never restart an active reveal.
    if (this.active || this.completed) return
    this.active = true
    this.exiting = false

    if (this.motionPreference.matches) this.finishWithoutMotion()
    else this.timeline.timeScale(1).restart()
  },

  finishWithoutMotion() {
    // Suppress callbacks and skip both entrance and exit for reduced motion or
    // a return to an already unlocked workspace, including during an active exit.
    this.timeline.progress(1, true).pause()
    this.complete()
  },

  complete() {
    if (this.completed) return
    this.completed = true
    this.el.dispatchEvent(new CustomEvent("lovelace:brand-complete", {bubbles: true}))
  },

  destroy() {
    this.el.removeEventListener("lovelace:brand-focus", this.onFocus)
    this.el.removeEventListener("lovelace:brand-reset", this.onReset)
    this.motionPreference.removeEventListener("change", this.onMotionChange)
    this.context.revert()
  },
}

export function createBrandReveal(el) {
  const animation = Object.assign({el}, BrandAnimation)
  animation.initialize()
  return animation
}

export default {
  ...BrandAnimation,

  mounted() {
    this.initialize()
    const root = this.el.closest("#workspace")
    if (root.querySelector("#main-content").getAttribute("data-enter-on-return") === "true") {
      this.finishWithoutMotion()
    } else {
      // Also handle focus established before the LiveView hook finished mounting.
      const pane = root.querySelector("#workspace-pane")
      if (pane.getAttribute("aria-pressed") === "true") this.reveal()
    }
  },

  destroyed() {
    this.destroy()
  },
}
