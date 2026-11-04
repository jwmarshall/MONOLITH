import assert from "node:assert/strict"
import test from "node:test"
import {THEME_KEY, restoreTheme, selectTheme} from "../../assets/js/theme.js"
import ThemePicker from "../../assets/js/hooks/theme_picker.js"

const themes = ["charcoal", "earth", "sea-glass", "mist"]

function browser(saved = null) {
  const values = new Map(saved === null ? [] : [[THEME_KEY, saved]])
  const writes = []
  const window = new EventTarget()
  window.Event = Event
  window.localStorage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => { writes.push([key, value]); values.set(key, value) },
  }
  const document = {documentElement: {dataset: {}}, defaultView: window}
  return {document, window, values, writes}
}

function picker(document) {
  const inputs = themes.map(value => ({
    value,
    checked: false,
    matches: selector => selector === "input[type=radio][name=theme]",
  }))
  const status = {textContent: ""}
  const listeners = new Map()
  const el = {
    ownerDocument: document,
    querySelectorAll: () => inputs,
    querySelector: () => status,
    addEventListener: (type, callback) => listeners.set(type, callback),
    removeEventListener: (type, callback) => {
      if (listeners.get(type) === callback) listeners.delete(type)
    },
  }
  const hook = Object.assign({}, ThemePicker, {el})
  hook.mounted()
  const checked = () => inputs.filter(input => input.checked).map(input => input.value)
  const change = value => {
    for (const input of inputs) input.checked = input.value === value
    listeners.get("change")?.({target: inputs.find(input => input.value === value)})
  }
  return {hook, inputs, status, listeners, checked, change}
}

for (const theme of themes) {
  test(`${theme} applies immediately, survives reload, and restores the native picker`, () => {
    const {document, values, writes} = browser()
    restoreTheme(document)
    const first = picker(document)
    first.change(theme)
    assert.equal(document.documentElement.dataset.theme, theme)
    assert.equal(values.get(THEME_KEY), theme)
    assert.deepEqual(writes, [[THEME_KEY, theme]])
    assert.deepEqual(first.checked(), [theme])
    assert.match(first.status.textContent, /saved in this browser/)
    first.hook.destroyed()

    const remounted = picker(document)
    assert.deepEqual(remounted.checked(), [theme])
    remounted.hook.destroyed()

    const reloaded = browser(values.get(THEME_KEY))
    restoreTheme(reloaded.document)
    const restored = picker(reloaded.document)
    assert.deepEqual(restored.checked(), [theme])
    assert.deepEqual(reloaded.writes, [])
    restored.hook.destroyed()
  })
}

test("corrupt and prototype-named stored values fall back without writing storage", () => {
  for (const value of [null, "", "unknown", "EARTH", "__proto__", "constructor", "toString"]) {
    const {document, writes} = browser(value)
    restoreTheme(document)
    assert.equal(document.documentElement.dataset.theme, "sea-glass")
    assert.deepEqual(writes, [])
    const {hook, checked, status} = picker(document)
    assert.deepEqual(checked(), ["sea-glass"])
    assert.doesNotMatch(status.textContent, /saved in this browser/)
    hook.destroyed()
  }
})

test("denied storage access and reads still apply a safe palette and explain the limitation", () => {
  for (const failure of ["access", "read"]) {
    const {document, window} = browser("earth")
    if (failure === "access") {
      Object.defineProperty(window, "localStorage", {get() { throw new Error("denied") }})
    } else {
      window.localStorage.getItem = () => { throw new Error("denied") }
    }
    assert.doesNotThrow(() => restoreTheme(document))
    assert.equal(document.documentElement.dataset.theme, "sea-glass")
    const {hook, status} = picker(document)
    assert.match(status.textContent, /storage is unavailable/)
    assert.doesNotMatch(status.textContent, /saved in this browser/)
    hook.destroyed()
  }
})

test("failed persistence keeps the applied theme through patches and picker remounts", () => {
  const {document, window, values} = browser("earth")
  restoreTheme(document)
  window.localStorage.setItem = () => { throw new Error("quota exceeded") }
  const first = picker(document)
  first.change("mist")
  assert.equal(document.documentElement.dataset.theme, "mist")
  assert.equal(values.get(THEME_KEY), "earth")
  assert.deepEqual(first.checked(), ["mist"])
  assert.match(first.status.textContent, /applied for this page only/)
  assert.match(first.status.textContent, /couldn’t be saved/)

  for (const input of first.inputs) input.checked = input.value === "sea-glass"
  first.hook.updated()
  assert.deepEqual(first.checked(), ["mist"])
  first.hook.destroyed()
  const second = picker(document)
  assert.deepEqual(second.checked(), ["mist"])
  assert.match(second.status.textContent, /couldn’t be saved/)

  window.localStorage.setItem = (key, value) => values.set(key, value)
  second.change("charcoal")
  assert.equal(values.get(THEME_KEY), "charcoal")
  assert.match(second.status.textContent, /saved in this browser/)
  assert.doesNotMatch(second.status.textContent, /couldn’t be saved/)
  second.hook.destroyed()
})

test("unsupported selections do not mutate the page or storage or announce a theme", () => {
  const {document, window, writes} = browser("earth")
  restoreTheme(document)
  let announcements = 0
  window.addEventListener("lovelace:theme-change", () => announcements++)
  for (const value of ["unknown", "__proto__", "constructor", null, ["mist"], {toString: () => "mist"}]) {
    assert.equal(selectTheme(document, value), false)
  }
  assert.equal(document.documentElement.dataset.theme, "earth")
  assert.deepEqual(writes, [])
  assert.equal(announcements, 0)
  selectTheme(document, "mist")
  assert.equal(announcements, 1)
})

test("picker destruction removes the native listener and prevents later selections", () => {
  const {document, writes} = browser("earth")
  restoreTheme(document)
  const {hook, change, listeners} = picker(document)
  assert.equal(listeners.size, 1)
  hook.destroyed()
  assert.equal(listeners.size, 0)
  change("mist")
  assert.equal(document.documentElement.dataset.theme, "earth")
  assert.deepEqual(writes, [])
})
