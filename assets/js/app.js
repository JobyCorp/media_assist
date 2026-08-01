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
import {hooks as colocatedHooks} from "phoenix-colocated/media_assist"
import topbar from "../vendor/topbar"

// Chat riser: click the prompt line to toggle, "/" opens and focuses the
// input from anywhere, "esc" closes. State lives in a data attribute so
// Tailwind group-data variants drive the styling.
const TerminalRiser = {
  mounted() {
    this.toggleEl = this.el.querySelector("[data-riser-toggle]")
    this.toggleEl.addEventListener("click", () => this.setOpen(!this.isOpen()))
    // The input is cleared after LiveView serializes the submit; the
    // riser stays open and focused for the next message.
    this.el.querySelector("[data-riser-form]")?.addEventListener("submit", () => {
      requestAnimationFrame(() => { const i = this.input(); if (i) i.value = "" })
    })
    this.onKeydown = e => {
      // composedPath sees through shadow DOM (e.g. the Tidewave panel);
      // a retargeted event means the key was typed in someone else's
      // surface — never ours to hijack.
      const target = e.composedPath ? e.composedPath()[0] : e.target
      const foreign = target !== e.target
      const editing = target instanceof HTMLElement &&
        (/^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) || target.isContentEditable)
      if (e.key === "/" && !editing && !foreign) {
        e.preventDefault()
        this.setOpen(true)
      } else if (e.key === "Escape" && !foreign && this.isOpen()) {
        this.setOpen(false)
      }
    }
    window.addEventListener("keydown", this.onKeydown)
    // Live navigation rebuilds the sticky riser's DOM; reopen if the
    // session had it open — visually only, without grabbing focus.
    if (window.__riserOpen) this.setOpen(true, {focus: false})
  },
  updated() {
    // Every server patch re-syncs attributes from server HTML, which
    // doesn't know about data-riser-open — re-assert the client state
    // so busy/reply updates can't slam the riser shut.
    this.applyOpenState(!!window.__riserOpen)
    // New transcript lines (or busy → idle) keep the scrollback pinned
    // to the bottom. Reclaim focus only when it is unclaimed or already
    // inside the riser — never steal it from another surface.
    if (this.isOpen()) {
      this.scrollToEnd()
      const input = this.input()
      const active = document.activeElement
      const focusIsFree = !active || active === document.body || this.el.contains(active)
      if (input && !input.disabled && focusIsFree && active !== input) input.focus()
    }
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
  },
  input() {
    return this.el.querySelector("[data-riser-input]")
  },
  isOpen() {
    return this.el.hasAttribute("data-riser-open")
  },
  scrollToEnd() {
    const scrollback = this.el.querySelector("[data-riser-scrollback]")
    if (scrollback) scrollback.scrollTop = scrollback.scrollHeight
  },
  applyOpenState(open) {
    this.el.toggleAttribute("data-riser-open", open)
    this.toggleEl.setAttribute("aria-expanded", String(open))
  },
  setOpen(open, {focus = true} = {}) {
    window.__riserOpen = open
    this.applyOpenState(open)
    if (open) {
      if (focus) this.input()?.focus()
      this.scrollToEnd()
    }
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, TerminalRiser},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#e8b84a"}, shadowColor: "rgba(0, 0, 0, .3)"})
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

