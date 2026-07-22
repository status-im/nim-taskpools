# taskpools
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Injection queue
#
# Lock-free MPMC queue used by threads that are not currently running the
# taskpool scheduler (external threads, or a worker submitting to a foreign
# pool) to hand tasks over to the pool's workers.
#
# It is a Treiber stack:
#   - push is lock-free and multi-producer (a release CAS on the head),
#   - drain claims the whole stack in a single atomic exchange, so only one
#     worker wins per drain and no per-node synchronization is needed.
#
# The nodes are linked intrusively: the element type `T` must be a pointer type
# whose object has a public `injectionNext: T` field, used as the link. This
# avoids a separate allocation for the queue links.

{.push raises: [], gcsafe.}

import std/atomics

const tasksBetweenInjectionDrains* {.intdefine: "taskpoolsIqDrainTick".} = 61
  ## Drain the injection queue after processing at most this many local tasks,
  ## so externally submitted tasks are not starved while a worker churns through
  ## a local deque that internal spawns keep refilling. Prime to avoid resonance
  ## with regular workload sizes. Override with `-d:taskpoolsIqDrainTick:N`.

static:
  doAssert tasksBetweenInjectionDrains > 0,
    "taskpoolsIqDrainTick must be a positive integer"

type
  InjectionQueue*[T] = object
    ## Lock-free MPMC injection queue (Treiber stack).
    ## Any thread may push; any worker may drain via atomic exchange;
    ## only one worker wins the exchange per drain call.
    head{.align: 64.}: Atomic[T]

proc `=copy`[T](
    dest: var InjectionQueue[T], source: InjectionQueue[T]
  ) {.error: "An injection queue cannot be copied".}

proc init*[T](q: var InjectionQueue[T]) {.inline.} =
  ## Reset the queue to empty. Must be called before any push/drain.
  q.head.store(default(T), moRelaxed)

proc push*[T](q: var InjectionQueue[T], node: T, wasEmpty: var bool) {.inline.} =
  ## Push a node onto the queue from any thread (lock-free MPMC).
  ## `wasEmpty` is set to `true` if the queue was empty before the push.
  ##
  ## The release CAS on the head makes the plain write to the intrusive link
  ## visible to the draining worker after its acquire exchange.
  var headOld = q.head.load(moRelaxed)
  while true:
    node.injectionNext = headOld  # plain write; ordered by the release CAS below
    if q.head.compareExchange(headOld, node, moRelease, moRelaxed):
      wasEmpty = headOld.isNil
      break

iterator drain*[T](q: var InjectionQueue[T]): T {.inline.} =
  ## Atomically claim the entire queue and yield every node in it, clearing the
  ## intrusive link of each as it is handed out. Only one caller wins the
  ## exchange; concurrent callers observe an empty queue and yield nothing.
  ##
  ## The acquire exchange orders the plain reads of the intrusive links below
  ## against the release pushes that produced them.
  # The queue is empty most of the time, so probe with a cheap
  # relaxed load and take the atomic exchange only when there may be work;
  # the load(relaxed)+exchange(acquire) race is harmless.
  if not q.head.load(moRelaxed).isNil:
    var node = q.head.exchange(default(T), moAcquire)
    var next = default(T)
    while not node.isNil:
      next = node.injectionNext  # plain read; ordered by the acquire exchange above
      node.injectionNext = default(T)
      yield node
      node = next

{.pop.} # raises: [], gcsafe
