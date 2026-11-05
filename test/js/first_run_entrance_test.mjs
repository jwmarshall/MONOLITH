import assert from "node:assert/strict"
import test from "node:test"
import {initFirstRunEntrance} from "../../assets/js/first_run_entrance.js"
import {gsap} from "../../assets/vendor/gsap/gsap.js"

const SEEN_KEY = "lovelace:first-run-entrance:session:v1"
const LEGACY_KEY = "lovelace:first-run-entrance:v1"

class Target extends EventTarget {
  attributes = new Map()
  listeners = new Map()
  setAttribute(name, value) { this.attributes.set(name, value) }
  removeAttribute(name) { this.attributes.delete(name) }
  hasAttribute(name) { return this.attributes.has(name) }
  addEventListener(type, listener) {
    super.addEventListener(type, listener)
    if (!this.listeners.has(type)) this.listeners.set(type, new Set())
    this.listeners.get(type).add(listener)
  }
  removeEventListener(type, listener) {
    super.removeEventListener(type, listener)
    this.listeners.get(type)?.delete(listener)
  }
  emit(type) { this.dispatchEvent(new Event(type)) }
  get listenerCount() { return [...this.listeners.values()].reduce((sum, listeners) => sum + listeners.size, 0) }
}

function page(t, options = {}) {
  const document = {body: {}, documentElement: {}, referrer: options.referrer || ""}
  const view = new Target()
  view.location = {origin: "http://localhost:4322"}
  view.performance = {getEntriesByType: () => [{type: options.navigation || "navigate"}]}
  const values = options.values || new Map()
  const sessionValues = options.sessionValues || new Map()
  const storageAccesses = []
  const storage = values => ({
    getItem: key => {
      if (options.readFailure) throw new Error("unavailable")
      return values.get(key) ?? null
    },
    setItem: (key, value) => {
      if (options.writeFailure) throw new Error("unavailable")
      values.set(key, value)
    },
  })
  for (const [name, entries] of [["localStorage", values], ["sessionStorage", sessionValues]]) {
    Object.defineProperty(view, name, {get: () => {
      storageAccesses.push(name)
      if (options.noStorage || (options.noSessionStorage && name === "sessionStorage") ||
          (options.noLocalStorage && name === "localStorage")) throw new Error("unavailable")
      return storage(entries)
    }})
  }
  const preference = new Target()
  preference.matches = options.reduced || false
  view.matchMedia = () => preference
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window")
  document.defaultView = view
  document.activeElement = options.focused || document.body
  const heading = {focus: () => { document.activeElement = heading }}
  const main = new Target()
  main.querySelector = selector => selector === "h1" ? heading : null
  const brand = new Target()
  brand.hidden = true
  const stroke = {strokeDasharray: 0, strokeDashoffset: 0, getTotalLength: () => 100}
  const letters = Array.from({length: 8}, () => ({opacity: 1, rotationX: 0, yPercent: 0}))
  brand.querySelector = () => stroke
  brand.querySelectorAll = () => letters
  const stage = new Target()
  stage.dataset = {firstRunEntrance: options.eligible === false ? "false" : "true"}
  stage.querySelector = selector => {
    if (selector === "#main-content") return options.noMain ? null : main
    return options.noBrand ? null : brand
  }
  document.querySelector = () => options.noStage ? null : stage
  t.after(() => {
    view.emit("pagehide")
    gsap.ticker.sleep()
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow)
    else delete globalThis.window
  })
  const start = () => {
    Object.defineProperty(globalThis, "window", {configurable: true, value: view})
    try {
      initFirstRunEntrance(document)
    } finally {
      if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow)
      else delete globalThis.window
      gsap.ticker.sleep()
    }
  }
  return {document, view, stage, main, brand, heading, preference, values, sessionValues, storageAccesses, start}
}

function assertUsable({main, brand, stage}) {
  assert.equal(main.hasAttribute("inert"), false)
  assert.equal(brand.hidden, true)
  assert.equal(stage.hasAttribute("data-first-run-state"), false)
}

test("first eligible visit claims a tab-session marker and gates main only until completion", t => {
  const current = page(t)
  current.start()
  assert.equal(current.sessionValues.get(SEEN_KEY), "seen")
  assert.equal(current.values.size, 0)
  assert.deepEqual(current.storageAccesses, ["sessionStorage"])
  assert.equal(current.main.hasAttribute("inert"), true)
  assert.equal(current.brand.hidden, false)
  current.brand.emit("lovelace:brand-complete")
  assertUsable(current)
  assert.equal(current.document.activeElement, current.heading)
  assert.equal(current.view.listenerCount, 0)
  assert.equal(current.brand.listenerCount, 0)
  assert.equal(current.preference.listenerCount, 0)
})

test("legacy persistent and session markers cannot suppress a fresh introduction", t => {
  const current = page(t, {
    values: new Map([[LEGACY_KEY, "seen"], [SEEN_KEY, "seen"]]),
    sessionValues: new Map([[LEGACY_KEY, "seen"]]),
  })
  current.start()
  assert.equal(current.main.hasAttribute("inert"), true)
  assert.equal(current.brand.hidden, false)
  assert.equal(current.sessionValues.get(SEEN_KEY), "seen")
  assert.deepEqual(current.storageAccesses, ["sessionStorage"])
})

test("a claimed session skips subsequent steps and a new session on the same origin plays", t => {
  const first = page(t)
  first.start()
  first.view.emit("pagehide")

  const next = page(t, {values: first.values, sessionValues: first.sessionValues})
  next.start()
  assertUsable(next)
  assert.equal(next.view.listenerCount, 0)

  const fresh = page(t, {values: first.values})
  fresh.start()
  assert.equal(fresh.main.hasAttribute("inert"), true)
  assert.equal(fresh.brand.hidden, false)
})

for (const navigation of ["reload", "back_forward"]) {
  test(`${navigation} plays without a claim, then skips after an interrupted entrance`, t => {
    const first = page(t, {navigation})
    first.start()
    assert.equal(first.main.hasAttribute("inert"), true)
    assert.equal(first.sessionValues.get(SEEN_KEY), "seen")
    first.view.emit("pagehide")
    assertUsable(first)

    const returned = page(t, {navigation, sessionValues: first.sessionValues})
    returned.start()
    assertUsable(returned)
    assert.equal(returned.view.listenerCount, 0)
  })
}

for (const referrer of ["http://localhost:4322/setup", "http://localhost:4322/onboarding/project"]) {
  test(`a flow referrer cannot substitute for a session claim: ${referrer}`, t => {
    const first = page(t, {referrer})
    first.start()
    assert.equal(first.main.hasAttribute("inert"), true)
    first.view.emit("pagehide")

    const next = page(t, {referrer, sessionValues: first.sessionValues})
    next.start()
    assertUsable(next)
  })
}

test("ineligible POST, paired setup and error pages do not consume the introduction", t => {
  const ineligible = page(t, {eligible: false})
  ineligible.start()
  assertUsable(ineligible)
  assert.equal(ineligible.sessionValues.size, 0)
  assert.deepEqual(ineligible.storageAccesses, [])

  const pairing = page(t, {sessionValues: ineligible.sessionValues})
  pairing.start()
  assert.equal(pairing.main.hasAttribute("inert"), true)
})

for (const missing of ["noStage", "noMain", "noBrand"]) {
  test(`missing required markup (${missing}) does not consume a session claim`, t => {
    const current = page(t, {[missing]: true})
    current.start()
    assertUsable(current)
    assert.equal(current.sessionValues.size, 0)
    assert.deepEqual(current.storageAccesses, [])
  })
}

test("unavailable persistent storage does not affect the session introduction", t => {
  const current = page(t, {noLocalStorage: true})
  current.start()
  assert.equal(current.main.hasAttribute("inert"), true)
  assert.equal(current.sessionValues.get(SEEN_KEY), "seen")
})

for (const failure of ["noStorage", "noSessionStorage", "readFailure", "writeFailure"]) {
  test(`session storage failure (${failure}) skips without gating controls or persisting a fallback`, t => {
    const current = page(t, {[failure]: true})
    current.start()
    assertUsable(current)
    assert.equal(current.sessionValues.size, 0)
    assert.equal(current.values.size, 0)
    assert.deepEqual(current.storageAccesses, ["sessionStorage"])
  })
}

test("reduced motion completes immediately and collects animation listeners", t => {
  const current = page(t, {reduced: true})
  current.start()
  assertUsable(current)
  assert.equal(current.document.activeElement, current.heading)
  assert.equal(current.preference.listenerCount, 0)
})

test("a mid-animation reduced-motion change opens the gate immediately", t => {
  const current = page(t)
  current.start()
  current.preference.matches = true
  current.preference.emit("change")
  assertUsable(current)
  assert.equal(current.preference.listenerCount, 0)
})

test("an already focused control is neither gated nor overwritten", t => {
  const focused = {}
  const current = page(t, {focused})
  current.start()
  assertUsable(current)
  assert.equal(current.document.activeElement, focused)
  assert.equal(current.sessionValues.size, 0)
  assert.deepEqual(current.storageAccesses, [])

  const pairing = page(t, {sessionValues: current.sessionValues})
  pairing.start()
  assert.equal(pairing.main.hasAttribute("inert"), true)
})

test("completion does not replace focus established outside main", t => {
  const current = page(t)
  current.start()
  const skipLink = {}
  current.document.activeElement = skipLink
  current.brand.emit("lovelace:brand-complete")
  assertUsable(current)
  assert.equal(current.document.activeElement, skipLink)
})

test("Escape completes the existing choreography without leaving a gate", t => {
  const current = page(t)
  current.start()
  const event = new Event("keydown")
  Object.defineProperty(event, "key", {value: "Escape"})
  current.view.dispatchEvent(event)
  assertUsable(current)
})

test("pagehide restores controls and removes listeners before a cached return", t => {
  const current = page(t)
  current.start()
  current.view.emit("pagehide")
  assertUsable(current)
  assert.equal(current.document.activeElement, current.document.body)
  assert.equal(current.view.listenerCount, 0)
  assert.equal(current.brand.listenerCount, 0)
  assert.equal(current.preference.listenerCount, 0)
})

test("repeated initialization does not restart or duplicate an active entrance", t => {
  const current = page(t)
  current.start()
  const viewListeners = current.view.listenerCount
  const brandListeners = current.brand.listenerCount
  current.start()
  assert.equal(current.main.hasAttribute("inert"), true)
  assert.equal(current.view.listenerCount, viewListeners)
  assert.equal(current.brand.listenerCount, brandListeners)
  current.brand.emit("lovelace:brand-complete")
  assertUsable(current)
  assert.equal(current.view.listenerCount, 0)
  assert.equal(current.brand.listenerCount, 0)
})
