import {test} from "node:test"
import assert from "node:assert/strict"
import BoardDrag, {dropTargets} from "../../assets/js/hooks/board_drag.js"
const transitions = {new: ["in_progress", "rejected", "cancelled"], in_progress: ["done", "rejected", "cancelled"], done: ["verified", "in_progress"], verified: ["in_progress"], rejected: ["new"], cancelled: ["new"]}
for (const status of Object.keys(transitions)) test(`targets ${status}`, () => assert.deepEqual(dropTargets(transitions, status, false), transitions[status]))
test("blocked NEW cannot start", () => assert.deepEqual(dropTargets(transitions, "new", true), ["rejected", "cancelled"]))
function setup(fine = true) {
  const handlers = {}
  const card = {dataset: {taskId: "BOS-1", status: "new", canMove: "true", blocked: "false"}, attrs: {}, setAttribute(k,v) {this.attrs[k]=v}, removeAttribute(k) {delete this.attrs[k]}}
  const columns = ["in_progress", "verified"].map(status => ({dataset: {boardColumn: status}, attrs: {}, setAttribute(k,v) {this.attrs[k]=v}}))
  global.window = {matchMedia: () => ({matches: fine, addEventListener() {}, removeEventListener() {}})}
  const el = {dataset: {transitions: JSON.stringify(transitions)}, parentElement: {addEventListener() {}, removeEventListener() {}}, addEventListener(k,v) {handlers[k]=v}, removeEventListener() {}, querySelector() {return card}, querySelectorAll(sel) {return sel === "[data-task-id]" ? [card] : columns}}
  const pushed = []
  const hook = Object.assign(Object.create(BoardDrag), {el, pushEvent: (event, payload) => pushed.push({event, payload}), handleEvent() {}})
  hook.mounted()
  const event = node => ({target: {closest: sel => sel === "button" ? null : node}, dataTransfer: {setData() {}}, prevented: false, stopped: false, preventDefault() {this.prevented=true}, stopImmediatePropagation() {this.stopped=true}})
  return {hook, handlers, card, columns, pushed, event}
}
test("fine pointer is draggable, coarse pointer is not", () => {
  assert.equal(setup().card.attrs.draggable, "true")
  assert.equal(setup(false).card.attrs.draggable, undefined)
})
test("payload, legal dragover, aria and swallowed click; no DOM move", () => {
  const {handlers, card, columns, pushed, event} = setup()
  handlers.dragstart(event(card))
  assert.equal(columns[0].attrs["aria-dropeffect"], "move")
  const illegal = event(columns[1]); handlers.dragover(illegal); assert.equal(illegal.prevented, false)
  const legal = event(columns[0]); handlers.dragover(legal); assert.equal(legal.prevented, true)
  handlers.drop(event(columns[0]))
  assert.deepEqual(pushed, [{event: "move", payload: {id: "BOS-1", from: "new", to: "in_progress"}}])
  assert.equal(card.dataset.status, "new")
  const click=event(card); handlers.click(click); assert.equal(click.prevented, true); assert.equal(click.stopped, true)
  const next=event(card); handlers.click(next); assert.equal(next.prevented, false)
})
test("coarse dragstart and unauthorized card are rejected", () => {
  const {handlers, card, event}=setup(false)
  const drag=event(card);handlers.dragstart(drag);assert.equal(drag.prevented,true)
  const fine=setup();fine.card.dataset.canMove="false";const denied=fine.event(fine.card);fine.handlers.dragstart(denied);assert.equal(denied.prevented,true)
})
