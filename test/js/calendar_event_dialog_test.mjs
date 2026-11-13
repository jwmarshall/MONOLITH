import assert from "node:assert/strict"
import test from "node:test"
import CalendarEventDialog from "../../assets/js/hooks/calendar_event_dialog.js"

class Target {
  listeners = new Map()
  attributes = new Map()
  addEventListener(type, fn, capture = false) {
    if (!this.listeners.has(type)) this.listeners.set(type, [])
    this.listeners.get(type).push({fn, capture})
  }
  removeEventListener(type, fn, capture = false) {
    this.listeners.set(type, (this.listeners.get(type) ?? []).filter(item => item.fn !== fn || item.capture !== capture))
  }
  dispatchEvent(event) {
    const listeners = [...(this.listeners.get(event.type) ?? [])].sort((a, b) => Number(b.capture) - Number(a.capture))
    for (const {fn} of listeners) {
      fn(event)
      if (event.immediateStopped) break
    }
  }
  emit(type, details = {}) {
    const event = {type, defaultPrevented: false, immediateStopped: false, ...details,
      preventDefault() { this.defaultPrevented = true },
      stopImmediatePropagation() { this.immediateStopped = true },
    }
    this.dispatchEvent(event)
    return event
  }
  setAttribute(name, value) { this.attributes.set(name, value) }
  removeAttribute(name) { this.attributes.delete(name) }
  getAttribute(name) { return this.attributes.get(name) ?? null }
  get listenerCount() { return [...this.listeners.values()].reduce((sum, items) => sum + items.length, 0) }
}

function textNode() {
  return {textContent: "", set innerHTML(_value) { assert.fail("provider content must never enter HTML parsing") }}
}

function fixture(t) {
  const view = new Target()
  view.Event = class { constructor(type) { this.type = type } }
  const document = new Target()
  document.defaultView = view
  const fields = Object.fromEntries(["title", "account", "calendar", "time"].map(name => [name, textNode()]))
  const link = new Target()
  link.hidden = true
  Object.defineProperty(link, "href", {
    get: () => link.getAttribute("href"), set: value => link.setAttribute("href", value),
  })
  const focused = []
  const heading = {focus: options => { document.activeElement = heading; focused.push([heading, options]) }}
  document.querySelector = selector => selector === "[data-workspace-heading]" ? heading : null
  const closeButton = {focus: options => { document.activeElement = closeButton; focused.push([closeButton, options]) }}
  const dialog = new Target()
  dialog.open = false
  let shows = 0, closes = 0
  dialog.showModal = () => { dialog.open = true; shows++ }
  dialog.close = () => { dialog.open = false; closes++; dialog.emit("close") }
  dialog.querySelector = selector => selector === "button" ? closeButton
    : selector === "[data-calendar-dialog-link]" ? link
      : fields[selector.slice("[data-calendar-dialog-".length, -1)] ?? null
  const el = new Target()
  el.ownerDocument = document
  el.querySelector = () => dialog
  const triggers = new Set()
  el.contains = trigger => triggers.has(trigger)
  const hook = {...CalendarEventDialog, el, js: () => ({
    setAttribute: (target, name, value) => target.setAttribute(name, value),
    removeAttribute: (target, name) => target.removeAttribute(name),
  })}
  hook.mounted()
  t.after(() => hook.destroyed())
  let closed = 0
  document.addEventListener("monolith:modal-closed", () => closed++)
  const event = ({title = "Review", account = "owner@example.test", calendar = "Work", time = "09:00–09:30", url = "https://calendar.google.com/calendar/event?eid=synthetic", owned = true} = {}) => {
    const timeText = {textContent: time}
    const row = {id: "synthetic-occurrence", querySelector: () => timeText}
    const trigger = {isConnected: true, dataset: {eventTitle: title, eventAccount: account, eventCalendar: calendar, eventUrl: url},
      closest: selector => selector === ".calendar-event" ? row : null,
      focus: options => { document.activeElement = trigger; focused.push([trigger, options]) },
    }
    if (owned) triggers.add(trigger)
    const child = {closest: selector => selector === "[data-calendar-event-open]" ? trigger : null}
    return {trigger, row, child, timeText, open: () => el.emit("click", {target: child})}
  }
  return {view, document, el, dialog, fields, link, focused, closeButton, heading, event, hook,
    counts: () => ({shows, closes, closed})}
}

test("event disclosure keeps provider text literal and uses the browser-local time readout", t => {
  const {event, fields, link, dialog, document, closeButton} = fixture(t)
  const content = event({title: '<img src=x onerror="alert(1)"> & review', account: "<owner>@example.test", calendar: "<b>Shared</b>", time: "Tomorrow · 00:30–01:00"})
  content.open()
  assert.equal(fields.title.textContent, '<img src=x onerror="alert(1)"> & review')
  assert.equal(fields.account.textContent, "<owner>@example.test")
  assert.equal(fields.calendar.textContent, "<b>Shared</b>")
  assert.equal(fields.time.textContent, "Tomorrow · 00:30–01:00")
  assert.equal(link.hidden, false)
  assert.equal(link.href, content.trigger.dataset.eventUrl)
  assert.equal(dialog.getAttribute("data-modal"), "")
  assert.equal(document.activeElement, closeButton)
})

for (const url of [
  "https://calendar.google.com/calendar",
  "https://calendar.google.com/calendar/event?eid=synthetic",
  "https://www.google.com/calendar",
  "https://www.google.com:443/calendar/event?eid=synthetic#details",
]) {
  test(`approved Calendar destination remains usable: ${url}`, t => {
    const {event, dialog, link} = fixture(t)
    event({url}).open()
    assert.equal(dialog.open, true)
    assert.equal(link.hidden, false)
    assert.equal(link.href, url)
  })
}

const unsafeDestinations = [
  "javascript:alert(1)", "data:text/html,<script>alert(1)</script>",
  "http://calendar.google.com/calendar/event", "https://calendar.google.com.evil.test/calendar/event",
  "https://evil.test/calendar/event?next=https://calendar.google.com", "https://calendar.google.com@evil.test/calendar/event",
  "https://name:password@calendar.google.com/calendar/event", "https://calendar.google.com:8443/calendar/event",
  "https://name@www.google.com/calendar/event", "https://www.google.com:8443/calendar/event",
  "https://calendar.google.com/event", "https://calendar.google.com/calendarity/event",
  "https://www.google.com/", "https://www.google.com/calendar.evil/event",
  "https://www.google.com/calendar/../search",
  "//calendar.google.com/calendar/event", "/calendar/event", "not a URL", "",
]

for (const url of unsafeDestinations) {
  test(`unsafe Calendar destination cannot retain a previous safe link: ${url}`, t => {
    const {event, dialog, link} = fixture(t)
    event().open()
    assert.equal(link.hidden, false)
    dialog.close()
    event({url}).open()
    assert.equal(link.hidden, true)
    assert.equal(link.getAttribute("href"), null)
  })
}

test("Escape closes only the disclosure, resumes idle observation and restores its opener", t => {
  const {event, view, document, dialog, focused, counts} = fixture(t)
  const {trigger, open} = event()
  open()
  let sceneryEscapes = 0
  view.addEventListener("keydown", () => sceneryEscapes++)
  view.emit("keydown", {key: "a"})
  assert.equal(dialog.open, true)
  sceneryEscapes = 0
  const escape = view.emit("keydown", {key: "Escape"})
  assert.equal(escape.defaultPrevented, true)
  assert.equal(escape.immediateStopped, true)
  assert.equal(sceneryEscapes, 0)
  assert.equal(dialog.open, false)
  assert.equal(dialog.getAttribute("data-modal"), null)
  assert.deepEqual(counts(), {shows: 1, closes: 1, closed: 1})
  assert.equal(document.activeElement, trigger)
  assert.deepEqual(focused.at(-1), [trigger, {preventScroll: true}])
  const next = view.emit("keydown", {key: "Escape"})
  assert.equal(next.defaultPrevented, false)
  assert.equal(sceneryEscapes, 1)
})

test("an event outside the owning agenda cannot open or replace the disclosure", t => {
  const {event, fields, dialog, counts} = fixture(t)
  event({owned: false, title: "Other account"}).open()
  assert.equal(dialog.open, false)
  assert.equal(fields.title.textContent, "")
  assert.deepEqual(counts(), {shows: 0, closes: 0, closed: 0})
})

test("closing after an agenda patch restores the heading instead of the detached trigger", t => {
  const {event, dialog, document, focused, heading} = fixture(t)
  const {trigger, open} = event()
  open()
  trigger.isConnected = false
  dialog.close()
  assert.equal(focused.some(([target]) => target === trigger), false)
  assert.equal(document.activeElement, heading)
  assert.deepEqual(focused.at(-1), [heading, {preventScroll: true}])
})

test("a connected trigger repurposed by a patch cannot receive another event's focus", t => {
  const {event, dialog, document, heading} = fixture(t)
  const {row, open} = event()
  open()
  row.id = "replacement-occurrence"
  dialog.close()
  assert.equal(document.activeElement, heading)
})

test("teardown closes the dialog and removes listeners without restoring a stale opener", t => {
  const {event, el, dialog, view, hook, focused, counts} = fixture(t)
  const {trigger, open} = event()
  open()
  hook.destroyed()
  assert.equal(dialog.open, false)
  assert.equal(dialog.getAttribute("data-modal"), null)
  assert.equal(view.listenerCount, 0)
  assert.equal(dialog.listenerCount, 0)
  assert.equal(el.listenerCount, 0)
  assert.equal(focused.some(([target]) => target === trigger), false)
  open()
  view.emit("keydown", {key: "Escape"})
  assert.equal(counts().shows, 1)
})
