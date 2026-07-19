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

proc work2(): int =
  123

proc submitterFv(ctx: Context) {.thread.} =
  var futs = newSeq[Flowvar[int]]()
  for i in 0 ..< ctx.numTasks:
    futs.add ctx.tp.spawn work2()
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
