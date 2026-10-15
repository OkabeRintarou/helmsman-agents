export function dropTargets(transitions, status, blocked) {
  return (transitions[status] || []).filter(to => !(status === "new" && to === "in_progress" && blocked))
}

export default {
  mounted() {
    this.fine = window.matchMedia("(pointer: fine)")
    this.listeners = []
    this.listen = (name, fn, capture = false) => {
      this.el.addEventListener(name, fn, capture)
      this.listeners.push([name, fn, capture])
    }
    this.refresh = () => {
      this.transitions = JSON.parse(this.el.dataset.transitions || "{}")
      this.el.querySelectorAll("[data-task-id]").forEach(card => {
        if (this.fine.matches && card.dataset.canMove === "true") card.setAttribute("draggable", "true")
        else card.removeAttribute("draggable")
      })
    }
    this.pointerChanged = () => this.refresh()
    this.fine.addEventListener("change", this.pointerChanged)
    this.listen("dragstart", event => {
      const card = event.target.closest("[data-task-id]")
      if (!card || !this.fine.matches || card.dataset.canMove !== "true" || event.target.closest("button")) {
        event.preventDefault()
        return
      }
      this.drag = {id: card.dataset.taskId, from: card.dataset.status}
      this.targets = dropTargets(this.transitions, this.drag.from, card.dataset.blocked === "true")
      event.dataTransfer.effectAllowed = "move"
      event.dataTransfer.setData("text/plain", this.drag.id)
      this.el.querySelectorAll("[data-board-column]").forEach(column => {
        column.setAttribute("aria-dropeffect", this.targets.includes(column.dataset.boardColumn) ? "move" : "none")
      })
    })
    this.listen("dragover", event => {
      const column = event.target.closest("[data-board-column]")
      if (this.drag && column && this.targets.includes(column.dataset.boardColumn)) {
        event.preventDefault()
        event.dataTransfer.dropEffect = "move"
      }
    })
    this.listen("drop", event => {
      const column = event.target.closest("[data-board-column]")
      if (this.drag && column && this.targets.includes(column.dataset.boardColumn)) {
        event.preventDefault()
        const card = this.el.querySelector(`[data-task-id="${this.drag.id}"]`)
        card?.setAttribute("data-board-pending", "true")
        this.pushEvent("move", {...this.drag, to: column.dataset.boardColumn}, () => card?.removeAttribute("data-board-pending"))
      }
      this.finish()
    })
    this.listen("dragend", () => this.finish())
    this.listen("click", event => {
      if (this.swallowUntil && Date.now() < this.swallowUntil) {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.swallowUntil = 0
      }
    }, true)
    this.handleEvent("board-focus", ({id}) => {
      // LiveView applies the stream patch before this callback.
      requestAnimationFrame(() => document.getElementById(id)?.focus({preventScroll: true}))
    })
    this.anchorListener = event => {
      const anchor = event.target.closest("[data-board-anchor]")
      if (anchor) {
        event.preventDefault()
        document.getElementById(`board-column-${anchor.dataset.boardAnchor}`)?.scrollIntoView({behavior: "smooth", block: "nearest", inline: "start"})
      }
    }
    this.el.parentElement.addEventListener("click", this.anchorListener)
    this.refresh()
  },
  updated() { this.refresh() },
  finish() {
    if (this.drag) this.swallowUntil = Date.now() + 400
    this.drag = null
    this.targets = []
    this.el.querySelectorAll("[data-board-column]").forEach(column => column.setAttribute("aria-dropeffect", "none"))
  },
  destroyed() {
    this.listeners.forEach(([name, fn, capture]) => this.el.removeEventListener(name, fn, capture))
    this.fine.removeEventListener("change", this.pointerChanged)
    this.el.parentElement.removeEventListener("click", this.anchorListener)
  },
}
