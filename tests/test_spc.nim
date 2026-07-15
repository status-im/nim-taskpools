# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Test based on benchmarks/single_task_producer
#
# A single thread produces every task; all worker threads consume them.
# This stresses the work-stealing of a hot single-producer queue.
#
# Each task bumps a counter that lives on the producer's stack, so the count can
# only be read once `syncAll` has returned and no task can be running anymore.

{.push raises: [], gcsafe.}

import
  std/atomics,
  unittest2,
  ./utils,
  ../taskpools

proc spcConsume(usec: int32, executed: ptr Atomic[int]) =
  withGranularity(usec):
    dummyCpt()
  discard executed[].fetchAdd(1, moRelaxed)

suite "Single Task Producer":
  setup:
    var tp = Taskpool.new(numThreads())

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "tasks=10_000; granularity=10":
    var executed: Atomic[int]
    for i in 0 ..< 10_000:
      tp.spawn spcConsume(10, addr executed)
    tp.syncAll()
    check executed.load(moAcquire) == 10_000

  test "tasks=100_000; granularity=0":
    var executed: Atomic[int]
    for i in 0 ..< 100_000:
      tp.spawn spcConsume(0, addr executed)
    tp.syncAll()
    check executed.load(moAcquire) == 100_000

  when defined(release) or defined(danger):
    test "tasks=1_000_000; granularity=10":
      var executed: Atomic[int]
      for i in 0 ..< 1_000_000:
        tp.spawn spcConsume(10, addr executed)
      tp.syncAll()
      check executed.load(moAcquire) == 1_000_000

  test "syncAll is repeatable":
    var executed: Atomic[int]
    for round in 0 ..< 3:
      for i in 0 ..< 1_000:
        tp.spawn spcConsume(0, addr executed)
      tp.syncAll()
      check executed.load(moAcquire) == (round + 1) * 1_000
