import {calendarDay} from "./hooks/calendar_agenda.js"

const instances = new WeakMap()
const identity = picker => ["workspaceId", "accountId", "generation"].map(key => picker.dataset[key])
const sameIdentity = (picker, expected) => identity(picker).every((value, index) => value && value === expected[index])

// Controller HTML is accepted only for the identity that initiated this lifecycle.
export function initOnboardingCalendar(doc = document) {
  instances.get(doc)?.()
  let picker = doc.querySelector("[data-onboarding-calendar]")
  if (!picker) return

  const win = doc.defaultView, expected = identity(picker)
  const abort = new AbortController()
  let timer, form, statusLink, polls = 0, request = 0, loadingRequest = false, stopped = false
  const progress = () => picker.querySelector("[data-calendar-progress]")
  const showError = () => {
    const message = picker.querySelector("[data-calendar-client-error]")
    if (message) message.hidden = false
  }
  const pending = () => {
    const message = picker.querySelector("[data-calendar-poll-stopped]")
    if (message) message.hidden = false
    const loading = picker.querySelector("[data-calendar-loading-message]")
    if (loading) loading.hidden = true
  }
  const unbind = () => {
    form?.removeEventListener("submit", handleLoad)
    statusLink?.removeEventListener("click", handleStatus)
  }
  const stop = () => {
    stopped = true
    request++
    win.clearTimeout(timer)
    abort.abort()
    unbind()
    win.removeEventListener("pagehide", stop)
  }
  const dispose = () => {
    stop()
    win.removeEventListener("pageshow", resume)
  }
  const resume = event => { if (event.persisted) initOnboardingCalendar(doc) }
  instances.set(doc, dispose)
  win.addEventListener("pagehide", stop, {once: true})
  win.addEventListener("pageshow", resume)

  const current = token => !stopped && token === request &&
    doc.querySelector("[data-onboarding-calendar]") === picker && sameIdentity(picker, expected)
  const rejectIdentity = () => {
    stop()
    for (const control of picker.querySelectorAll("fieldset, button")) control.disabled = true
    showError()
  }
  const readPage = async (url, options, token, signal) => {
    const response = await win.fetch(url, {
      credentials: "same-origin", cache: "no-store", ...options, signal,
    })
    if (signal.aborted || !current(token)) return null
    if (response.redirected) {
      const destination = new URL(response.url, win.location.href)
      if (destination.origin !== win.location.origin) throw new Error("Unexpected Calendar redirect")
      if (/^\/(unlock|setup|onboarding(?:\/[^/]+)?)$/.test(destination.pathname) &&
          destination.pathname !== win.location.pathname) {
        stop()
        win.location.assign(destination.href)
        return null
      }
    }
    if (!response.ok) throw new Error("Calendar setup is unavailable")
    const html = await response.text()
    if (signal.aborted || !current(token)) return null
    const parsed = new win.DOMParser().parseFromString(html, "text/html")
    const next = parsed.querySelector("[data-onboarding-calendar]")
    if (!next || !sameIdentity(next, expected)) {
      rejectIdentity()
      return null
    }
    return next
  }
  const read = async (url, options, token) => {
    const controller = new AbortController()
    let deadline, cancel
    const canceled = new Promise(resolve => {
      cancel = () => { controller.abort(); resolve(null) }
      abort.signal.addEventListener("abort", cancel, {once: true})
    })
    const timeout = new Promise((_, reject) => {
      deadline = win.setTimeout(() => {
        controller.abort()
        reject(new Error("Calendar setup request timed out"))
      }, 10000)
    })
    try {
      return await Promise.race([readPage(url, options, token, controller.signal), timeout, canceled])
    } finally {
      win.clearTimeout(deadline)
      abort.signal.removeEventListener("abort", cancel)
    }
  }
  const replace = next => {
    // Refresh may finish after the owner edited existing choices. Keep those edits.
    const choices = new Map([...picker.querySelectorAll('input[type="checkbox"]')]
      .map(input => [input.value, input.checked]))
    const active = picker.contains(doc.activeElement) ? doc.activeElement : null
    const focusId = active?.id
    const focusChoice = active?.type === "checkbox" ? active.value : null
    unbind()
    picker.replaceWith(doc.importNode(next, true))
    picker = doc.querySelector("[data-onboarding-calendar]")
    for (const input of picker.querySelectorAll('input[type="checkbox"]')) {
      if (choices.has(input.value)) input.checked = choices.get(input.value)
    }
    bind()
    if (active) {
      const target = focusId ? doc.getElementById(focusId) :
        [...picker.querySelectorAll('input[type="checkbox"]')].find(input => input.value === focusChoice)
      const focus = !target || target.disabled || target.closest("fieldset")?.disabled ? picker.querySelector("h2") : target
      focus?.focus({preventScroll: true})
    }
  }
  const poll = () => {
    if (stopped || progress()?.dataset.loading !== "true") return
    if (polls >= 20) { pending(); return }
    timer = win.setTimeout(async () => {
      const token = ++request
      try {
        polls++
        const next = await read(statusLink.href, {}, token)
        if (!next) return
        if (next.querySelector("[data-calendar-progress]")?.dataset.loading !== "true") replace(next)
        poll()
      } catch (error) {
        if (current(token) && error.name !== "AbortError") { pending(); showError() }
      }
    }, 1500)
  }
  const load = async (form, manual = true) => {
    if (stopped || loadingRequest) return
    loadingRequest = true
    win.clearTimeout(timer)
    const token = ++request
    polls = 0
    const fieldset = picker.querySelector("fieldset"), wasDisabled = fieldset?.disabled
    if (fieldset) fieldset.disabled = true
    const button = form.querySelector("button")
    button.setAttribute("aria-disabled", "true")
    for (const [key, value] of Object.entries(calendarDay())) form.elements[key].value = value
    const body = new URLSearchParams(new win.FormData(form))
    body.set("operation", manual ? "refresh_calendars" : "load_calendars")
    try {
      const next = await read(form.action, {
        method: "POST", body,
      }, token)
      if (!next) return
      replace(next)
      poll()
    } catch (error) {
      if (current(token) && error.name !== "AbortError") {
        showError()
        button.removeAttribute("aria-disabled")
        if (fieldset) fieldset.disabled = wasDisabled
      }
    } finally {
      loadingRequest = false
    }
  }
  const handleLoad = event => { event.preventDefault(); load(event.currentTarget) }
  const handleStatus = async event => {
    event.preventDefault()
    if (stopped || loadingRequest) return
    loadingRequest = true
    win.clearTimeout(timer)
    const token = ++request
    try {
      const next = await read(statusLink.href, {}, token)
      if (!next) return
      if (next.querySelector("[data-calendar-progress]")?.dataset.loading === "true") pending()
      else replace(next)
    } catch (error) {
      if (current(token) && error.name !== "AbortError") { pending(); showError() }
    } finally {
      loadingRequest = false
    }
  }
  const bind = () => {
    form = picker.querySelector("[data-calendar-load]")
    statusLink = picker.querySelector("[data-calendar-status]")
    form?.addEventListener("submit", handleLoad)
    statusLink?.addEventListener("click", handleStatus)
  }
  bind()
  if (progress()?.dataset.statusOnly === "true") {
    if (progress()?.dataset.loading === "true") pending()
  } else if (progress()?.dataset.autoload === "true" && form) load(form, false)
  else poll()
}
