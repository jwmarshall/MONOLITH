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

function fixture() {
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
  el.dataset = {returnFocus: "#trigger", initialFocus: "#name", cancelEvent: "cancel_workspace"}
  let shows = 0, closes = 0
  el.showModal = () => { shows++; el.open = true }
  el.close = () => { closes++; el.open = false }
  el.querySelector = selector => { assert.equal(selector, "#name"); return input }
  document.querySelector = selector => {
    if (selector === "dialog[open]") return el.open ? el : null
    if (selector === "#trigger") return document.opener
    if (selector === "[data-workspace-heading]") return heading
    assert.fail(selector)
  }
  document.opener = opener
  const events = []
  const sticky = []
  const hook = Object.assign({}, NativeModal, {
    el,
    pushEvent: (...args) => events.push(args),
    js: () => ({setAttribute: (target, name, value) => {
      assert.equal(target, el)
      sticky.push([name, value])
    }}),
  })
  hook.mounted()
  const event = (key = "Escape") => ({key, prevented: false, stopped: false,
    preventDefault() { this.prevented = true }, stopPropagation() { this.stopped = true }})
  return {window, document, el, hook, input, events, focused, frames, event, sticky,
    counts: () => ({shows, closes})}
}

test("opens a native modal once and focuses its input, without owning validation patches", () => {
  const {hook, counts, focused, input, sticky} = fixture()
  assert.deepEqual(counts(), {shows: 1, closes: 0})
  assert.deepEqual(sticky, [["open", ""]], "LiveView must retain native open across validation/background patches")
  assert.deepEqual(focused, [["input", {preventScroll: true}]])
  // No updated callback: validation/background patches must neither reopen nor
  // refocus the dialog or overwrite the server/LiveView-managed draft.
  assert.equal(hook.updated, undefined)
  assert.equal(input.value, "Draft")
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
