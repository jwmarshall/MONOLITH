// Decorative ownership only. Artwork and native keyframes match the authored
// identity.js playEntrance; application and provider work never belong here.
const BrandAnimation = {
  initialize() {
    this.active = false
    this.completed = false
    this.disposed = false
    this.animations = []
    this.view = this.el.ownerDocument?.defaultView || window
    this.motionPreference = this.view.matchMedia("(prefers-reduced-motion: reduce)")
    this.onFocus = () => this.reveal()
    this.onReset = () => { if (this.active) this.finishWithoutMotion() }
    this.onMotionChange = () => { if (this.active && this.motionPreference.matches) this.finishWithoutMotion() }
    this.onNavigate = () => { if (this.active) this.finishWithoutMotion() }
    this.el.addEventListener("monolith:brand-focus", this.onFocus)
    this.el.addEventListener("monolith:brand-reset", this.onReset)
    this.motionPreference.addEventListener("change", this.onMotionChange)
    this.view.addEventListener("beforeprint", this.onNavigate)
    this.view.addEventListener("phx:page-loading-start", this.onNavigate)
  },
  animate(element, frames, options) {
    const animation = element.animate(frames, {...options, fill: "both"})
    this.animations.push(animation)
    return animation.finished.catch(() => {})
  },
  async play() {
    const svg = this.el.querySelector("svg")
    const letters = [...this.el.querySelectorAll(".workspace-letter")]
    const trace = (path, duration, delay) => this.animate(path, [
      {strokeDashoffset: 1, opacity: 0},
      {strokeDashoffset: 1, opacity: 1, offset: .001},
      {strokeDashoffset: 0, opacity: 1},
    ], {duration, delay, easing: "cubic-bezier(.45,0,.2,1)"})
    await Promise.all([
      ...[...svg.querySelectorAll("[data-layer=outline] path")].map(path => trace(path, 1600, 180)),
      ...[...svg.querySelectorAll("[data-layer=inner] path")].map((path, index) => trace(path, index ? 500 : 1100, index ? 1850 : 1100)),
      ...letters.map((letter, index) => this.animate(letter, [
        {opacity: 0, transform: "translateY(60%) rotateX(-90deg)"},
        {opacity: 1, transform: "translateY(0) rotateX(0deg)"},
      ], {duration: 600, delay: 2600 + index * 85, easing: "cubic-bezier(.16,1,.3,1)"})),
    ])
    if (!this.active || this.disposed) return
    await this.animate(this.el, [{opacity: 1}, {opacity: 1}], {duration: 360})
    if (!this.active || this.disposed) return
    await Promise.all([
      this.animate(svg, [
        {opacity: 1, transform: "translateY(0)"},
        {opacity: 0, transform: "translateY(-12px)"},
      ], {duration: 900, delay: 150, easing: "cubic-bezier(.65,0,.35,1)"}),
      ...letters.map((letter, index) => this.animate(letter, [
        {opacity: 1, transform: "translateY(0) rotateX(0deg)"},
        {opacity: 0, transform: "translateY(-60%) rotateX(90deg)"},
      ], {duration: 600 / 1.8, delay: index * 85 / 1.8, easing: "cubic-bezier(.7,0,.84,0)"})),
    ])
    if (this.active && !this.disposed) this.complete()
  },
  reveal() {
    if (this.active || this.completed || this.disposed) return
    this.active = true
    if (this.motionPreference.matches) this.finishWithoutMotion()
    else this.play()
  },
  restore() {
    this.animations.forEach(animation => animation.cancel())
    this.animations = []
  },
  finishWithoutMotion() { this.complete() },
  complete() {
    if (this.completed || this.disposed) return
    this.active = false
    this.completed = true
    this.restore()
    this.el.dispatchEvent(new CustomEvent("monolith:brand-complete", {bubbles: true}))
  },
  destroy() {
    this.disposed = true
    this.active = false
    this.el.removeEventListener("monolith:brand-focus", this.onFocus)
    this.el.removeEventListener("monolith:brand-reset", this.onReset)
    this.motionPreference.removeEventListener("change", this.onMotionChange)
    this.view.removeEventListener("beforeprint", this.onNavigate)
    this.view.removeEventListener("phx:page-loading-start", this.onNavigate)
    this.restore()
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
    if (root.querySelector("#main-content").getAttribute("data-enter-on-return") === "true") this.finishWithoutMotion()
    else if (root.querySelector("#workspace-pane").getAttribute("aria-pressed") === "true") this.reveal()
  },
  destroyed() { this.destroy() },
}
