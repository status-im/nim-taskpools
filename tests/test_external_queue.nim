# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/atomics,
  unittest2,
  ./utils,
  ../taskpools

# Exercises the injection queue path: tasks spawned from threads that are not
# part of the taskpool go through submitTask() and are picked up by workers via
# drainInjectionQueue().

type
  Context = tuple
    tp: Taskpool
    numTasks: int
    executed: ptr Atomic[int]

proc work(executed: ptr Atomic[int]) =
  discard executed[].fetchAdd(1, moRelaxed)

proc submitter(ctx: Context) {.thread.} =
  for i in 0 ..< ctx.numTasks:
    ctx.tp.spawn work(ctx.executed)

proc workInt(): int =
  123

proc submitterFv(ctx: Context) {.thread.} =
  var futs = newSeq[Flowvar[int]]()
  for i in 0 ..< ctx.numTasks:
    futs.add ctx.tp.spawn workInt()
  for fut in futs:
    doAssert sync(fut) == 123
    discard ctx.executed[].fetchAdd(1, moRelaxed)

suite "External threads task queue":
  setup:
    var tp = Taskpool.new(numThreads())

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "externalThreads=1; tasksPerThread=10_000":
    const
      externalThreads = 1
      tasksPerThread = 10_000
    var executed: Atomic[int]
    var threads = newSeq[Thread[Context]](externalThreads)
    for t in mitems(threads):
      createThread(t, submitter, (tp, tasksPerThread, addr executed))
    joinThreads(threads)
    tp.syncAll()
    check executed.load(moAcquire) == externalThreads * tasksPerThread

  test "externalThreads=100; tasksPerThread=10_000":
    const
      externalThreads = 100
      tasksPerThread = 10_000
    var executed: Atomic[int]
    var threads = newSeq[Thread[Context]](externalThreads)
    for t in mitems(threads):
      createThread(t, submitter, (tp, tasksPerThread, addr executed))
    joinThreads(threads)
    tp.syncAll()
    check executed.load(moAcquire) == externalThreads * tasksPerThread

  test "externalThreads=1_000; tasksPerThread=1_000":
    const
      externalThreads = 1_000
      tasksPerThread = 1_000
    var executed: Atomic[int]
    var threads = newSeq[Thread[Context]](externalThreads)
    for t in mitems(threads):
      createThread(t, submitter, (tp, tasksPerThread, addr executed))
    joinThreads(threads)
    tp.syncAll()
    check executed.load(moAcquire) == externalThreads * tasksPerThread

  test "flowvar; externalThreads=1; tasksPerThread=10_000":
    const
      externalThreads = 1
      tasksPerThread = 10_000
    var executed: Atomic[int]
    var threads = newSeq[Thread[Context]](externalThreads)
    for t in mitems(threads):
      createThread(t, submitterFv, (tp, tasksPerThread, addr executed))
    joinThreads(threads)
    tp.syncAll()
    check executed.load(moAcquire) == externalThreads * tasksPerThread

  test "flowvar; externalThreads=100; tasksPerThread=10_000":
    const
      externalThreads = 100
      tasksPerThread = 10_000
    var executed: Atomic[int]
    var threads = newSeq[Thread[Context]](externalThreads)
    for t in mitems(threads):
      createThread(t, submitterFv, (tp, tasksPerThread, addr executed))
    joinThreads(threads)
    tp.syncAll()
    check executed.load(moAcquire) == externalThreads * tasksPerThread

# submitTask only wakes a worker on the injection queue's empty->non-empty
# transition. Unlike an internal spawn (whose task's owner is live and always
# drains its own deque before parking), an injected task has no owning thread:
# its only consumers are the pool workers, which may all be parked. So the
# empty->non-empty wake is the sole guarantee that a consumer shows up. A lost
# wake there is a liveness bug (a hang), invisible to ThreadSanitizer, so we
# exercise it directly. A small pool is used so workers park quickly between
# submissions, maximizing the empty->non-empty edges.

proc pingPong(ctx: Context) {.thread.} =
  ## Submit one task and block until it completes before submitting the next.
  ## Each round takes the injection queue empty -> non-empty -> empty, so a
  ## worker must be woken from park every round; a lost wake hangs here.
  for i in 0 ..< ctx.numTasks:
    let fv = ctx.tp.spawn workInt()
    doAssert sync(fv) == 123
    discard ctx.executed[].fetchAdd(1, moRelaxed)

suite "External threads injection wake edge":
  setup:
    # Small pool so workers park quickly between injections, driving the
    # empty->non-empty transition submitTask's wake optimization hinges on.
    var tp = Taskpool.new(2)

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "ping-pong; externalThreads=1; rounds=50_000":
    # Deterministic edge: the queue is provably empty between rounds, so every
    # submission must wake a parked worker.
    const
      externalThreads = 1
      rounds = 50_000
    var executed: Atomic[int]
    var threads = newSeq[Thread[Context]](externalThreads)
    for t in mitems(threads):
      createThread(t, pingPong, (tp, rounds, addr executed))
    joinThreads(threads)
    tp.syncAll()
    check executed.load(moAcquire) == externalThreads * rounds

  test "ping-pong; externalThreads=8; rounds=20_000":
    # Concurrent submitters contend on the injection queue head while it churns
    # empty <-> non-empty under a 2-worker pool.
    const
      externalThreads = 8
      rounds = 20_000
    var executed: Atomic[int]
    var threads = newSeq[Thread[Context]](externalThreads)
    for t in mitems(threads):
      createThread(t, pingPong, (tp, rounds, addr executed))
    joinThreads(threads)
    tp.syncAll()
    check executed.load(moAcquire) == externalThreads * rounds

  test "trickle; externalThreads=8; tasksPerThread=100_000":
    # High-throughput fire-and-forget submissions onto a small pool: the queue
    # repeatedly drains to empty and is re-armed under heavy contention.
    const
      externalThreads = 8
      tasksPerThread = 100_000
    var executed: Atomic[int]
    var threads = newSeq[Thread[Context]](externalThreads)
    for t in mitems(threads):
      createThread(t, submitter, (tp, tasksPerThread, addr executed))
    joinThreads(threads)
    tp.syncAll()
    check executed.load(moAcquire) == externalThreads * tasksPerThread
