import assert from "node:assert/strict"
import test from "node:test"
import NativeModal from "../../assets/js/hooks/native_modal.js"

class Target {
  listeners = new Map()
  addEventListener(name, fn, capture) { this.listeners.set(name, {fn, capture}) }
  removeEventListener(name, fn, capture) {
    const listener = this.listeners.get(name)
    assert.equal(listener?.fn, fn)
    assert.equal(listener?.capture, capture)
    this.listeners.delete(name)
  }
  dispatchEvent(event) { this.listeners.get(event.type)?.fn(event) }
}

function fixture({returnFocus = "#trigger", manual = false} = {}) {
  const window = new Target()
  const document = new Target()
  document.defaultView = window
  window.Event = class { constructor(type) { this.type = type } }
  const frames = []
  window.requestAnimationFrame = fn => frames.push(fn)
  const focused = []
  const input = {value: "Draft", focus: options => focused.push(["input", options])}
  const opener = {focus: options => focused.push(["opener", options])}
  const heading = {focus: options => focused.push(["heading", options])}
  const el = new Target()
  el.ownerDocument = document
  el.dataset = {returnFocus, initialFocus: "#name",
    ...(manual ? {openOnMount: "false"} : {cancelEvent: "cancel_workspace"})}
  let shows = 0, closes = 0
  el.showModal = () => { shows++; el.open = true }
  el.close = () => { closes++; el.open = false }
  el.querySelector = selector => { assert.equal(selector, "#name"); return input }
  document.querySelector = selector => {
    if (selector === "dialog[open]") return el.open ? el : null
    if (selector === returnFocus) return document.opener
    if (selector === "[data-workspace-heading]") return heading
    assert.fail(selector)
  }
  document.opener = opener
  const events = []
  const sticky = []
  const hook = Object.assign({}, NativeModal, {
    el,
    pushEvent: (...args) => events.push(args),
    js: () => ({
      setAttribute: (target, name) => {
        assert.equal(target, el)
        const apply = () => {
          if (name === "open") target.open = true
          if (name === "data-modal") target.dataset.modal = ""
        }
        apply.attribute = name
        sticky.push(apply)
        sticky.at(-1)()
      },
      removeAttribute: (target, name) => {
        assert.equal(target, el)
        const index = sticky.findIndex(apply => apply.attribute === name)
        if (index !== -1) sticky.splice(index, 1)
        if (name === "open") target.open = false
        if (name === "data-modal") delete target.dataset.modal
      },
    }),
  })
  hook.mounted()
  const event = (key = "Escape") => ({key, prevented: false, stopped: false,
    preventDefault() { this.prevented = true }, stopPropagation() { this.stopped = true }})
  return {window, document, el, hook, input, events, focused, frames, event, sticky,
    counts: () => ({shows, closes})}
}

test("validation patches keep the modal open and preserve the edited draft and focus", () => {
  const {hook, el, counts, focused, input, sticky} = fixture()
  input.value = "Edited draft"
  el.open = false
  for (const apply of sticky) apply()
  hook.updated?.()
  assert.equal(el.open, true)
  assert.deepEqual(counts(), {shows: 1, closes: 0})
  assert.deepEqual(focused, [["input", {preventScroll: true}]])
  assert.equal(input.value, "Edited draft")
  hook.destroyed()
})

test("Escape is intercepted in capture, cancels only once and leaves removal to the server", () => {
  const {window, el, hook, events, event} = fixture()
  assert.equal(window.listeners.get("keydown").capture, true)
  const typing = event("a")
  window.dispatchEvent({type: "keydown", ...typing})
  assert.deepEqual(events, [])
  const escape = event()
  window.listeners.get("keydown").fn(escape)
  assert.equal(escape.prevented, true)
  assert.equal(escape.stopped, true)
  el.listeners.get("cancel").fn(event())
  assert.deepEqual(events, [["cancel_workspace", {}]])
  assert.equal(el.open, true)
  hook.destroyed()
  assert.equal(window.listeners.size, 0)
  assert.equal(el.listeners.size, 0)
})

test("save/cancel teardown closes and restores a patched trigger without scrolling", () => {
  const {hook, document, frames, focused, counts} = fixture()
  let closed = 0
  document.addEventListener("monolith:modal-closed", () => closed++)
  hook.destroyed()
  assert.deepEqual(counts(), {shows: 1, closes: 1})
  assert.equal(focused.length, 1)
  frames.shift()()
  assert.deepEqual(focused.at(-1), ["opener", {preventScroll: true}])
  assert.equal(closed, 1)
})

test("a sidebar-origin modal restores the mark after the opener is patched", () => {
  const {hook, document, frames, focused} = fixture({returnFocus: "#sidebar-toggle"})
  document.opener = {focus: options => focused.push(["sidebar-mark", options])}
  hook.destroyed()
  frames.shift()()
  assert.deepEqual(focused.at(-1), ["sidebar-mark", {preventScroll: true}])
})

test("a disabled trigger falls back to the heading after a confirmed request", () => {
  const {hook, document, frames, focused} = fixture()
  document.opener.disabled = true
  hook.destroyed()
  frames.shift()()
  assert.equal(focused.at(-1)[0], "heading")
})

test("missing trigger falls back to the heading; another modal never loses focus", () => {
  const {hook, document, frames, focused} = fixture()
  document.opener = null
  hook.destroyed()
  frames.shift()()
  assert.equal(focused.at(-1)[0], "heading")

  const next = fixture()
  next.hook.destroyed()
  next.el.open = true // A replacement modal has taken over before the frame.
  next.frames.shift()()
  assert.equal(next.focused.length, 1)
})

test("credential dialogs open locally and Escape preserves the draft without a server event", () => {
  const {hook, el, input, events, counts, focused, frames, sticky, event} = fixture({manual: true})
  assert.deepEqual(counts(), {shows: 0, closes: 0})
  assert.equal(el.dataset.modal, undefined, "closed credentials do not suspend visual idle")
  el.dispatchEvent({type: "monolith:modal-open"})
  assert.equal(el.open, true)
  assert.equal(el.dataset.modal, "", "opening suspends visual idle")
  assert.equal(focused.at(-1)[0], "input")
  input.value = "Synthetic credential draft"
  el.open = false
  sticky.forEach(apply => apply())
  assert.equal(el.open, true)
  hook.onKeydown(event())
  frames.shift()()
  assert.equal(el.open, false)
  assert.equal(el.dataset.modal, undefined, "Escape resumes visual idle")
  assert.equal(focused.at(-1)[0], "opener")
  assert.deepEqual(events, [])
  el.dispatchEvent({type: "monolith:modal-open"})
  assert.equal(input.value, "Synthetic credential draft")
  el.dispatchEvent({type: "monolith:modal-close"})
  assert.equal(el.open, false)
  assert.equal(el.dataset.modal, undefined, "Cancel resumes visual idle")
  assert.deepEqual(events, [])
  assert.deepEqual(counts(), {shows: 2, closes: 2})
  hook.destroyed()
  assert.equal(el.listeners.size, 0)
})

test("removing an unopened or already dismissed credential dialog leaves navigation focus alone", () => {
  for (const dismissed of [false, true]) {
    const state = fixture({manual: true})
    if (dismissed) {
      state.el.dispatchEvent({type: "monolith:modal-open"})
      state.el.dispatchEvent({type: "monolith:modal-close"})
      state.frames.shift()()
    }
    const before = state.focused.length
    state.hook.destroyed()
    state.frames.forEach(frame => frame())
    assert.equal(state.focused.length, before)
  }
})
