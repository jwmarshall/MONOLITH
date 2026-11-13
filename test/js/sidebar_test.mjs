import assert from "node:assert/strict"
import test from "node:test"
import Sidebar from "../../assets/js/hooks/sidebar.js"
import NativeModal from "../../assets/js/hooks/native_modal.js"
import WorkspaceEntrance from "../../assets/js/hooks/workspace_entrance.js"

class Target {
  listeners = new Map()
  attributes = new Map()
  dataset = {}
  addEventListener(type, fn, capture = false) {
    if (!this.listeners.has(type)) this.listeners.set(type, [])
    this.listeners.get(type).push({fn, capture})
  }
  removeEventListener(type, fn, capture = false) {
    this.listeners.set(type, (this.listeners.get(type) ?? []).filter(item => item.fn !== fn || item.capture !== capture))
  }
  dispatchEvent(event) { return this.emit(event.type, event) }
  emit(type, details = {}) {
    const event = {type, defaultPrevented: false, immediateStopped: false, ...details,
      preventDefault() { this.defaultPrevented = true },
      stopPropagation() { this.propagationStopped = true },
      stopImmediatePropagation() { this.immediateStopped = true },
    }
    const listeners = [...(this.listeners.get(type) ?? [])].sort((a, b) => Number(b.capture) - Number(a.capture))
    for (const {fn} of listeners) {
      fn(event)
      if (event.immediateStopped) break
    }
    return event
  }
  getAttribute(name) { return this.attributes.get(name) ?? null }
  setAttribute(name, value) {
    this.attributes.set(name, value)
    if (name === "data-navigation") this.dataset.navigation = value
  }
  get listenerCount() { return [...this.listeners.values()].reduce((sum, items) => sum + items.length, 0) }
}

function fixture(t) {
  const view = new Target()
  const document = new Target()
  document.defaultView = view
  document.body = {id: "body"}
  view.Event = class { constructor(type) { this.type = type } }
  document.dispatchEvent = event => document.emit(event.type)
  const frames = new Map()
  let frameId = 0
  view.requestAnimationFrame = callback => { frames.set(++frameId, callback); return frameId }
  view.cancelAnimationFrame = id => frames.delete(id)
  const flushFrames = () => {
    const callbacks = [...frames.values()]
    frames.clear()
    for (const callback of callbacks) callback()
  }
  const serverEvents = new Map()
  const pushHeading = () => serverEvents.get("workspace:focus-heading")({})
  const focused = []
  const toggle = new Target()
  toggle.focus = options => { document.activeElement = toggle; focused.push([toggle, options]) }
  toggle.closest = selector => selector === ".navigation-toggle" ? toggle : null
  const content = new Target()
  const shell = new Target()
  const workspace = new Target()
  const pane = new Target()
  pane.setAttribute("aria-pressed", "true")
  workspace.setAttribute("data-workspace-focus", "shared-focus-command")
  workspace.setAttribute("data-workspace-reset", "shared-reset-command")
  workspace.querySelector = selector => selector === "#workspace-pane" ? pane : null
  const entrance = new Target()
  entrance.ownerDocument = document
  entrance.closest = () => workspace
  entrance.querySelector = selector => selector === ".workspace-shell" ? shell
    : selector === "[data-workspace-heading]" ? document.heading : null
  const el = new Target()
  el.ownerDocument = document
  el.closest = selector => selector === ".workspace-shell" ? shell : selector === "#workspace" ? workspace : null
  el.querySelector = selector => selector === ".navigation-toggle" ? toggle : selector === ".sidebar-content" ? content : null
  document.querySelector = selector => selector === "dialog[open]" ? (document.modal?.open ? document.modal : null)
    : selector === "[data-workspace-heading]" ? document.heading : null
  const sticky = []
  const mutate = callback => { sticky.push(callback); callback() }
  const js = {
    setAttribute: (target, name, value) => mutate(() => target.setAttribute(name, value)),
    removeAttribute: (target, name) => mutate(() => target.attributes.delete(name)),
    exec: command => {
      const focused = command === workspace.getAttribute("data-workspace-focus")
      pane.setAttribute("aria-pressed", String(focused))
      if (!focused) workspace.emit("monolith:brand-reset")
    },
  }
  const hook = {...Sidebar, el, js: () => js}
  hook.mounted()
  t.after(() => hook.destroyed())
  const link = {href: "/workspaces"}
  const linkChild = {closest: selector => selector === ".sidebar-content a[href]" ? link : null}
  const activity = {id: "scene-global-activity", className: "scene-global-activity", href: "/scenes"}
  const activityChild = {closest: selector => selector === ".sidebar-content a[href]" ? activity : null}
  const click = (target = toggle, details = {}) => {
    const event = el.emit("click", {target, button: 0, ...details})
    if (target.closest(".sidebar-content a[href]") && event.button === 0 &&
        !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
      // LiveSocket starts link patches after the native click handler.
      view.emit("phx:page-loading-start", {detail: {kind: "patch"}})
    }
    return event
  }
  const heading = () => {
    const node = {focus: options => {
      document.activeElement = node
      focused.push([node, options])
      entrance.emit("focusin")
    }}
    document.heading = node
    return node
  }
  const patch = () => {
    shell.setAttribute("data-navigation", "collapsed")
    toggle.setAttribute("aria-expanded", "false")
    content.setAttribute("hidden", "")
    for (const apply of sticky) apply()
  }
  const mountEntrance = () => {
    const hook = {...WorkspaceEntrance, el: entrance, js: () => js,
      handleEvent: (name, callback) => serverEvents.set(name, callback)}
    hook.mounted()
    t.after(() => hook.destroyed())
  }
  const command = name => js.exec(workspace.getAttribute(`data-workspace-${name}`))
  return {view, document, el, hook, toggle, content, shell, workspace, pane, focused,
    linkChild, activity, activityChild, click, heading, patch, mountEntrance, command,
    pushHeading, flushFrames, frames}
}

test("expanded navigation remains accessible through patches and Escape restores the mark", t => {
  const {click, shell, toggle, content, view, document, patch, focused} = fixture(t)
  click()
  patch()
  assert.equal(shell.dataset.navigation, "expanded")
  assert.equal(toggle.getAttribute("aria-expanded"), "true")
  assert.equal(content.getAttribute("hidden"), null)
  const escape = view.emit("keydown", {key: "Escape"})
  assert.equal(escape.defaultPrevented, true)
  assert.equal(escape.immediateStopped, true)
  assert.equal(shell.dataset.navigation, "collapsed")
  assert.equal(toggle.getAttribute("aria-expanded"), "false")
  assert.equal(content.getAttribute("hidden"), "")
  assert.equal(document.activeElement, toggle)
  assert.deepEqual(focused, [[toggle, {preventScroll: true}]])
  const next = view.emit("keydown", {key: "Escape"})
  assert.equal(next.defaultPrevented, false)
  assert.equal(next.immediateStopped, false)
})

test("an open native modal owns Escape before the expanded sidebar", t => {
  const {click, shell, view, document, toggle} = fixture(t)
  click()
  const modal = new Target()
  modal.ownerDocument = document
  modal.dataset = {cancelEvent: "cancel_workspace", initialFocus: "#name", returnFocus: "#sidebar-toggle"}
  modal.querySelector = () => ({focus() {}})
  modal.showModal = () => { modal.open = true }
  modal.close = () => { modal.open = false }
  document.modal = modal
  const cancels = []
  const native = {...NativeModal, el: modal, pushEvent: (...args) => cancels.push(args), js: () => ({setAttribute() {}})}
  native.mounted()
  const escape = view.emit("keydown", {key: "Escape"})
  assert.equal(escape.defaultPrevented, true)
  assert.deepEqual(cancels, [["cancel_workspace", {}]])
  assert.equal(modal.open, true, "server removal still owns cancellation")
  assert.equal(shell.dataset.navigation, "expanded")
  native.destroyed()
  view.emit("keydown", {key: "Escape"})
  assert.equal(shell.dataset.navigation, "collapsed")
  assert.equal(document.activeElement, toggle)
})

test("ordinary destination selection preserves the native click and focuses the patched heading once", t => {
  const {click, linkChild, shell, view, document, heading, focused} = fixture(t)
  click()
  const draft = {value: "Unfinished draft"}
  document.activeElement = draft
  const event = click(linkChild)
  assert.equal(event.defaultPrevented, false)
  assert.equal(shell.dataset.navigation, "collapsed")
  assert.equal(document.activeElement, draft)
  assert.equal(draft.value, "Unfinished draft")
  const destination = heading()
  view.emit("phx:page-loading-stop")
  assert.equal(document.activeElement, destination)
  assert.deepEqual(focused, [[destination, {preventScroll: true}]])
  const next = heading()
  view.emit("phx:page-loading-stop")
  assert.notEqual(document.activeElement, next)
  assert.equal(focused.length, 1)
})

test("the sidebar-foot activity destination collapses and hands off keyboard activation without replacing its URL", t => {
  const {click, activity, activityChild, shell, view, document, heading, focused} = fixture(t)
  click()
  assert.equal(activityChild.closest("nav a"), null, "activity is outside the main nav")
  const event = click(activityChild, {detail: 0})
  assert.equal(event.defaultPrevented, false)
  assert.equal(event.propagationStopped, undefined)
  assert.equal(activity.href, "/scenes")
  assert.equal(shell.dataset.navigation, "collapsed")
  const destination = heading()
  view.emit("phx:page-loading-stop")
  assert.equal(document.activeElement, destination)
  assert.deepEqual(focused, [[destination, {preventScroll: true}]])
})

test("Escape before a delayed activity completion cannot wake WorkspaceEntrance or move draft focus", t => {
  const {click, activityChild, view, document, hook, pane, heading, focused, mountEntrance} = fixture(t)
  mountEntrance()
  click()
  click(activityChild)
  const draft = {value: "Unfinished draft"}
  document.activeElement = draft
  view.location = {pathname: "/scenes"}
  const escape = view.emit("keydown", {key: "Escape"})
  assert.equal(escape.defaultPrevented, true)
  assert.equal(hook.focusDestination, false)
  assert.equal(pane.getAttribute("aria-pressed"), "false")
  heading()
  view.emit("phx:page-loading-stop")
  assert.equal(pane.getAttribute("aria-pressed"), "false")
  assert.equal(document.activeElement, draft)
  assert.equal(draft.value, "Unfinished draft")
  assert.equal(view.location.pathname, "/scenes")
  assert.deepEqual(focused, [])
})

test("the existing scenery gate fences delayed heading focus even without a reset notification", t => {
  const {click, linkChild, view, document, pane, heading, focused, mountEntrance} = fixture(t)
  mountEntrance()
  click()
  click(linkChild)
  pane.setAttribute("aria-pressed", "false")
  heading()
  view.emit("phx:page-loading-stop")
  assert.equal(pane.getAttribute("aria-pressed"), "false")
  assert.equal(document.activeElement, undefined)
  assert.deepEqual(focused, [])
})

test("idle reset cancels the handoff even when first input wakes before navigation completes", t => {
  const {click, linkChild, view, document, hook, pane, heading, focused, command, mountEntrance} = fixture(t)
  mountEntrance()
  click()
  click(linkChild)
  const draft = {value: "Keep this draft"}
  document.activeElement = draft
  command("reset")
  assert.equal(hook.focusDestination, false)
  assert.equal(pane.getAttribute("aria-pressed"), "false")
  const firstInput = document.emit("keydown", {key: "x", target: draft})
  command("focus")
  heading()
  view.emit("phx:page-loading-stop")
  assert.equal(firstInput.defaultPrevented, false)
  assert.equal(pane.getAttribute("aria-pressed"), "true")
  assert.equal(document.activeElement, draft)
  assert.equal(draft.value, "Keep this draft")
  assert.deepEqual(focused, [])
})
test("ordinary Scenes navigation composes the pushed event with one sidebar heading handoff", t => {
  const {click, activityChild, view, document, heading, focused, mountEntrance, pushHeading, flushFrames} = fixture(t)
  mountEntrance()
  click()
  click(activityChild)
  const destination = heading()
  pushHeading()
  view.emit("phx:page-loading-stop")
  flushFrames()
  assert.equal(document.activeElement, destination)
  assert.deepEqual(focused, [[destination, {preventScroll: true}]])
})

for (const [type, details] of [["pointerdown", {}], ["keydown", {key: "a"}], ["input", {}]]) {
  test(`a delayed Scenes push cannot override newer ${type} control intent`, t => {
    const {click, activityChild, view, document, toggle, shell, heading, focused,
      mountEntrance, pushHeading, flushFrames} = fixture(t)
    mountEntrance()
    click()
    click(activityChild)
    const control = type === "pointerdown" ? toggle : {value: "Keep typing"}
    document.activeElement = control
    const event = document.emit(type, {target: control, ...details})
    if (type === "pointerdown") click()
    heading()
    pushHeading()
    view.emit("phx:page-loading-stop")
    flushFrames()
    assert.equal(event.defaultPrevented, false)
    assert.equal(document.activeElement, control)
    if (type === "pointerdown") assert.equal(shell.dataset.navigation, "expanded")
    else assert.equal(control.value, "Keep typing")
    assert.deepEqual(focused, [])
  })
}

for (const wakeWithInput of [false, true]) {
  test(`reset then wake fences a delayed Scenes push (new input: ${wakeWithInput})`, t => {
    const {click, activityChild, view, document, pane, heading, focused, command,
      mountEntrance, pushHeading, flushFrames} = fixture(t)
    mountEntrance()
    click()
    click(activityChild)
    const draft = {value: "Preserve this draft"}
    document.activeElement = draft
    command("reset")
    if (wakeWithInput) document.emit("keydown", {key: "x", target: draft})
    command("focus")
    heading()
    pushHeading()
    view.emit("phx:page-loading-stop")
    flushFrames()
    assert.equal(pane.getAttribute("aria-pressed"), "true")
    assert.equal(document.activeElement, draft)
    assert.equal(draft.value, "Preserve this draft")
    assert.deepEqual(focused, [])
  })
}

test("sidebar Escape cancels the pushed frame even when it stops keyboard propagation", t => {
  const {click, activityChild, view, document, toggle, heading, focused,
    mountEntrance, pushHeading, flushFrames} = fixture(t)
  mountEntrance()
  click()
  click(activityChild)
  heading()
  pushHeading()
  click()
  const event = view.emit("keydown", {key: "Escape"})
  view.emit("phx:page-loading-stop")
  flushFrames()
  assert.equal(event.immediateStopped, true)
  assert.equal(document.activeElement, toggle)
  assert.deepEqual(focused, [[toggle, {preventScroll: true}]])
})


for (const [type, details] of [["pointerdown", {}], ["keydown", {key: "a"}], ["input", {}]]) {
  test(`${type} after destination selection keeps the user's newer control intent`, t => {
    const {click, linkChild, view, document, heading, focused} = fixture(t)
    click()
    click(linkChild)
    const control = {value: "Current input"}
    document.activeElement = control
    const event = document.emit(type, {target: control, ...details})
    heading()
    view.emit("phx:page-loading-stop")
    assert.equal(event.defaultPrevented, false)
    assert.equal(document.activeElement, control)
    assert.equal(control.value, "Current input")
    assert.deepEqual(focused, [])
  })
}

for (const destination of ["linkChild", "activityChild"]) {
  for (const details of [{button: 1}, {metaKey: true}, {ctrlKey: true}, {shiftKey: true}, {altKey: true}]) {
    test(`modified ${destination} navigation ${JSON.stringify(details)} never claims destination focus`, t => {
      const fixtureState = fixture(t)
      const {click, shell, view, document, heading, focused} = fixtureState
      click()
      const event = click(fixtureState[destination], details)
      heading()
      view.emit("phx:page-loading-stop")
      assert.equal(event.defaultPrevented, false)
      assert.equal(shell.dataset.navigation, "expanded")
      assert.deepEqual(focused, [])
      assert.equal(document.activeElement, undefined)
    })
  }
}

test("missing destination headings and hook teardown leave focus untouched", t => {
  const {click, linkChild, view, document, workspace, hook, el, focused} = fixture(t)
  click()
  click(linkChild)
  assert.doesNotThrow(() => view.emit("phx:page-loading-stop"))
  click()
  click(linkChild)
  hook.destroyed()
  assert.equal(view.listenerCount, 0)
  assert.equal(el.listenerCount, 0)
  assert.equal(document.listenerCount, 0)
  assert.equal(workspace.listenerCount, 0)
  view.emit("phx:page-loading-stop")
  view.emit("keydown", {key: "Escape"})
  assert.equal(document.activeElement, undefined)
  assert.deepEqual(focused, [])
})
