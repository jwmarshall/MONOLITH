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
  const document = {body: {id: "body"}}
  const focusCalls = []
  const heading = {focus: options => {
    focusCalls.push(options)
    document.activeElement = heading
  }}
  const content = new FakeTarget()
  content.attributes.set("inert", "")
  content.querySelector = selector => {
    assert.equal(selector, "[data-workspace-heading]")
    return heading
  }
  const controls = new FakeTarget()
  controls.attributes.set("inert", "")
  const root = new FakeTarget()
  root.attributes.set("data-workspace-focus", "shared-focus-command")
  const entrance = new FakeTarget()
  entrance.ownerDocument = document
  entrance.attributes.set("data-entered", "false")
  if (enterOnReturn !== null) entrance.attributes.set("data-enter-on-return", enterOnReturn)
  entrance.closest = selector => {
    assert.equal(selector, "#workspace")
    return root
  }
  entrance.querySelector = selector => {
    if (selector === "#workspace-content") return content
    if (selector === "#workspace-controls") return controls
    assert.equal(selector, "[data-workspace-heading]")
    return heading
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
      exec: command => commands.push(command),
    }),
  })
  hook.mounted()
  t.after(() => hook.destroyed())
  const patch = () => {
    entrance.attributes.set("data-entered", "false")
    content.attributes.set("inert", "")
    controls.attributes.set("inert", "")
    // Model LiveView reapplying the sticky mutations over server-rendered attrs.
    for (const apply of sticky) apply()
  }
  return {hook, entrance, root, content, controls, document, heading, focusCalls, sticky, commands, serverEvents, patch}
}

test("completion opens the entrance gate through sticky LiveView JS, surviving a patch", t => {
  const {entrance, content, controls, focusCalls, sticky, patch} = workspace(t)
  assert.equal(entrance.getAttribute("data-entered"), "false")
  assert.equal(content.getAttribute("inert"), "")
  assert.equal(controls.getAttribute("inert"), "")
  assert.deepEqual(focusCalls, [])
  assert.equal(sticky.length, 0)

  entrance.emit("monolith:brand-complete")
  assert.equal(entrance.getAttribute("data-entered"), "true")
  assert.equal(content.getAttribute("inert"), null)
  assert.equal(controls.getAttribute("inert"), null)
  assert.equal(sticky.length, 3)
  patch()
  assert.equal(entrance.getAttribute("data-entered"), "true")
  assert.equal(content.getAttribute("inert"), null)
  assert.equal(controls.getAttribute("inert"), null)
})

test("return opens content and controls immediately without waiting for brand completion", t => {
  const {entrance, content, controls, commands, sticky, patch, document, heading} =
    workspace(t, "body", "true")
  assert.equal(entrance.getAttribute("data-entered"), "true")
  assert.equal(content.getAttribute("inert"), null)
  assert.equal(controls.getAttribute("inert"), null)
  assert.equal(document.activeElement, heading)
  assert.deepEqual(commands, ["shared-focus-command"])
  assert.equal(sticky.length, 3)

  patch()
  patch()
  assert.equal(entrance.getAttribute("data-entered"), "true")
  assert.equal(content.getAttribute("inert"), null)
  assert.equal(controls.getAttribute("inert"), null)
  assert.deepEqual(commands, ["shared-focus-command"], "patches must not refocus a reset workspace")
})

for (const enterOnReturn of [null, "false", "1", ""]) {
  test(`ordinary mount keeps the gate closed for return flag ${JSON.stringify(enterOnReturn)}`, t => {
    const {entrance, content, controls, commands, sticky} = workspace(t, "body", enterOnReturn)
    assert.equal(entrance.getAttribute("data-entered"), "false")
    assert.equal(content.getAttribute("inert"), "")
    assert.equal(controls.getAttribute("inert"), "")
    assert.deepEqual(commands, [])
    assert.deepEqual(sticky, [])
  })
}

test("return preserves an active input while opening and focusing the workspace pane state", t => {
  const input = {id: "workspace-name", tagName: "INPUT"}
  const {document, focusCalls, commands, content} = workspace(t, input, "true")
  assert.equal(document.activeElement, input)
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

test("focusin executes the current shared workspace focus command without moving focus", t => {
  const field = {id: "workspace-name"}
  const {entrance, root, commands, document, focusCalls} = workspace(t, field)
  entrance.emit("focusin")
  root.attributes.set("data-workspace-focus", "patched-focus-command")
  entrance.emit("focusin")
  assert.deepEqual(commands, ["shared-focus-command", "patched-focus-command"])
  assert.equal(document.activeElement, field)
  assert.deepEqual(focusCalls, [])
})

test("server focus-heading event explicitly focuses the heading without opening the gate", t => {
  const {serverEvents, document, heading, content, focusCalls, commands} = workspace(t, {id: "field"})
  assert.deepEqual([...serverEvents.keys()], ["workspace:focus-heading"])
  serverEvents.get("workspace:focus-heading")({})
  assert.equal(document.activeElement, heading)
  assert.deepEqual(focusCalls, [{preventScroll: true}])
  assert.equal(content.getAttribute("inert"), "")
  assert.deepEqual(commands, [])
})

test("missing heading is safe for completion and the server event", t => {
  const {entrance, content, serverEvents, focusCalls} = workspace(t)
  content.querySelector = () => null
  entrance.querySelector = selector => selector === "#workspace-content" ? content : null
  assert.doesNotThrow(() => entrance.emit("monolith:brand-complete"))
  assert.doesNotThrow(() => serverEvents.get("workspace:focus-heading")({}))
  assert.deepEqual(focusCalls, [])
  assert.equal(content.getAttribute("inert"), null)
})

test("destruction removes both native listeners and prevents further effects", t => {
  const {hook, entrance, content, sticky, commands, focusCalls} = workspace(t)
  assert.equal(entrance.listenerCount, 2)
  hook.destroyed()
  assert.equal(entrance.listenerCount, 0)
  entrance.emit("monolith:brand-complete")
  entrance.emit("focusin")
  assert.equal(entrance.getAttribute("data-entered"), "false")
  assert.equal(content.getAttribute("inert"), "")
  assert.deepEqual(sticky, [])
  assert.deepEqual(commands, [])
  assert.deepEqual(focusCalls, [])
})
