import assert from "node:assert/strict"
import test from "node:test"
import BrandReveal from "../../assets/js/hooks/brand_reveal.js"
import WorkspaceEntrance from "../../assets/js/hooks/workspace_entrance.js"
import {gsap} from "../../assets/vendor/gsap/gsap.js"

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

function brand(t, {reduced = false, focused = false, enterOnReturn = null, beforeMount} = {}) {
  const preference = new FakeTarget()
  preference.matches = reduced
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window")
  Object.defineProperty(globalThis, "window", {configurable: true, value: {
    matchMedia: query => {
      assert.equal(query, "(prefers-reduced-motion: reduce)")
      return preference
    },
  }})
  t.after(() => {
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow)
    else delete globalThis.window
  })

  // Real vendored GSAP animates plain properties in Node. This exercises timeline
  // callbacks and hook lifecycle, not browser SVG/CSSPlugin rendering or layout.
  const stroke = {strokeDasharray: 0, strokeDashoffset: 0, getTotalLength: () => 100}
  const letters = Array.from({length: 8}, () => ({opacity: 1, rotationX: 0, yPercent: 0}))
  const el = new FakeTarget()
  el.querySelector = selector => {
    assert.equal(selector, "#monolith-monogram-stroke")
    return stroke
  }
  el.querySelectorAll = selector => {
    assert.equal(selector, ".workspace-letter")
    return letters
  }
  const main = new FakeTarget()
  if (enterOnReturn !== null) main.attributes.set("data-enter-on-return", enterOnReturn)
  const pane = new FakeTarget()
  pane.attributes.set("aria-pressed", String(focused))
  const root = new FakeTarget()
  root.querySelector = selector => {
    if (selector === "#main-content") return main
    assert.equal(selector, "#workspace-pane")
    return pane
  }
  el.closest = selector => {
    assert.equal(selector, "#workspace")
    return root
  }
  const completions = []
  el.addEventListener("monolith:brand-complete", event => completions.push(event))
  const hook = Object.assign({}, BrandReveal, {el})
  t.after(() => {
    hook.destroyed()
    gsap.ticker.sleep()
  })
  beforeMount?.({el, main, pane, root})
  hook.mounted()
  // Advance explicitly: no wall-clock waits or background animation races.
  gsap.ticker.sleep()
  const restart = t.mock.method(hook.timeline, "restart")
  const seek = progress => {
    hook.timeline.time(progress * hook.timeline.labels.exit).pause()
    gsap.ticker.sleep()
  }
  const motion = matches => {
    preference.matches = matches
    preference.emit("change")
    gsap.ticker.sleep()
  }
  const exit = progress => {
    const start = hook.timeline.labels.exit
    hook.timeline.time(start + progress * (hook.timeline.duration() - start)).pause()
    gsap.ticker.sleep()
  }
  const finish = () => { seek(1); exit(1) }
  return {hook, el, main, pane, root, preference, completions, stroke, letters, restart, seek, exit, motion, finish}
}

test("normal reveal holds, exits in the opposite direction, then completes exactly once", t => {
  const {hook, el, completions, restart, seek, exit, stroke, letters} = brand(t)
  assert.equal(hook.active, false)
  assert.equal(hook.completed, false)
  assert.equal(hook.timeline.paused(), true)
  assert.deepEqual(completions, [])

  el.emit("monolith:brand-focus")
  assert.equal(restart.mock.callCount(), 1)
  assert.equal(hook.active, true)
  seek(0.5)
  assert.equal(hook.completed, false)
  assert.deepEqual(completions, [])
  seek(1)
  assert.equal(hook.completed, false)
  assert.equal(hook.exiting, true)
  assert.equal(hook.timeline.reversed(), false)
  assert.equal(hook.timeline.timeScale(), 1)
  assert.deepEqual(completions, [])
  assert.equal(stroke.strokeDashoffset, 0)
  for (const letter of letters) {
    assert.equal(letter.opacity, 1)
    assert.equal(letter.rotationX, 0)
    assert.equal(letter.yPercent, 0)
  }
  exit(0.15)
  assert.equal(hook.completed, false)
  assert.ok(letters[0].opacity < letters[7].opacity, "exit proceeds left-to-right")
  assert.ok(letters[0].rotationX > 0, "letters continue flipping upward")
  assert.ok(letters[0].yPercent < 0)
  exit(0.7)
  assert.equal(hook.completed, false)
  assert.ok(stroke.strokeDashoffset < 0 && stroke.strokeDashoffset > -100)
  assert.ok(letters.every(letter => letter.opacity === 0))
  exit(1)
  assert.equal(hook.completed, true)
  assert.equal(stroke.strokeDashoffset, -100)
  for (const letter of letters) assert.equal(letter.opacity, 0)
  assert.equal(completions.length, 1)
  assert.equal(completions[0].type, "monolith:brand-complete")
  assert.equal(completions[0].bubbles, true)
  assert.equal(completions[0].target, el)

  hook.complete()
  el.emit("monolith:brand-focus")
  el.emit("monolith:brand-reset")
  assert.equal(completions.length, 1)
})

test("duplicate focus/click signals do not restart an active animation", t => {
  const {el, hook, restart, seek} = brand(t)
  el.emit("monolith:brand-focus")
  seek(0.4)
  el.emit("monolith:brand-focus")
  el.emit("monolith:brand-focus")
  assert.equal(restart.mock.callCount(), 1)
  assert.equal(hook.timeline.time(), 0.4 * hook.timeline.labels.exit)
})

test("reset mid-animation freezes in place and a fresh focus replays from the start", t => {
  const {el, hook, restart, seek, completions, stroke, finish} = brand(t)
  el.emit("monolith:brand-focus")
  seek(0.5)
  const interruptedOffset = stroke.strokeDashoffset
  assert.ok(interruptedOffset > 0 && interruptedOffset < 100)
  el.emit("monolith:brand-reset")
  assert.equal(hook.active, false)
  assert.equal(hook.completed, false)
  assert.equal(hook.timeline.paused(), true)
  assert.equal(hook.timeline.time(), 0.5 * hook.timeline.labels.exit)
  assert.equal(stroke.strokeDashoffset, interruptedOffset)
  assert.deepEqual(completions, [])

  el.emit("monolith:brand-focus")
  assert.equal(restart.mock.callCount(), 2)
  assert.equal(hook.timeline.progress(), 0)
  assert.equal(hook.timeline.paused(), false)
  assert.equal(stroke.strokeDashoffset, 100)
  finish()
  assert.equal(completions.length, 1)
})

test("completed state survives idle reset and prevents replay on resume", t => {
  const {el, hook, restart, finish, completions} = brand(t)
  el.emit("monolith:brand-focus")
  finish()
  for (let cycle = 0; cycle < 2; cycle++) {
    el.emit("monolith:brand-reset")
    assert.equal(hook.active, false)
    assert.equal(hook.completed, true)
    el.emit("monolith:brand-focus")
    assert.equal(hook.timeline.progress(), 1)
    assert.equal(hook.timeline.paused(), true)
  }
  assert.equal(restart.mock.callCount(), 1)
  assert.equal(completions.length, 1)
})

test("initial reduced motion completes immediately without restarting the timeline", t => {
  const {el, hook, restart, completions} = brand(t, {reduced: true})
  assert.equal(hook.completed, false)
  assert.deepEqual(completions, [])
  el.emit("monolith:brand-focus")
  assert.equal(hook.completed, true)
  assert.equal(hook.timeline.progress(), 1)
  assert.equal(hook.timeline.paused(), true)
  assert.equal(restart.mock.callCount(), 0)
  assert.equal(completions.length, 1)
  el.emit("monolith:brand-focus")
  assert.equal(completions.length, 1)
})

test("enabling reduced motion mid-animation completes once and disabling it does not replay", t => {
  const {el, hook, restart, seek, motion, completions} = brand(t)
  el.emit("monolith:brand-focus")
  seek(0.4)
  motion(true)
  assert.equal(hook.completed, true)
  assert.equal(hook.timeline.progress(), 1)
  assert.equal(hook.timeline.paused(), true)
  assert.equal(completions.length, 1)
  motion(true)
  motion(false)
  el.emit("monolith:brand-reset")
  el.emit("monolith:brand-focus")
  assert.equal(restart.mock.callCount(), 1)
  assert.equal(completions.length, 1)
})

test("preference changes while inactive do not complete until focus resumes", t => {
  const {el, hook, seek, motion, completions, restart} = brand(t)
  motion(true)
  assert.equal(hook.completed, false)
  assert.deepEqual(completions, [])
  motion(false)
  el.emit("monolith:brand-focus")
  seek(0.4)
  el.emit("monolith:brand-reset")
  motion(true)
  assert.equal(hook.timeline.time(), 0.4 * hook.timeline.labels.exit)
  assert.equal(hook.completed, false)
  assert.deepEqual(completions, [])
  el.emit("monolith:brand-focus")
  assert.equal(hook.completed, true)
  assert.equal(hook.timeline.paused(), true)
  assert.equal(restart.mock.callCount(), 1)
  assert.equal(completions.length, 1)
})

for (const reduced of [false, true]) {
  test(`mount catches focus established before hook registration (reduced motion: ${reduced})`, t => {
    const {hook, completions, finish} = brand(t, {focused: true, reduced})
    assert.equal(hook.active, true)
    if (!reduced) {
      assert.equal(hook.completed, false)
      assert.equal(hook.timeline.paused(), false)
      finish()
    }
    assert.equal(hook.completed, true)
    assert.equal(completions.length, 1)
  })
}

for (const enterOnReturn of [null, "false"]) {
  test(`ordinary brand mount stays dormant for return flag ${JSON.stringify(enterOnReturn)}`, t => {
    const {hook, completions} = brand(t, {enterOnReturn})
    assert.equal(hook.completed, false)
    assert.equal(hook.active, false)
    assert.equal(hook.timeline.paused(), true)
    assert.equal(hook.timeline.progress(), 0)
    assert.deepEqual(completions, [])
  })
}

for (const order of ["entrance-first", "brand-first"]) {
  test(`return skips motion and opens the workspace with ${order} hook mounting`, t => {
    let entranceHook, content, controls, document, sticky
    const current = brand(t, {
      enterOnReturn: "true",
      beforeMount: ({el, main, pane, root}) => {
        content = new FakeTarget()
        controls = new FakeTarget()
        content.attributes.set("inert", "")
        controls.attributes.set("inert", "")
        main.attributes.set("data-entered", "false")
        document = {body: {id: "body"}, activeElement: {id: "reply", tagName: "INPUT"}}
        main.ownerDocument = document
        main.closest = () => root
        main.querySelector = selector => {
          if (selector === "#workspace-content") return content
          if (selector === "#workspace-controls") return controls
          throw new Error(`Unexpected focus query: ${selector}`)
        }
        root.attributes.set("data-workspace-focus", "shared-focus-command")
        root.attributes.set("data-workspace-reset", "shared-reset-command")
        sticky = []
        const setAttribute = (target, name, value) => {
          sticky.push(() => target.attributes.set(name, value))
          sticky.at(-1)()
        }
        entranceHook = Object.assign({}, WorkspaceEntrance, {
          el: main,
          handleEvent() {},
          js: () => ({
            setAttribute,
            removeAttribute: (target, name) => {
              sticky.push(() => target.attributes.delete(name))
              sticky.at(-1)()
            },
            exec: command => {
              const focus = command === "shared-focus-command"
              assert.ok(focus || command === "shared-reset-command")
              setAttribute(pane, "aria-pressed", String(focus))
              el.emit(focus ? "monolith:brand-focus" : "monolith:brand-reset")
            },
          }),
        })
        // Node EventTarget does not bubble; forward the brand's real completion.
        const onComplete = () => main.emit("monolith:brand-complete")
        el.addEventListener("monolith:brand-complete", onComplete)
        t.after(() => {
          entranceHook.destroyed()
          el.removeEventListener("monolith:brand-complete", onComplete)
        })
        if (order === "entrance-first") entranceHook.mounted()
      },
    })
    if (order === "brand-first") entranceHook.mounted()

    const {hook, el, main, pane, root, completions, stroke, letters, restart} = current
    assert.equal(main.getAttribute("data-entered"), "true")
    assert.equal(content.getAttribute("inert"), null)
    assert.equal(controls.getAttribute("inert"), null)
    assert.equal(pane.getAttribute("aria-pressed"), "true")
    assert.equal(document.activeElement.id, "reply")
    assert.equal(hook.completed, true)
    assert.equal(hook.active, false, "no reveal was started")
    assert.equal(hook.timeline.paused(), true)
    assert.equal(hook.timeline.progress(), 1)
    assert.equal(stroke.strokeDashoffset, -100)
    assert.ok(letters.every(letter => letter.opacity === 0))
    assert.equal(completions.length, 1)

    // Escape and idle execute this same shared reset. Patches must not undo it.
    entranceHook.js().exec(root.getAttribute("data-workspace-reset"))
    main.attributes.set("data-entered", "false")
    content.attributes.set("inert", "")
    controls.attributes.set("inert", "")
    pane.attributes.set("aria-pressed", "false")
    for (const apply of sticky) apply()
    entranceHook.updated?.()
    assert.equal(pane.getAttribute("aria-pressed"), "false")
    assert.equal(main.getAttribute("data-entered"), "true")
    assert.equal(content.getAttribute("inert"), null)
    assert.equal(controls.getAttribute("inert"), null)
    assert.equal(hook.active, false)

    entranceHook.js().exec(root.getAttribute("data-workspace-focus"))
    el.emit("monolith:brand-focus")
    assert.equal(pane.getAttribute("aria-pressed"), "true")
    assert.equal(restart.mock.callCount(), 0)
    assert.equal(completions.length, 1)
  })
}

test("reset during the exit keeps the gate closed and fresh focus restarts at normal speed", t => {
  const {hook, el, seek, exit, restart, completions, finish, stroke, letters} = brand(t)
  el.emit("monolith:brand-focus")
  seek(1)
  exit(0.7)
  el.emit("monolith:brand-reset")
  assert.equal(hook.active, false)
  assert.equal(hook.timeline.paused(), true)
  assert.equal(hook.completed, false)
  assert.deepEqual(completions, [])
  el.emit("monolith:brand-focus")
  assert.equal(restart.mock.callCount(), 2)
  assert.equal(hook.exiting, false)
  assert.equal(hook.timeline.timeScale(), 1)
  assert.equal(hook.timeline.reversed(), false)
  assert.equal(hook.timeline.progress(), 0)
  assert.equal(stroke.strokeDashoffset, 100)
  for (const letter of letters) {
    assert.equal(letter.opacity, 0)
    assert.equal(letter.rotationX, -90)
    assert.equal(letter.yPercent, 60)
  }
  assert.deepEqual(completions, [])
  finish()
  assert.equal(completions.length, 1)
})

test("enabling reduced motion during the exit completes immediately without replay", t => {
  const {hook, el, seek, exit, motion, completions} = brand(t)
  el.emit("monolith:brand-focus")
  seek(1)
  exit(0.4)
  motion(true)
  assert.equal(hook.completed, true)
  assert.equal(hook.timeline.paused(), true)
  assert.equal(completions.length, 1)
  motion(false)
  el.emit("monolith:brand-focus")
  assert.equal(hook.timeline.paused(), true)
  assert.equal(completions.length, 1)
})

test("destroying during the exit kills the timeline without handing off", t => {
  const {hook, el, seek, completions} = brand(t)
  el.emit("monolith:brand-focus")
  seek(1)
  hook.destroyed()
  assert.equal(hook.timeline.parent, null)
  assert.deepEqual(completions, [])
})

test("destruction removes hook and preference listeners and reverts the GSAP context", t => {
  const {el, preference, hook, seek, motion, restart, completions, stroke, letters} = brand(t)
  el.emit("monolith:brand-focus")
  seek(0.5)
  const revert = t.mock.method(hook.context, "revert")
  assert.equal(el.listenerCount, 3) // Two hook listeners plus the test completion observer.
  assert.equal(preference.listenerCount, 1)
  hook.destroyed()
  assert.equal(revert.mock.callCount(), 1)
  assert.equal(el.listenerCount, 1)
  assert.equal(preference.listenerCount, 0)
  assert.equal(stroke.strokeDashoffset, 0)
  for (const letter of letters) assert.equal(letter.opacity, 1)
  el.emit("monolith:brand-reset")
  el.emit("monolith:brand-focus")
  motion(true)
  assert.equal(restart.mock.callCount(), 1)
  assert.deepEqual(completions, [])
})
