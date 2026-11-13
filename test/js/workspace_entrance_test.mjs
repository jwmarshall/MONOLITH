import assert from "node:assert/strict"
import test from "node:test"
import WorkspaceEntrance from "../../assets/js/hooks/workspace_entrance.js"

class FakeTarget extends EventTarget {
  listeners = new Map()
  attributes = new Map()

  addEventListener(type, callback) {
    super.addEventListener(type, callback)
    if (!this.listeners.has(type)) this.listeners.set(type, new Set())
    this.listeners.get(type).add(callback)
  }

  removeEventListener(type, callback) {
    super.removeEventListener(type, callback)
    this.listeners.get(type)?.delete(callback)
  }

  getAttribute(name) { return this.attributes.get(name) ?? null }
  emit(type) { this.dispatchEvent(new Event(type)) }
  get listenerCount() { return [...this.listeners.values()].reduce((n, callbacks) => n + callbacks.size, 0) }
}

function workspace(t, active = "pane", enterOnReturn = null) {
  const view = new FakeTarget()
  const frames = new Map()
  let frameId = 0
  view.requestAnimationFrame = callback => { frames.set(++frameId, callback); return frameId }
  view.cancelAnimationFrame = id => frames.delete(id)
  const document = new FakeTarget()
  document.body = {id: "body"}
  document.defaultView = view
  document.querySelector = selector => selector === "dialog[open]" ? document.modal ?? null : null
  const focusCalls = []
  const heading = {focus: options => {
    focusCalls.push(options)
    document.activeElement = heading
  }}
  const content = new FakeTarget()
  content.attributes.set("inert", "")
  content.querySelector = () => heading
  const pane = new FakeTarget()
  pane.attributes.set("aria-pressed", "true")
  const shell = {dataset: {navigation: "collapsed"}}
  const root = new FakeTarget()
  root.attributes.set("data-workspace-focus", "shared-focus-command")
  root.attributes.set("data-workspace-reset", "shared-reset-command")
  root.querySelector = selector => selector === "#workspace-pane" ? pane : null
  const entrance = new FakeTarget()
  entrance.ownerDocument = document
  entrance.attributes.set("data-entered", "false")
  if (enterOnReturn !== null) entrance.attributes.set("data-enter-on-return", enterOnReturn)
  entrance.closest = () => root
  entrance.querySelector = selector => {
    if (selector === "#workspace-content") return content
    if (selector === ".workspace-shell") return shell
    return selector === "[data-workspace-heading]" ? heading : null
  }
  document.activeElement = active === "pane" ? {id: "workspace-pane"}
    : active === "body" ? document.body : active

  const sticky = []
  const commands = []
  const serverEvents = new Map()
  const hook = Object.assign({}, WorkspaceEntrance, {
    el: entrance,
    handleEvent: (name, callback) => serverEvents.set(name, callback),
    js: () => ({
      setAttribute: (el, name, value) => {
        sticky.push(() => el.attributes.set(name, value))
        sticky.at(-1)()
      },
      removeAttribute: (el, name) => {
        sticky.push(() => el.attributes.delete(name))
        sticky.at(-1)()
      },
      exec: command => {
        commands.push(command)
        pane.attributes.set("aria-pressed", String(command === root.getAttribute("data-workspace-focus")))
        if (command === root.getAttribute("data-workspace-reset")) root.emit("monolith:brand-reset")
      },
    }),
  })
  hook.mounted()
  t.after(() => hook.destroyed())
  const patch = () => {
    entrance.attributes.set("data-entered", "false")
    content.attributes.set("inert", "")
    for (const apply of sticky) apply()
  }
  const flushFrames = () => {
    const callbacks = [...frames.values()]
    frames.clear()
    for (const callback of callbacks) callback()
  }
  const key = value => {
    const event = new Event("keydown", {cancelable: true})
    Object.defineProperty(event, "key", {value})
    document.dispatchEvent(event)
    view.dispatchEvent(event)
    return event
  }
  return {hook, entrance, root, content, document, heading, pane, shell, view,
    focusCalls, commands, serverEvents, frames, patch, flushFrames, key}
}

test("completion opens the entrance gate and survives a LiveView patch", t => {
  const {entrance, content, patch} = workspace(t)
  assert.equal(content.getAttribute("inert"), "")
  entrance.emit("monolith:brand-complete")
  assert.equal(entrance.getAttribute("data-entered"), "true")
  assert.equal(content.getAttribute("inert"), null)
  patch()
  assert.equal(entrance.getAttribute("data-entered"), "true")
  assert.equal(content.getAttribute("inert"), null)
})

test("authorized return opens immediately without reopening the focal plane after patches", t => {
  const {entrance, content, commands, patch, document, heading} = workspace(t, "body", "true")
  assert.equal(entrance.getAttribute("data-entered"), "true")
  assert.equal(content.getAttribute("inert"), null)
  assert.equal(document.activeElement, heading)
  assert.deepEqual(commands, ["shared-focus-command"])
  patch()
  patch()
  assert.equal(content.getAttribute("inert"), null)
  assert.deepEqual(commands, ["shared-focus-command"])
})

for (const enterOnReturn of [null, "false", "1", ""]) {
  test(`ordinary mount keeps the gate closed for return flag ${JSON.stringify(enterOnReturn)}`, t => {
    const {entrance, content, commands} = workspace(t, "body", enterOnReturn)
    assert.equal(entrance.getAttribute("data-entered"), "false")
    assert.equal(content.getAttribute("inert"), "")
    assert.deepEqual(commands, [])
  })
}

test("authorized return preserves an active draft input", t => {
  const input = {id: "workspace-name", tagName: "INPUT", value: "Unfinished name"}
  const {document, focusCalls, commands, content} = workspace(t, input, "true")
  assert.equal(document.activeElement, input)
  assert.equal(input.value, "Unfinished name")
  assert.deepEqual(focusCalls, [])
  assert.deepEqual(commands, ["shared-focus-command"])
  assert.equal(content.getAttribute("inert"), null)
})

for (const active of ["pane", "body"]) {
  test(`completion focuses the heading without scrolling when focus is on ${active}`, t => {
    const {entrance, document, heading, focusCalls} = workspace(t, active)
    entrance.emit("monolith:brand-complete")
    assert.equal(document.activeElement, heading)
    assert.deepEqual(focusCalls, [{preventScroll: true}])
  })
}

for (const active of [{id: "workspace-name", tagName: "INPUT"}, {id: "outside-button"}, null]) {
  test(`completion does not steal existing focus (${active?.id ?? "no active element"})`, t => {
    const {entrance, content, document, focusCalls} = workspace(t, active)
    entrance.emit("monolith:brand-complete")
    assert.equal(document.activeElement, active)
    assert.deepEqual(focusCalls, [])
    assert.equal(content.getAttribute("inert"), null)
  })
}

test("Escape cancellation opens the gate without waking scenery or moving focus", t => {
  const {entrance, content, pane, document, key, commands, focusCalls, patch} = workspace(t)
  const active = document.activeElement
  assert.equal(key("Escape").defaultPrevented, true, "scenery Escape must not clear a native search draft")
  entrance.emit("monolith:brand-complete")
  patch()
  assert.equal(content.getAttribute("inert"), null)
  assert.equal(pane.getAttribute("aria-pressed"), "false")
  assert.equal(document.activeElement, active)
  assert.deepEqual(focusCalls, [])
  assert.deepEqual(commands, ["shared-reset-command"])
  entrance.emit("focusin")
  assert.equal(pane.getAttribute("aria-pressed"), "true")
})

test("Escape belongs to an open modal or expanded sidebar before scenery", t => {
  const {document, shell, key, commands} = workspace(t)
  document.modal = {}
  key("Escape")
  document.modal = null
  shell.dataset.navigation = "expanded"
  key("Escape")
  assert.deepEqual(commands, [])
  shell.dataset.navigation = "collapsed"
  key("a")
  assert.deepEqual(commands, [])
  key("Escape")
  assert.deepEqual(commands, ["shared-reset-command"])
})

test("focusin uses the current shared focus command without moving focus", t => {
  const field = {id: "workspace-name"}
  const {entrance, root, commands, document, focusCalls} = workspace(t, field)
  entrance.emit("focusin")
  root.attributes.set("data-workspace-focus", "patched-focus-command")
  entrance.emit("focusin")
  assert.deepEqual(commands, ["shared-focus-command", "patched-focus-command"])
  assert.equal(document.activeElement, field)
  assert.deepEqual(focusCalls, [])
})

test("destination focus waits for the patch and coalesces duplicate requests", t => {
  const {serverEvents, document, heading, content, focusCalls, commands, flushFrames} = workspace(t, {id: "field"})
  serverEvents.get("workspace:focus-heading")({})
  serverEvents.get("workspace:focus-heading")({})
  assert.deepEqual(focusCalls, [])
  flushFrames()
  assert.equal(document.activeElement, heading)
  assert.deepEqual(focusCalls, [{preventScroll: true}])
  assert.equal(content.getAttribute("inert"), "")
  assert.deepEqual(commands, [])
})

test("Escape before a pending heading frame preserves focus and scenery", t => {
  const {serverEvents, document, key, flushFrames, focusCalls} = workspace(t, {id: "field"})
  const field = document.activeElement
  serverEvents.get("workspace:focus-heading")({})
  key("Escape")
  flushFrames()
  assert.equal(document.activeElement, field)
  assert.deepEqual(focusCalls, [])
})
for (const type of ["keydown", "pointerdown", "input"]) {
  test(`${type} after a pushed heading request cancels its pending frame`, t => {
    const {serverEvents, document, flushFrames, focusCalls} = workspace(t, {id: "field"})
    const field = document.activeElement
    serverEvents.get("workspace:focus-heading")({})
    document.emit(type)
    flushFrames()
    assert.equal(document.activeElement, field)
    assert.deepEqual(focusCalls, [])
  })
}

test("control focus after a destination request survives its pending heading frame", t => {
  const {hook, serverEvents, document, flushFrames, focusCalls} = workspace(t)
  serverEvents.get("workspace:focus-heading")({})
  const summary = {id: "client-editor-summary", matches: () => true}
  document.activeElement = summary
  hook.onFocus({target: summary})
  flushFrames()
  assert.equal(document.activeElement, summary)
  assert.deepEqual(focusCalls, [])
})

test("a scenery reset cancels a pushed frame even if focus wakes before the next paint", t => {
  const {serverEvents, root, entrance, document, flushFrames, focusCalls} = workspace(t, {id: "field"})
  const field = document.activeElement
  serverEvents.get("workspace:focus-heading")({})
  root.emit("monolith:brand-reset")
  entrance.emit("focusin")
  flushFrames()
  assert.equal(document.activeElement, field)
  assert.deepEqual(focusCalls, [])
})

test("a completed cancelled navigation does not suppress later programmatic heading focus", t => {
  const {serverEvents, view, document, heading, flushFrames, focusCalls} = workspace(t, {id: "field"})
  view.emit("phx:page-loading-start")
  document.emit("pointerdown")
  serverEvents.get("workspace:focus-heading")({})
  view.emit("phx:page-loading-stop")
  flushFrames()
  assert.deepEqual(focusCalls, [])
  serverEvents.get("workspace:focus-heading")({})
  flushFrames()
  assert.equal(document.activeElement, heading)
  assert.deepEqual(focusCalls, [{preventScroll: true}])
})


test("missing headings are safe for completion and destination focus", t => {
  const {entrance, content, serverEvents, focusCalls, flushFrames} = workspace(t)
  content.querySelector = () => null
  const original = entrance.querySelector
  entrance.querySelector = selector => selector === "[data-workspace-heading]" ? null : original(selector)
  entrance.emit("monolith:brand-complete")
  serverEvents.get("workspace:focus-heading")({})
  assert.doesNotThrow(flushFrames)
  assert.deepEqual(focusCalls, [])
  assert.equal(content.getAttribute("inert"), null)
})

test("destruction removes listeners and pending destination focus", t => {
  const {hook, entrance, root, content, document, view, serverEvents, key, frames, flushFrames, commands, focusCalls} = workspace(t)
  serverEvents.get("workspace:focus-heading")({})
  hook.destroyed()
  assert.equal(entrance.listenerCount, 0)
  assert.equal(view.listenerCount, 0)
  assert.equal(document.listenerCount, 0)
  assert.equal(root.listenerCount, 0)
  assert.equal(frames.size, 0)
  entrance.emit("monolith:brand-complete")
  entrance.emit("focusin")
  key("Escape")
  flushFrames()
  assert.equal(content.getAttribute("inert"), "")
  assert.deepEqual(commands, [])
  assert.deepEqual(focusCalls, [])
})
