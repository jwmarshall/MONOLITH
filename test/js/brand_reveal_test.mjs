import assert from "node:assert/strict"
import test from "node:test"
import BrandReveal, {createBrandReveal} from "../../assets/js/hooks/brand_reveal.js"
import WorkspaceEntrance from "../../assets/js/hooks/workspace_entrance.js"

class FakeTarget extends EventTarget {
  listeners = new Map()
  attributes = new Map()
  addEventListener(type, callback, options) {
    super.addEventListener(type, callback, options)
    if (!this.listeners.has(type)) this.listeners.set(type, new Set())
    this.listeners.get(type).add(callback)
  }
  removeEventListener(type, callback, options) {
    super.removeEventListener(type, callback, options)
    this.listeners.get(type)?.delete(callback)
  }
  getAttribute(name) { return this.attributes.get(name) ?? null }
  emit(type) { this.dispatchEvent(new Event(type)) }
  get listenerCount() { return [...this.listeners.values()].reduce((n, callbacks) => n + callbacks.size, 0) }
}

function brand(t, {reduced = false, focused = false, enterOnReturn = null, enterOnUnlock = null, standalone = false, beforeMount} = {}) {
  const preference = Object.assign(new FakeTarget(), {matches: reduced})
  const view = Object.assign(new FakeTarget(), {matchMedia: () => preference})
  const frames = new Map()
  let frameId = 0
  view.requestAnimationFrame = callback => { frames.set(++frameId, callback); return frameId }
  view.cancelAnimationFrame = id => frames.delete(id)
  const document = Object.assign(new FakeTarget(), {defaultView: view, body: {id: "body"}, querySelector: () => null})
  document.activeElement = {id: "workspace-pane"}
  const animations = []
  const target = () => {
    const element = new FakeTarget()
    element.animate = (frames, options) => {
      let resolve, reject
      const animation = {
        element, frames, options, canceled: false,
        finished: new Promise((done, fail) => { resolve = done; reject = fail }),
        finish() { resolve() },
        cancel() { this.canceled = true; reject(new Error("Canceled")) },
      }
      animations.push(animation)
      return animation
    }
    return element
  }
  const outline = [target(), target()]
  const inner = [target(), target()]
  const letters = Array.from({length: 8}, target)
  const svg = target()
  svg.querySelectorAll = selector => selector === "[data-layer=outline] path" ? outline : inner
  const el = target()
  el.ownerDocument = document
  el.querySelector = () => svg
  el.querySelectorAll = () => letters
  const main = new FakeTarget()
  const pane = new FakeTarget()
  main.ownerDocument = document
  if (enterOnReturn !== null) main.attributes.set("data-enter-on-return", enterOnReturn)
  if (enterOnUnlock !== null) main.attributes.set("data-enter-on-unlock", enterOnUnlock)
  pane.attributes.set("aria-pressed", String(focused))
  const completions = []
  el.addEventListener("monolith:brand-complete", event => completions.push(event))
  const root = new FakeTarget()
  root.querySelector = selector => selector === "#main-content" ? main : pane
  el.closest = () => root
  main.closest = () => root
  beforeMount?.({el, main, pane, root, document, view})
  const hook = standalone ? createBrandReveal(el) : Object.assign({}, BrandReveal, {el})
  if (!standalone) hook.mounted()
  t.after(() => hook.destroy())
  // Resolve one native-animation phase, then let its Promise.all continuation run.
  const finishPhase = async () => {
    animations.forEach(animation => animation.finish())
    for (let turn = 0; turn < 5; turn++) await Promise.resolve()
  }
  const motion = matches => { preference.matches = matches; preference.emit("change") }
  return {hook, el, main, pane, root, document, view, preference, animations, completions, finishPhase, motion, svg, letters}
}

test("reveal traces the mark, flips letters, holds, and exits before handing off once", async t => {
  const {hook, el, animations, completions, finishPhase, svg, letters} = brand(t)
  assert.equal(animations.length, 0)
  el.emit("monolith:brand-focus")
  assert.equal(animations.length, 12)
  assert.deepEqual(animations[0].frames, [
    {strokeDashoffset: 1, opacity: 0},
    {strokeDashoffset: 1, opacity: 1, offset: .001},
    {strokeDashoffset: 0, opacity: 1},
  ])
  assert.deepEqual(animations[0].options, {duration: 1600, delay: 180, easing: "cubic-bezier(.45,0,.2,1)", fill: "both"})
  assert.equal(animations[2].options.duration, 1100)
  assert.equal(animations[2].options.delay, 1100)
  assert.equal(animations[3].options.duration, 500)
  assert.equal(animations[3].options.delay, 1850)
  assert.deepEqual(animations[11].options, {duration: 600, delay: 3195, easing: "cubic-bezier(.16,1,.3,1)", fill: "both"})
  assert.deepEqual(completions, [])
  await finishPhase()
  assert.equal(animations.length, 13)
  assert.equal(animations[12].element, el)
  assert.equal(animations[12].options.duration, 360)
  await finishPhase()
  assert.equal(animations.length, 22)
  assert.equal(animations[13].element, svg)
  assert.deepEqual(animations[13].options, {duration: 900, delay: 150, easing: "cubic-bezier(.65,0,.35,1)", fill: "both"})
  assert.equal(animations[14].element, letters[0])
  assert.deepEqual(animations[14].options, {duration: 600 / 1.8, delay: 0, easing: "cubic-bezier(.7,0,.84,0)", fill: "both"})
  assert.deepEqual(completions, [])
  await finishPhase()
  assert.equal(hook.completed, true)
  assert.equal(hook.active, false)
  assert.ok(animations.every(animation => animation.canceled))
  assert.equal(completions.length, 1)
  assert.equal(completions[0].bubbles, true)
  assert.equal(completions[0].target, el)
  hook.complete()
  el.emit("monolith:brand-focus")
  assert.equal(animations.length, 22)
  assert.equal(completions.length, 1)
})

test("duplicate focus signals do not overlap an active reveal", t => {
  const {el, animations} = brand(t)
  el.emit("monolith:brand-focus")
  el.emit("monolith:brand-focus")
  assert.equal(animations.length, 12)
})

for (const phase of [0, 1, 2]) {
  for (const event of ["monolith:brand-reset", "beforeprint", "phx:page-loading-start", "reduced-motion"]) {
    test(`${event} during phase ${phase} restores static artwork without replay or delayed handoff`, async t => {
      const {hook, el, view, motion, animations, completions, finishPhase} = brand(t)
      el.emit("monolith:brand-focus")
      for (let index = 0; index < phase; index++) await finishPhase()
      if (event === "reduced-motion") motion(true)
      else (event === "monolith:brand-reset" ? el : view).emit(event)
      const count = animations.length
      assert.equal(hook.active, false)
      assert.equal(hook.completed, true)
      assert.ok(animations.every(animation => animation.canceled))
      motion(false)
      el.emit("monolith:brand-focus")
      await finishPhase()
      assert.equal(animations.length, count)
      assert.equal(completions.length, 1)
    })
  }
}

test("dormant motion changes do not open the gate; reduced-motion reveal completes without animation", t => {
  const {hook, el, motion, animations, completions} = brand(t)
  motion(true)
  assert.equal(hook.completed, false)
  assert.equal(completions.length, 0)
  el.emit("monolith:brand-focus")
  assert.equal(hook.completed, true)
  assert.equal(animations.length, 0)
  assert.equal(completions.length, 1)
})

for (const reduced of [false, true]) {
  test(`mount catches focus established before registration (reduced: ${reduced})`, t => {
    const {hook, animations, completions} = brand(t, {focused: true, reduced})
    assert.equal(hook.active, !reduced)
    assert.equal(hook.completed, reduced)
    assert.equal(animations.length, reduced ? 0 : 12)
    assert.equal(completions.length, reduced ? 1 : 0)
  })
}

test("authorized return skips animation", t => {
  const {hook, animations, completions} = brand(t, {enterOnReturn: "true"})
  assert.equal(hook.completed, true)
  assert.equal(animations.length, 0)
  assert.equal(completions.length, 1)
})

test("standalone API supports reveal, cancellation, and teardown", t => {
  const {hook, animations, completions, el, view, preference} = brand(t, {standalone: true})
  hook.reveal()
  hook.finishWithoutMotion()
  hook.reveal()
  assert.equal(animations.length, 12)
  assert.equal(completions.length, 1)
  hook.destroy()
  assert.equal(el.listenerCount, 1)
  assert.equal(view.listenerCount, 0)
  assert.equal(preference.listenerCount, 0)
})

test("destruction cancels every animation/listener without handing off or continuing", async t => {
  const {hook, el, animations, view, preference, completions, finishPhase} = brand(t)
  el.emit("monolith:brand-focus")
  hook.destroy()
  assert.ok(animations.every(animation => animation.canceled))
  assert.equal(el.listenerCount, 1)
  assert.equal(view.listenerCount, 0)
  assert.equal(preference.listenerCount, 0)
  el.emit("monolith:brand-focus")
  view.emit("beforeprint")
  await finishPhase()
  assert.equal(animations.length, 12)
  assert.equal(completions.length, 0)
})

function entrance(t, {el, main, pane, root, document}) {
  const content = new FakeTarget()
  content.attributes.set("inert", "")
  main.attributes.set("data-entered", "false")
  const heading = {focus() { document.activeElement = heading }}
  content.querySelector = () => heading
  main.querySelector = selector => selector === "#workspace-content" ? content
    : selector === "[data-workspace-heading]" ? heading : null
  root.attributes.set("data-workspace-focus", "focus")
  root.attributes.set("data-workspace-reset", "reset")
  const sticky = []
  const mutate = operation => { sticky.push(operation); operation() }
  const hook = {...WorkspaceEntrance, el: main, handleEvent() {}, js: () => ({
    setAttribute: (target, name, value) => mutate(() => target.attributes.set(name, value)),
    removeAttribute: (target, name) => mutate(() => target.attributes.delete(name)),
    exec: command => {
      mutate(() => pane.attributes.set("aria-pressed", String(command === "focus")))
      el.emit(command === "focus" ? "monolith:brand-focus" : "monolith:brand-reset")
    },
  })}
  const onComplete = () => main.emit("monolith:brand-complete")
  el.addEventListener("monolith:brand-complete", onComplete)
  t.after(() => {
    hook.destroyed()
    el.removeEventListener("monolith:brand-complete", onComplete)
  })
  const patch = () => {
    content.attributes.set("inert", "")
    main.attributes.set("data-entered", "false")
    for (const operation of sticky) operation()
  }
  return {hook, content, patch}
}

for (const order of ["entrance-first", "brand-first"]) {
  test(`authorized return opens without motion with ${order} mounting`, t => {
    let gate
    const draft = {id: "reply", value: "Draft"}
    const current = brand(t, {enterOnReturn: "true", beforeMount: fixture => {
      fixture.document.activeElement = draft
      gate = entrance(t, fixture)
      if (order === "entrance-first") gate.hook.mounted()
    }})
    if (order === "brand-first") gate.hook.mounted()
    assert.equal(current.hook.completed, true)
    assert.equal(current.hook.active, false)
    assert.equal(current.pane.getAttribute("aria-pressed"), "true")
    assert.equal(gate.content.getAttribute("inert"), null)
    assert.equal(current.document.activeElement, draft)
    assert.equal(draft.value, "Draft")
    gate.hook.js().exec("reset")
    gate.patch()
    assert.equal(current.pane.getAttribute("aria-pressed"), "false")
    assert.equal(gate.content.getAttribute("inert"), null)
    gate.hook.js().exec("focus")
    assert.equal(current.animations.length, 0)
    assert.equal(current.completions.length, 1)
  })
}
for (const order of ["entrance-first", "brand-first"]) {
  for (const reduced of [false, true]) {
    test(`successful unlock plays once with ${order} mounting and reduced motion ${reduced}`, async t => {
      let gate
      const draft = {id: "reply", value: "Unfinished draft"}
      const current = brand(t, {reduced, enterOnUnlock: "true", beforeMount: fixture => {
        fixture.document.activeElement = draft
        gate = entrance(t, fixture)
        if (order === "entrance-first") gate.hook.mounted()
      }})
      if (order === "brand-first") gate.hook.mounted()
      assert.equal(current.pane.getAttribute("aria-pressed"), "true")
      assert.equal(gate.content.getAttribute("inert"), reduced ? null : "")
      if (!reduced) {
        await current.finishPhase()
        await current.finishPhase()
        await current.finishPhase()
      }
      assert.equal(gate.content.getAttribute("inert"), null)
      assert.equal(current.document.activeElement, draft)
      assert.equal(draft.value, "Unfinished draft")
      const effects = current.animations.length
      gate.patch()
      gate.hook.js().exec("reset")
      gate.hook.js().exec("focus")
      assert.equal(gate.content.getAttribute("inert"), null)
      assert.equal(current.animations.length, effects)
      assert.equal(current.completions.length, 1)
    })
  }
}


test("Escape mid-entrance opens the canceled gate without refocusing or replaying", async t => {
  let gate
  const current = brand(t, {focused: true, beforeMount: fixture => {
    gate = entrance(t, fixture)
    gate.hook.mounted()
  }})
  const active = current.document.activeElement
  const escape = new Event("keydown")
  Object.defineProperty(escape, "key", {value: "Escape"})
  current.view.dispatchEvent(escape)
  gate.patch()
  assert.equal(current.hook.completed, true)
  assert.equal(current.pane.getAttribute("aria-pressed"), "false")
  assert.equal(gate.content.getAttribute("inert"), null)
  assert.equal(current.document.activeElement, active)
  gate.hook.js().exec("focus")
  await current.finishPhase()
  assert.equal(current.animations.length, 12)
  assert.equal(current.completions.length, 1)
})
