export const THEME_KEY = "monolith:theme"
export const THEME_NAMES = Object.freeze({
  charcoal: "Charcoal",
  earth: "Earth",
  "sea-glass": "Sea Glass",
  mist: "Mist",
})

export function validTheme(value) {
  return typeof value === "string" && Object.hasOwn(THEME_NAMES, value)
}

export function normalizeTheme(value) {
  return validTheme(value) ? value : "sea-glass"
}

function announceTheme(document) {
  const window = document.defaultView
  window.dispatchEvent(new window.Event("monolith:theme-change"))
}

// Called by the synchronous, self-hosted head entry before styles are loaded.
export function restoreTheme(document) {
  const root = document.documentElement
  try {
    const saved = document.defaultView.localStorage.getItem(THEME_KEY)
    root.dataset.theme = normalizeTheme(saved)
    root.dataset.themePersistence = validTheme(saved) ? "saved" : "default"
  } catch {
    root.dataset.theme = normalizeTheme(null)
    root.dataset.themePersistence = "unavailable"
  }
  announceTheme(document)
}

export function selectTheme(document, value) {
  if (!validTheme(value)) return false

  const root = document.documentElement
  root.dataset.theme = value
  try {
    document.defaultView.localStorage.setItem(THEME_KEY, value)
    root.dataset.themePersistence = "saved"
  } catch {
    root.dataset.themePersistence = "unavailable"
  }
  announceTheme(document)
  return true
}
