import assert from "node:assert/strict"
import test from "node:test"
import StatusSignal from "../../assets/js/hooks/status_signal.js"

class Target {
  listeners = new Map()
  attributes = new Map()
  style = {setProperty: (name, value) => this.attributes.set(name, value)}
  addEventListener(name, fn) { assert.equal(this.listeners.has(name), false); this.listeners.set(name, fn) }
  removeEventListener(name, fn) {
    assert.equal(this.listeners.get(name), fn)
    this.listeners.delete(name)
  }
  setAttribute(name, value) { this.attributes.set(name, value) }
  removeAttribute(name) { this.attributes.delete(name) }
}

function fixture(embedded = false, text = false) {
  const el = new Target()
  const link = new Target()
  const window = new Target()
  window.innerWidth = 390
  window.innerHeight = 844
  window.getComputedStyle = () => ({display: el.attributes.has("data-tooltip-dismissed") || el.detailVisible === false ? "none" : "block"})
  el.ownerDocument = {defaultView: window}
  el.dataset = {embedded: String(embedded)}
  el.closest = selector => selector === "a" ? link : {getBoundingClientRect: () => ({left: 43, right: 347, bottom: 820})}
  el.getBoundingClientRect = () => ({left: 300, bottom: 800})
  el.text = text
  el.querySelector = selector => { assert.equal(selector, ".status-tooltip"); return el.text ? null : {getBoundingClientRect: () => ({height: 60})} }
  const hook = {...StatusSignal, el}
  hook.mounted()
  return {el, link, window, hook, trigger: embedded ? link : el}
}

test("Escape dismisses details without also entering scenery mode; focus resets them", () => {
  const {el, hook, trigger, window} = fixture()
  let stopped = 0
  window.listeners.get("keydown")({key: "a", stopPropagation() { stopped++ }})
  assert.equal(el.attributes.has("data-tooltip-dismissed"), false)
  window.listeners.get("keydown")({key: "Escape", stopPropagation() { stopped++ }})
  assert.equal(stopped, 1)
  window.listeners.get("keydown")({key: "Escape", stopPropagation() { stopped++ }})
  assert.equal(stopped, 1, "second Escape belongs to the shell when the detail is already closed")
  assert.equal(el.attributes.has("data-tooltip-dismissed"), true)
  el.ownerDocument.activeElement = trigger
  el.listeners.get("pointerleave")()
  assert.equal(el.attributes.has("data-tooltip-dismissed"), true, "mouse leave must not reopen a focused, dismissed detail")
  trigger.listeners.get("blur")()
  assert.equal(el.attributes.has("data-tooltip-dismissed"), false)
  trigger.listeners.get("focus")()
  hook.destroyed()
  assert.equal(el.listeners.size, 0)
})

test("embedded signals use the existing link focus, with complete listener teardown", () => {
  const {el, link, window, hook, trigger} = fixture(true)
  assert.equal(trigger, link)
  assert.equal(el.listeners.has("keydown"), false)
  window.listeners.get("keydown")({key: "Escape", stopPropagation() {}})
  assert.equal(el.attributes.has("data-tooltip-dismissed"), true)
  el.listeners.get("pointerleave")()
  assert.equal(el.attributes.has("data-tooltip-dismissed"), false)
  hook.destroyed()
  assert.equal(el.listeners.size, 0)
  assert.equal(link.listeners.size, 0)
  assert.equal(window.listeners.size, 0)
})

test("hover-only details dismiss with focus elsewhere; closed details do not consume Escape", () => {
  const {el, hook, window} = fixture()
  el.ownerDocument.activeElement = {}
  let stopped = 0
  el.detailVisible = false
  window.listeners.get("keydown")({key: "Escape", stopPropagation() { stopped++ }})
  assert.equal(stopped, 0)
  el.detailVisible = true
  window.listeners.get("keydown")({key: "Escape", stopPropagation() { stopped++ }})
  assert.equal(stopped, 1)
  assert.equal(el.attributes.has("data-tooltip-dismissed"), true)
  hook.destroyed()
})

test("details fit the content boundary, flip above the bottom edge and update on resize", () => {
  const {el, hook, window} = fixture()
  assert.equal(el.attributes.get("--status-tooltip-width"), "280px")
  assert.equal(el.attributes.get("--status-tooltip-left"), "-241px")
  assert.equal(el.attributes.has("data-tooltip-above"), true)
  window.innerWidth = 320
  window.listeners.get("resize")()
  assert.equal(el.attributes.get("--status-tooltip-width"), "261px")
  assert.equal(el.attributes.get("--status-tooltip-left"), "-249px")
  hook.destroyed()
})

test("patches between compact activity and visible warnings clean up listeners", () => {
  const {el, hook, trigger, window} = fixture()
  el.text = true
  hook.updated()
  assert.equal(window.listeners.has("keydown"), false, "visible warnings do not intercept Escape")
  assert.equal(window.listeners.size, 0)
  el.text = false
  hook.updated()
  assert.equal(window.listeners.has("keydown"), true)
  hook.updated()
  hook.destroyed()
  assert.equal(el.listeners.size, 0)
  assert.equal(window.listeners.size, 0)
})
