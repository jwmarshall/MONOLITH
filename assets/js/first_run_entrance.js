import {createBrandReveal} from "./hooks/brand_reveal.js"

// This tab-session boolean is presentation state only. A previous installation
// on the same origin must not suppress a fresh session's introduction.
const SEEN_KEY = "lovelace:first-run-entrance:session:v1"

function claimEntrance(view) {
  try {
    const storage = view.sessionStorage
    if (storage.getItem(SEEN_KEY) === "seen") return false
    // Claim before playing so reloads and interrupted animations do not replay.
    storage.setItem(SEEN_KEY, "seen")
    return true
  } catch {
    // Without session storage, leave the ordinary form immediately usable.
    return false
  }
}

export function initFirstRunEntrance(document = window.document) {
  const stage = document.querySelector("[data-first-run-entrance]")
  if (!stage) return
  const view = document.defaultView
  const main = stage.querySelector("#main-content")
  const brand = stage.querySelector("[data-static-brand]")
  const active = document.activeElement
  if (stage.dataset.firstRunEntrance !== "true" || !main || !brand ||
      (active && active !== document.body && active !== document.documentElement)) return
  if (!claimEntrance(view)) return

  let animation
  let finished = false
  const wasInert = main.hasAttribute("inert")
  const cleanup = () => {
    brand.removeEventListener("lovelace:brand-complete", onComplete)
    view.removeEventListener("keydown", onKeydown)
    view.removeEventListener("pagehide", onPagehide)
    animation?.destroy()
  }
  const finish = (focus = true) => {
    if (finished) return
    finished = true
    cleanup()
    brand.hidden = true
    stage.removeAttribute("data-first-run-state")
    if (!wasInert) main.removeAttribute("inert")
    if (focus && (!document.activeElement || document.activeElement === document.body ||
        document.activeElement === document.documentElement)) {
      main.querySelector("h1")?.focus({preventScroll: true})
    }
  }
  const onComplete = () => finish()
  const onKeydown = event => {
    if (event.key === "Escape") animation.finishWithoutMotion()
  }
  // Restore the page before a potential back/forward-cache snapshot. Never leave
  // an inert form or running listeners/timeline behind on document navigation.
  const onPagehide = () => finish(false)

  try {
    animation = createBrandReveal(brand)
    brand.addEventListener("lovelace:brand-complete", onComplete)
    view.addEventListener("keydown", onKeydown)
    view.addEventListener("pagehide", onPagehide)
    main.setAttribute("inert", "")
    stage.setAttribute("data-first-run-state", "playing")
    brand.hidden = false
    animation.reveal()
  } catch {
    // The no-JS and failed-animation paths share the ordinary usable form.
    finish(false)
  }
}
