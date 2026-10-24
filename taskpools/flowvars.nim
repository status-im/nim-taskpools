# taskpools
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[atomics, isolation],
  ./primitives/[allocs, futexes]

const sharedHeap* = defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc)

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
  TaskState = object
    ## This state allows synchronization between:
    ## - a waiter that may sleep if no work and task is incomplete
    ## - a runner, the task creator or a thief, that completes the task
    ## - a waiter that frees the task memory
    ##
    ## Supports up to 2¹⁵ = 32768 threads
    completed: Futex
    synchro: Atomic[uint32]
    # type synchro = object
    #   canBeFreed {.bitsize:  1.}: uint32 - Transfer ownership from runner to waiter
    #   pad        {.bitsize:  1.}: uint32
    #   waiterID   {.bitsize: 15.}: uint32 - ID of the waiter blocked on the task completion.
    #                                        ID is always 0 for external threads.
    #   unused     {.bitsize: 15.}: uint32 - Leapfrogging stores the thief ID here.

  TaskCallback* = proc(env: pointer) {.nimcall, gcsafe, raises: [].}

  TaskNode* = ptr object
    # Linked list of tasks
    parent*: TaskNode
    # Intrusive link for the InjectionQueue Treiber stack
    injectionNext*: TaskNode
    callback*: TaskCallback
    state: TaskState
    hasFuture*: bool # Ownership: if true the awaiter frees the node, otherwise the runner frees it once run.
    env*{.align: sizeof(int).}: UncheckedArray[byte]

  Flowvar*[T] = object
    ## A Flowvar is a placeholder for a future result that may be computed in parallel.
    # A Flowvar merely references the intrusive task node that carries the
    # result. It is kept a single pointer wide so it can be tested with `isNil`
    # and stored cheaply in collections.
    tn: TaskNode

# Task state
# ------------------------------------------------------------------------------

# Tasks have the following lifecycle:
# - a task creator schedules a task on its queue
# - a task runner, the creator or a thief, runs the task
# - once the task is finished:
#   - if the task has no future, the runner frees the task
#   - if the task has a future,
#     - the runner can immediately pick up new work
#     - the awaiting thread reads the result and frees the task
#     - the awaiting thread may have run out of work and parked on the task,
#       in which case it needs to be woken up
#
# There is a delicate dance as we need to prevent 2 issues:
#
# 1. A deadlock:       if the waiter is never woken up after the runner completes the task
# 2. A use-after-free: if the runner touches the task after the waiter freed it
#
# To solve 1, the runner sets the `completed` flag, then checks again whether a
#             waiter registered in the meantime, and wakes it if so.
# To solve 2, we cannot require the runner to stop touching the task once it is
#             completed, as solving 1 forces it to read `synchro` afterwards.
#             Instead the runner hands the task over with `canBeFreed`, which the
#             waiter spins on before deallocating.

const # `synchro` bitfield
  kCanBeFreedShift = 31
  kCanBeFreed      = 1'u32 shl kCanBeFreedShift

  kWaiterShift     = 15
  kWaiterMask      = ((1'u32 shl kWaiterShift) - 1) shl kWaiterShift
  SentinelWaiter   = kWaiterMask
    ## No thread is parked on the task
  maxWaiterID      = int32(SentinelWaiter shr kWaiterShift) - 1
    ## Highest ID a waiter can have, one below the sentinel

proc initSynchroState(tn: TaskNode) {.inline.} =
  tn.state.completed.initialize()
  tn.state.synchro.store(SentinelWaiter, moRelaxed)

proc teardownSynchroState(tn: TaskNode) {.inline.} =
  tn.state.completed.teardown()

# Flowvar synchronization
# ------------------------------------------------------------------------------

proc isGcReady*(tn: TaskNode): bool {.inline.} =
  ## Check whether the runner is done accessing a task it handed to the waiter.
  (tn.state.synchro.load(moAcquire) and kCanBeFreed) != 0

proc setGcReady*(tn: TaskNode) {.inline.} =
  ## The runner transfers full ownership of the task to the waiter.
  ## The task must not be accessed by the runner afterwards.
  discard tn.state.synchro.fetchAdd(kCanBeFreed, moRelease)

proc isCompleted*(tn: TaskNode): bool {.inline.} =
  ## Check task completion.
  tn.state.completed.load(moAcquire) != 0

proc setCompleted*(tn: TaskNode) {.inline.} =
  ## Mark a task as complete and wake the awaiting thread if it parked.
  tn.state.completed.store(1, moRelease)
  fence(moSequentiallyConsistent)
  let waiter = tn.state.synchro.load(moRelaxed)
  if (waiter and kWaiterMask) != SentinelWaiter:
    tn.state.completed.wake()

proc sleepUntilComplete*(tn: TaskNode, waiterID: int32) {.inline.} =
  ## Park the current thread until the task is completed by the thread running it.
  assert 0 <= waiterID and waiterID <= maxWaiterID
  let waiter = (cast[uint32](waiterID) shl kWaiterShift) - SentinelWaiter
  discard tn.state.synchro.fetchAdd(waiter, moRelaxed)
  fence(moAcquire)
  while tn.state.completed.load(moRelaxed) == 0:
    tn.state.completed.wait(0)

# TaskNode
# ------------------------------------------------------------------------------

proc new*(T: type TaskNode, parent: TaskNode, callback: TaskCallback, envSize: int): T =
  var tn = tp_allocUnchecked(deref(T), sizeof(deref(T)) + envSize, zero = true)
  tn.parent = parent
  tn.injectionNext = nil
  tn.callback = callback
  tn.initSynchroState()
  tn.hasFuture = false
  tn

proc free*(tn: var TaskNode) {.inline.} =
  ## Release a task node. The caller must own it, see "Task state".
  doAssert not tn.isNil
  tn.teardownSynchroState()
  tp_free(tn)
  tn = nil

# Flowvars
# ------------------------------------------------------------------------------

proc `=copy`*[T](dst: var Flowvar[T], src: Flowvar[T]) {.error: "Futures/Flowvars cannot be copied".}

when (NimMajor, NimMinor) >= (2, 2):
  proc `=wasMoved`*[T](obj: var Flowvar[T]) {.inline.} =
    obj.tn = nil

proc newFlowVar*(T: typedesc, tn: TaskNode): Flowvar[T] {.inline.} =
  ## Create a Flowvar referencing `tn`. Must be called before the task node is
  ## scheduled so a thread running the task hands ownership to the awaiter.
  result.tn = tn
  tn.hasFuture = true

func isSpawned*(fv: Flowvar): bool {.inline.} =
  ## Returns true if a flowvar is spawned
  ## This may be useful for recursive algorithms that
  ## may or may not spawn a flowvar depending on a condition.
  ## This is similar to Option or Maybe types
  not fv.tn.isNil

func isReady*[T](fv: Flowvar[T]): bool {.inline.} =
  ## Returns true if the result of a Flowvar is ready.
  ## In that case `sync` will not block.
  ## Otherwise the current will block to help on all the pending tasks
  ## until the Flowvar is ready. The Flowvar must have been spawned.
  doAssert isSpawned(fv)
  fv.tn.isCompleted()

proc tryComplete*[T](fv: Flowvar[T], parentResult: var T): bool {.inline.} =
  ## If the task is complete, move its result into `parentResult` and return true.
  doAssert isSpawned(fv)
  if fv.tn.isCompleted():
    when sharedHeap:
      parentResult = extract(cast[ptr Isolated[T]](fv.tn.env.addr)[])
    else:
      parentResult = move(cast[ptr T](fv.tn.env.addr)[])
    true
  else:
    false

proc sleepUntilReady*(fv: Flowvar, waiterID: int32) {.inline.} =
  ## Park the current thread until the task backing the flowvar completes.
  ## Only park when there is no other work to do: the thread is only woken
  ## by the completion of that very task.
  doAssert isSpawned(fv)
  fv.tn.sleepUntilComplete(waiterID)

proc cleanup*(fv: var Flowvar) {.inline.} =
  doAssert isSpawned(fv)
  while not fv.tn.isGcReady():
    cpuRelax()
  fv.tn.free()
  fv.tn = nil

{.pop.} # raises: []
