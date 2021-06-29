# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./channels_spsc_single,
  system/ansi_c,
  ./instrumentation/contracts,
  std/os

{.push gcsafe.}

type
  Flowvar*[T] = object
    ## A Flowvar is a placeholder for a future result that may be computed in parallel
    # Flowvar are optimized when containing a ptr type.
    # They take less size in memory by testing isNil
    # instead of having an extra atomic bool
    # They also use type-erasure to avoid having duplicate code
    # due to generic monomorphization.
    chan: ptr ChannelSPSCSingle

# proc `=copy`*[T](dst: var Flowvar[T], src: Flowvar[T]) {.error: "Futures/Flowvars cannot be copied".}
#
# Unfortunately we cannot prevent this easily as internally
# we need a copy:
# - nim-taskpools level when doing toTask(fnCall(args, fut)) and then returning fut. (Can be worked around with copyMem)
# - in std/tasks (need upstream workaround)

proc newFlowVar*(T: typedesc): Flowvar[T] {.inline.} =
  let size = 2 + sizeof(T) # full flag + item size + buffer
  result.chan = cast[ptr ChannelSPSCSingle](c_calloc(1, csize_t size))
  result.chan[].initialize(sizeof(T))

proc cleanup(fv: Flowvar) {.inline.} =
  # TODO: Nim v1.4+ can use "sink Flowvar"
  if not fv.chan.isNil:
    c_free(fv.chan)

func isSpawned*(fv: Flowvar): bool {.inline.} =
  ## Returns true if a flowvar is spawned
  ## This may be useful for recursive algorithms that
  ## may or may not spawn a flowvar depending on a condition.
  ## This is similar to Option or Maybe types
  return not fv.chan.isNil

proc readyWith*[T](fv: Flowvar[T], childResult: T) {.inline.} =
  ## Send the Flowvar result from the child thread processing the task
  ## to its parent thread.
  let resultSent {.used.} = fv.chan[].trySend(childResult)
  postCondition: resultSent

template tryComplete*[T](fv: Flowvar, parentResult: var T): bool =
  fv.chan[].tryRecv(parentResult)

func isReady*[T](fv: Flowvar[T]): bool {.inline.} =
  ## Returns true if the result of a Flowvar is ready.
  ## In that case `sync` will not block.
  ## Otherwise the current will block to help on all the pending tasks
  ## until the Flowvar is ready.
  not fv.chan[].isEmpty()

proc sync*[T](fv: sink Flowvar[T]): T {.inline, gcsafe.} =
  ## Blocks the current thread until the flowvar is available
  ## and returned.
  ## The thread is not idle and will complete pending tasks.
  mixin forceFuture
  forceFuture(fv, result)
  cleanup(fv)
