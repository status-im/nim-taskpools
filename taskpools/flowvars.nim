# taskpools
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/atomics,
  ./primitives/allocs

# Tasks have an efficient design so that a single heap allocation
# is required per `spawn`.
# This greatly reduce overhead and potential memory fragmentation for long-running applications.
#
# This is done by tasks:
# - being an intrusive linked lists
# - integrating the channel to send results
#
# Flowvar is the public type created when spawning a task.
# and can be synced to receive the task result.
# Flowvars are also called future interchangeably.

type
  TaskCallback* = proc(env: pointer) {.nimcall, gcsafe, raises: [].}

  TaskNode* = ptr object
    # Linked list of tasks
    parent*: TaskNode
    # Intrusive link for the InjectionQueue Treiber stack
    injectionNext*: TaskNode
    callback*: TaskCallback
    completed: Atomic[bool] # Readiness flag for an awaiting Flowvar
    hasFuture*: bool # Ownership: if true the awaiter frees the node, otherwise the runner frees it once run.
    env*{.align: sizeof(int).}: UncheckedArray[byte]

  Flowvar*[T] = object
    ## A Flowvar is a placeholder for a future result that may be computed in parallel.
    # A Flowvar merely references the intrusive task node that carries the
    # result. It is kept a single pointer wide so it can be tested with `isNil`
    # and stored cheaply in collections.
    tn: TaskNode

# TaskNode
# ------------------------------------------------------------------------------

proc new*(T: type TaskNode, parent: TaskNode, callback: TaskCallback, envSize: int): T =
  var tn = tp_allocUnchecked(deref(T), sizeof(deref(T)) + envSize, zero = true)
  tn.parent = parent
  tn.injectionNext = nil
  tn.callback = callback
  tn.completed.store(false, moRelaxed)
  tn.hasFuture = false
  tn

proc setCompleted*(tn: TaskNode) {.inline.} =
  ## Mark a task as complete.
  tn.completed.store(true, moRelease)

# Flowvars
# ------------------------------------------------------------------------------

# proc `=copy`*[T](dst: var Flowvar[T], src: Flowvar[T]) {.error: "Futures/Flowvars cannot be copied".}
#
# Unfortunately we cannot prevent this easily as internally
# we need a copy:
# - taskpools level when returning the flowvar from the spawn macro
# - when storing flowvars in collections (seq/array)

proc newFlowVar*(T: typedesc, tn: TaskNode): Flowvar[T] {.inline.} =
  ## Create a Flowvar referencing `tn`. Must be called before the task node is
  ## scheduled so a thread running the task hands ownership to the awaiter.
  result.tn = tn
  tn.hasFuture = true

proc cleanup(fv: var Flowvar) {.inline.} =
  if not fv.tn.isNil:
    tp_free(fv.tn)
    fv.tn = nil

func isSpawned*(fv: Flowvar): bool {.inline.} =
  ## Returns true if a flowvar is spawned
  ## This may be useful for recursive algorithms that
  ## may or may not spawn a flowvar depending on a condition.
  ## This is similar to Option or Maybe types
  return not fv.tn.isNil

func isReady*[T](fv: Flowvar[T]): bool {.inline.} =
  ## Returns true if the result of a Flowvar is ready.
  ## In that case `sync` will not block.
  ## Otherwise the current will block to help on all the pending tasks
  ## until the Flowvar is ready.
  fv.tn.completed.load(moAcquire)

proc tryComplete*[T](fv: Flowvar[T], parentResult: var T): bool {.inline.} =
  ## If the task is complete, move its result into `parentResult` and return true.
  if fv.tn.completed.load(moAcquire):
    parentResult = move(cast[ptr T](fv.tn.env.addr)[])
    true
  else:
    false

proc sync*[T](fv: sink Flowvar[T]): T {.inline, gcsafe.} =
  ## Blocks the current thread until the flowvar is available and returned.
  ## Worker threads help execute pending tasks while waiting.
  ## Non-worker (external) threads busy-wait instead.
  mixin forceFuture
  forceFuture(fv, result)
  cleanup(fv)

{.pop.} # raises: []
