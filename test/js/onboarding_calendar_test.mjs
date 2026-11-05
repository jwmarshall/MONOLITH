import assert from "node:assert/strict"
import test from "node:test"
import {initOnboardingCalendar} from "../../assets/js/onboarding_calendar.js"

class Target extends EventTarget {
  attributes = new Map()
  setAttribute(key, value) { this.attributes.set(key, value) }
  removeAttribute(key) { this.attributes.delete(key) }
  emit(type) { this.dispatchEvent(new Event(type, {cancelable: true})) }
}

function page(t, initial = {}) {
  const win = new Target(), timers = new Map(), requests = []
  const doc = {defaultView: win, activeElement: null}
  let serial = 0, installed = 0
  win.location = {
    href: "http://localhost/onboarding/calendar", origin: "http://localhost", pathname: "/onboarding/calendar",
    assign: url => { win.destination = url },
  }
  win.setTimeout = fn => { const id = ++serial; timers.set(id, fn); return id }
  win.clearTimeout = id => timers.delete(id)
  win.fetch = (url, options) => new Promise((resolve, reject) => requests.push({url, options, resolve, reject}))
  const node = properties => {
    const element = Object.assign(new Target(), {id: "", disabled: false, hidden: false}, properties)
    element.focus = () => { doc.activeElement = element }
    element.closest = selector => selector === "fieldset" ? element.fieldset : null
    return element
  }
  const picker = (options = {}) => {
    const section = node({dataset: {workspaceId: "workspace-a", accountId: "account-a", generation: "generation-a", ...options.identity}})
    const progress = node({dataset: {
      loading: String(!!options.loading), autoload: String(!!options.autoload), statusOnly: String(!!options.statusOnly),
    }})
    const error = node({hidden: true}), pending = node({hidden: true}), loading = node()
    const heading = node({id: "onboarding-calendar-picker-heading"})
    const fieldset = options.choices === false ? null : node({disabled: !!options.loading})
    const choices = fieldset ? ["primary", "shared"].map(value => node({
      value, type: "checkbox", checked: value === "primary", fieldset,
    })) : []
    const button = node({id: "onboarding-calendar-load-button", disabled: !!options.loading})
    const save = fieldset ? node({id: "onboarding-calendar-save", disabled: !!options.loading}) : null
    const form = node({action: win.location.href, elements: {}})
    for (const [name, value] of Object.entries({
      operation: "refresh_calendars",
      workspace_id: section.dataset.workspaceId, account_id: section.dataset.accountId,
      generation: section.dataset.generation, _csrf_token: "synthetic-csrf", from: "", to: "", date: "", timezone: "",
    })) form.elements[name] = {value}
    form.querySelector = () => button
    const status = node({id: "onboarding-calendar-status-refresh", href: win.location.href + "?status=1"})
    const selectors = {
      "[data-calendar-progress]": progress, "[data-calendar-client-error]": error,
      "[data-calendar-poll-stopped]": pending, "[data-calendar-loading-message]": loading,
      "[data-calendar-load]": form, "[data-calendar-status]": status, fieldset, h2: heading,
      "#onboarding-calendar-save": save,
    }
    section.querySelector = selector => selectors[selector] ?? null
    section.querySelectorAll = selector => {
      if (selector === 'input[type="checkbox"]') return choices
      if (selector === "fieldset, button") return [fieldset, button, save].filter(Boolean)
      return []
    }
    section.contains = element => [heading, fieldset, button, save, form, status, ...choices].includes(element)
    section.replaceWith = next => { doc.picker = next; installed++ }
    return Object.assign(section, {progress, error, pending, loading, heading, fieldset, choices, button, save, form, status})
  }
  doc.picker = picker(initial)
  doc.querySelector = selector => selector === "[data-onboarding-calendar]" ? doc.picker : null
  doc.getElementById = id => [doc.picker.heading, doc.picker.button, doc.picker.status, doc.picker.save].find(node => node?.id === id)
  doc.importNode = next => next
  win.DOMParser = class {
    parseFromString(text) {
      const next = picker(JSON.parse(text))
      return {querySelector: selector => selector === "[data-onboarding-calendar]" ? next : null}
    }
  }
  win.FormData = class {
    constructor(form) { this.entries = Object.entries(form.elements).map(([key, input]) => [key, input.value]) }
    [Symbol.iterator]() { return this.entries[Symbol.iterator]() }
  }
  const settle = async () => { for (let turn = 0; turn < 8; turn++) await Promise.resolve() }
  const respond = async (index, options = {}, response = {}) => {
    requests[index].resolve({ok: true, text: async () => JSON.stringify(options), ...response})
    await settle()
  }
  const tick = async () => {
    assert.equal(timers.size, 1)
    const [id, callback] = timers.entries().next().value
    timers.delete(id)
    callback()
    await settle()
  }
  t.after(() => win.emit("pagehide"))
  return {doc, win, requests, timers, settle, respond, tick, start: () => initOnboardingCalendar(doc), get installed() { return installed }}
}

test("actual initializer posts browser-local boundaries and replaces loading with the picker", async t => {
  const NativeDate = globalThis.Date, previousTZ = process.env.TZ
  process.env.TZ = "America/Los_Angeles"
  globalThis.Date = class extends NativeDate {
    constructor(...args) { super(...(args.length ? args : ["2026-03-08T12:00:00Z"])) }
  }
  t.after(() => {
    globalThis.Date = NativeDate
    if (previousTZ === undefined) delete process.env.TZ
    else process.env.TZ = previousTZ
  })
  const current = page(t, {autoload: true, choices: false})
  current.start()
  assert.equal(current.requests.length, 1)
  const {options} = current.requests[0]
  assert.equal(options.method, "POST")
  assert.equal(options.body.get("operation"), "load_calendars")
  assert.deepEqual(Object.fromEntries([...options.body].filter(([key]) => ["from", "to", "date", "timezone"].includes(key))), {
    from: "2026-03-08T08:00:00.000Z", to: "2026-03-09T07:00:00.000Z", date: "2026-03-08", timezone: "America/Los_Angeles",
  })
  assert.equal(options.body.get("workspace_id"), "workspace-a")
  assert.equal(options.body.get("account_id"), "account-a")
  assert.equal(options.body.get("generation"), "generation-a")
  assert.equal(options.body.get("_csrf_token"), "synthetic-csrf")
  await current.respond(0, {loading: true, choices: false})
  assert.equal(current.timers.size, 1)
  await current.tick()
  assert.equal(current.requests[1].options.method, undefined)
  assert.match(current.requests[1].url, /\?status=1$/)
  await current.respond(1, {})
  assert.equal(current.installed, 2)
  assert.equal(current.doc.picker.fieldset.disabled, false)
  assert.equal(current.timers.size, 0)
})

test("manual refresh preserves edited choices and restores keyboard focus on status completion", async t => {
  const current = page(t)
  current.start()
  current.doc.picker.choices[0].checked = false
  current.doc.picker.choices[1].checked = true
  current.doc.picker.button.focus()
  current.doc.picker.form.emit("submit")
  assert.equal(current.requests[0].options.body.get("operation"), "refresh_calendars")
  assert.equal(current.doc.picker.save.disabled, true)
  await current.respond(0, {loading: true})
  assert.deepEqual(current.doc.picker.choices.map(input => input.checked), [false, true])
  assert.equal(current.doc.activeElement, current.doc.picker.heading)
  current.doc.picker.status.focus()
  await current.tick()
  await current.respond(1, {})
  assert.deepEqual(current.doc.picker.choices.map(input => input.checked), [false, true])
  assert.equal(current.doc.activeElement, current.doc.picker.status)
  assert.equal(current.doc.picker.save.disabled, false)
})

test("an enabled choice retains focus and its unsaved value across status-only replacement", async t => {
  const current = page(t)
  current.start()
  current.doc.picker.choices[1].checked = true
  current.doc.picker.choices[1].focus()
  current.doc.picker.status.emit("click")
  await current.respond(0, {})
  assert.equal(current.doc.activeElement, current.doc.picker.choices[1])
  assert.equal(current.doc.picker.choices[1].checked, true)
  assert.equal(current.timers.size, 0)
})

test("focus moving to selection save during a status request survives its replacement", async t => {
  const current = page(t)
  current.start()
  current.doc.picker.status.emit("click")
  current.doc.picker.save.focus()
  await current.respond(0, {})
  assert.equal(current.doc.activeElement, current.doc.picker.save)
  assert.equal(current.doc.picker.save.disabled, false)
})

test("duplicate submits are ignored and an older poll cannot overwrite a newer load", async t => {
  const current = page(t, {loading: true})
  current.start()
  await current.tick()
  current.doc.picker.form.emit("submit")
  current.doc.picker.form.emit("submit")
  assert.equal(current.requests.length, 2)
  await current.respond(1, {})
  await current.respond(0, {loading: true})
  assert.equal(current.installed, 1)
  assert.equal(current.doc.picker.progress.dataset.loading, "false")
  assert.equal(current.timers.size, 0)
})

for (const kind of ["load", "poll", "status"]) {
  test(`${kind} response rejects workspace/account/generation switches without installing controls`, async t => {
    for (const key of ["workspaceId", "accountId", "generation"]) {
      const current = page(t, {autoload: kind === "load", loading: kind === "poll"})
      current.start()
      if (kind === "poll") await current.tick()
      if (kind === "status") current.doc.picker.status.emit("click")
      await current.respond(0, {loading: kind === "poll", identity: {[key]: "identity-b"}})
      assert.equal(current.installed, 0)
      assert.equal(current.doc.picker.dataset[key], {workspaceId: "workspace-a", accountId: "account-a", generation: "generation-a"}[key])
      assert.equal(current.doc.picker.error.hidden, false)
      assert.equal(current.doc.picker.button.disabled, true)
      assert.equal(current.requests[0].options.signal.aborted, true)
      assert.equal(current.timers.size, 0)
      current.doc.picker.form.emit("submit")
      current.doc.picker.status.emit("click")
      assert.equal(current.requests.length, 1)
    }
  })
}

test("pagehide aborts pending work and a late fetch or text response cannot install HTML", async t => {
  for (const awaitingText of [false, true]) {
    const current = page(t, {autoload: true})
    current.start()
    let finishText
    if (awaitingText) {
      current.requests[0].resolve({ok: true, text: () => new Promise(resolve => { finishText = resolve })})
      await current.settle()
    }
    current.win.emit("pagehide")
    if (awaitingText) finishText(JSON.stringify({}))
    else await current.respond(0, {})
    await current.settle()
    assert.equal(current.requests[0].options.signal.aborted, true)
    assert.equal(current.installed, 0)
    assert.equal(current.timers.size, 0)
    current.doc.picker.form.emit("submit")
    assert.equal(current.requests.length, 1)
  }
})

test("reinitialization disposes pending work and restores from BFCache without duplicate listeners", async t => {
  const current = page(t, {autoload: true})
  current.start()
  current.start()
  assert.equal(current.requests[0].options.signal.aborted, true)
  await current.respond(0, {})
  assert.equal(current.installed, 0)
  await current.respond(1, {})
  current.win.emit("pagehide")
  const resume = new Event("pageshow")
  Object.defineProperty(resume, "persisted", {value: true})
  current.win.dispatchEvent(resume)
  current.doc.picker.form.emit("submit")
  current.doc.picker.form.emit("submit")
  assert.equal(current.requests.length, 3)
})

test("owner redirects navigate the whole page and never install returned markup", async t => {
  const current = page(t, {autoload: true})
  current.start()
  await current.respond(0, {}, {redirected: true, url: "http://localhost/unlock"})
  assert.equal(current.win.destination, "http://localhost/unlock")
  assert.equal(current.installed, 0)
  assert.equal(current.requests[0].options.signal.aborted, true)
})

test("twenty pending polls stop visibly; explicit status recovery is a single GET without provider authorization", async t => {
  const current = page(t, {loading: true})
  current.start()
  for (let index = 0; index < 20; index++) {
    await current.tick()
    await current.respond(index, {loading: true})
  }
  assert.equal(current.requests.length, 20)
  assert.equal(current.timers.size, 0)
  assert.equal(current.doc.picker.pending.hidden, false)
  assert.equal(current.doc.picker.loading.hidden, true)
  current.doc.picker.status.focus()
  current.doc.picker.status.emit("click")
  current.doc.picker.status.emit("click")
  assert.equal(current.requests.length, 21)
  assert.equal(current.requests[20].options.method, undefined)
  assert.equal(current.requests[20].options.body, undefined)
  await current.respond(20, {loading: true})
  assert.equal(current.timers.size, 0)
  current.doc.picker.status.emit("click")
  await current.respond(21, {})
  assert.equal(current.doc.picker.fieldset.disabled, false)
  assert.equal(current.doc.activeElement, current.doc.picker.status)
  assert.equal(current.timers.size, 0)
})

test("status-only entry never autoloads or automatically polls and failures retain editable choices", async t => {
  const current = page(t, {statusOnly: true, autoload: true})
  current.start()
  assert.equal(current.requests.length, 0)
  assert.equal(current.timers.size, 0)
  current.doc.picker.choices[1].checked = true
  current.doc.picker.form.emit("submit")
  current.requests[0].reject(new Error("offline"))
  await current.settle()
  assert.equal(current.doc.picker.fieldset.disabled, false)
  assert.equal(current.doc.picker.save.disabled, false)
  assert.equal(current.doc.picker.choices[1].checked, true)
  assert.equal(current.doc.picker.button.attributes.has("aria-disabled"), false)
  assert.equal(current.doc.picker.error.hidden, false)
  assert.equal(current.timers.size, 0)
})

test("manual initial load is explicit refresh, unlike automatic first preparation", async t => {
  const current = page(t, {choices: false})
  current.start()
  current.doc.picker.form.emit("submit")
  assert.equal(current.requests.length, 1)
  assert.equal(current.requests[0].options.body.get("operation"), "refresh_calendars")
  await current.respond(0, {loading: true, choices: false})
  assert.equal(current.timers.size, 1)
})

test("pending status-only entry is visibly stopped and navigation cancels scheduled polling", t => {
  const status = page(t, {statusOnly: true, loading: true})
  status.start()
  assert.equal(status.requests.length, 0)
  assert.equal(status.timers.size, 0)
  assert.equal(status.doc.picker.pending.hidden, false)
  assert.equal(status.doc.picker.loading.hidden, true)

  const polling = page(t, {loading: true})
  polling.start()
  assert.equal(polling.timers.size, 1)
  polling.win.emit("pagehide")
  assert.equal(polling.timers.size, 0)
  assert.equal(polling.requests.length, 0)
})

test("cross-origin redirects cannot navigate or install controls", async t => {
  const current = page(t, {autoload: true})
  current.start()
  await current.respond(0, {}, {redirected: true, url: "https://elsewhere.invalid/unlock"})
  assert.equal(current.win.destination, undefined)
  assert.equal(current.installed, 0)
  assert.equal(current.doc.picker.error.hidden, false)
  assert.equal(current.timers.size, 0)
})

for (const awaitingText of [false, true]) {
  test(`a stalled ${awaitingText ? "body" : "fetch"} times out, ignores late completion and permits explicit recovery`, async t => {
    const current = page(t)
    current.start()
    current.doc.picker.choices[1].checked = true
    current.doc.picker.form.emit("submit")
    let finishText
    if (awaitingText) {
      current.requests[0].resolve({ok: true, text: () => new Promise(resolve => { finishText = resolve })})
      await current.settle()
    }
    await current.tick()
    assert.equal(current.requests[0].options.signal.aborted, true)
    assert.equal(current.doc.picker.error.hidden, false)
    assert.equal(current.doc.picker.fieldset.disabled, false)
    assert.equal(current.doc.picker.save.disabled, false)
    assert.equal(current.doc.picker.button.attributes.has("aria-disabled"), false)
    assert.equal(current.doc.picker.choices[1].checked, true)
    assert.equal(current.timers.size, 0)
    if (awaitingText) finishText(JSON.stringify({}))
    else await current.respond(0, {})
    await current.settle()
    assert.equal(current.installed, 0)
    current.doc.picker.status.focus()
    current.doc.picker.status.emit("click")
    await current.respond(1, {})
    assert.equal(current.installed, 1)
    assert.equal(current.doc.activeElement, current.doc.picker.status)
    assert.equal(current.doc.picker.choices[1].checked, true)
    assert.equal(current.timers.size, 0)
  })
}

test("a stalled automatic poll stops visibly and explicit status recovery does not restart polling", async t => {
  const current = page(t, {loading: true})
  current.start()
  await current.tick()
  await current.tick()
  assert.equal(current.requests[0].options.signal.aborted, true)
  assert.equal(current.doc.picker.pending.hidden, false)
  assert.equal(current.doc.picker.loading.hidden, true)
  assert.equal(current.timers.size, 0)
  current.doc.picker.status.emit("click")
  await current.respond(1, {loading: true})
  assert.equal(current.requests.length, 2)
  assert.equal(current.timers.size, 0)
})
