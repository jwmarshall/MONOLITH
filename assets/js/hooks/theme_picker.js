import {normalizeTheme, selectTheme, THEME_NAMES} from "../theme.js"

const ThemePicker = {
  mounted() {
    this.themeDocument = this.el.ownerDocument
    this.onThemeChange = event => {
      const input = event.target
      if (input.matches("input[type=radio][name=theme]") && input.checked) {
        selectTheme(this.themeDocument, input.value)
        this.syncTheme()
      }
    }
    this.el.addEventListener("change", this.onThemeChange)
    this.syncTheme()
  },

  syncTheme() {
    const root = this.themeDocument.documentElement
    const theme = normalizeTheme(root.dataset.theme)
    for (const input of this.el.querySelectorAll("input[type=radio][name=theme]")) {
      input.checked = input.value === theme
    }
    const status = this.el.querySelector("#theme-status")
    const name = THEME_NAMES[theme]
    if (root.dataset.themePersistence === "unavailable") {
      status.textContent = `${name} applied for this page only. Browser storage is unavailable; your choice couldn’t be saved.`
    } else if (root.dataset.themePersistence === "saved") {
      status.textContent = `${name} saved in this browser.`
    } else {
      status.textContent = `${name} is active. Choose a theme to save it in this browser.`
    }
  },

  updated() { this.syncTheme() },
  reconnected() { this.syncTheme() },
  destroyed() { this.el.removeEventListener("change", this.onThemeChange) },
}

export default ThemePicker
