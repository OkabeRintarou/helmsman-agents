// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/helmsman"
import topbar from "../vendor/topbar"
import Hotkeys from "./hooks/hotkeys"
import Editor from "./hooks/editor"

const RECENT_TASKS = "hm:recent-tasks"
const recentTasks = () => {
  try { return JSON.parse(localStorage.getItem(RECENT_TASKS)) || [] } catch (_e) { return [] }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({_csrf_token: csrfToken, recent_tasks: recentTasks()}),
  hooks: {...colocatedHooks, Hotkeys, Editor},
})

// Focus return for modal layers (design D5c): remember the element focused when a layer
// opens and focus it again when that layer closes.
const focusStack = []
window.addEventListener("hm:overlay-open", ({target}) => {
  const el = document.activeElement
  if (el && el !== document.body && !target.contains(el)) focusStack.push({layer: target.id, el, id: el.id})
})
window.addEventListener("hm:overlay-close", ({target}) => {
  const index = focusStack.findLastIndex(entry => entry.layer === target.id)
  if (index === -1) return
  const [{el, id}] = focusStack.splice(index, 1)
  const restore = el.isConnected ? el : id && document.getElementById(id)
  restore?.focus({preventScroll: true})
})
window.addEventListener("hm:clear-input", ({target}) => { target.value = "" })

// Buttons disabled with a reason stay focusable (aria-disabled) but must not act: cancel
// clicks (also the synthetic click of implicit Enter submission) and their submits.
const disabledButton = el => el?.closest?.("[data-hm-disabled]")
window.addEventListener("click", e => {
  if (disabledButton(e.target)) { e.preventDefault(); e.stopImmediatePropagation() }
}, true)
window.addEventListener("submit", e => {
  if (disabledButton(e.submitter)) { e.preventDefault(); e.stopImmediatePropagation() }
}, true)

// Sidebar collapse (lg and up); the root layout applies the stored state before paint.
window.addEventListener("hm:toggle-sidebar", () => {
  const html = document.documentElement
  const collapsed = html.getAttribute("data-sidebar") !== "collapsed"
  collapsed ? html.setAttribute("data-sidebar", "collapsed") : html.removeAttribute("data-sidebar")
  localStorage.setItem("hm:sidebar", collapsed ? "collapsed" : "expanded")
})

// Task pages push this on mount; the command palette lists these when empty.
window.addEventListener("phx:hm:visit-task", ({detail}) => {
  if (!detail?.ident) return
  const list = [detail.ident, ...recentTasks().filter(i => i !== detail.ident)].slice(0, 10)
  localStorage.setItem(RECENT_TASKS, JSON.stringify(list))
})

// The shell pushes this when the current workspace is renamed: the title suffix is part
// of the static root layout (<.live_title suffix>), so update it here.
window.addEventListener("phx:hm:title-suffix", ({detail}) => {
  const title = document.querySelector("title")
  if (!title || typeof detail?.suffix !== "string") return
  const old = title.dataset.suffix || ""
  title.dataset.suffix = detail.suffix
  if (document.title.endsWith(old)) document.title = document.title.slice(0, document.title.length - old.length) + detail.suffix
})

// Command palette actions that run on the client.
window.addEventListener("phx:hm:palette-action", ({detail}) => {
  const dialog = document.getElementById("command-palette-dialog")
  if (dialog?.getAttribute("data-cancel")) liveSocket.execJS(dialog, dialog.getAttribute("data-cancel"))
  if (detail.action === "new-task") document.querySelector("[data-hm-new-task]")?.click()
  if (detail.action === "theme") window.dispatchEvent(new CustomEvent("phx:set-theme", {detail}))
  if (detail.action === "copy-link") navigator.clipboard?.writeText(window.location.href)
})

// Submitting buttons: aria-busy while the submit is pending; afterwards move focus to
// the first invalid field of the form.
window.addEventListener("phx:push", ({detail}) => {
  if (detail.eventType !== "submit") return
  const buttons = detail.loadingElements.filter(el => el.hasAttribute?.("data-hm-busy"))
  buttons.forEach(b => b.setAttribute("aria-busy", "true"))
  const form = detail.loadingElements.find(el => el.tagName === "FORM")
  detail.loadingComplete?.then(() => {
    buttons.forEach(b => b.removeAttribute("aria-busy"))
    requestAnimationFrame(() => form?.querySelector("[aria-invalid=true]")?.focus())
  })
})

// Info flashes fade out by CSS; clear them on the server afterwards so a repeated
// message is rendered (and animated) again.
window.addEventListener("animationend", ({target, animationName}) => {
  const clear = animationName === "hm-flash-out" && target.getAttribute?.("data-hm-flash-clear")
  if (clear) liveSocket.execJS(target, clear)
})

// Show progress bar on live navigation and form submits
const brand = getComputedStyle(document.documentElement).getPropertyValue("--hm-brand").trim()
topbar.config({barColors: {0: brand || "currentColor"}, shadowBlur: 0})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

