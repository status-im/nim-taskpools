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

var tp: Taskpool

proc bpcConsume(usec: int32, executed: ptr Atomic[int]) =
  withGranularity(usec):
    dummyCpt()
  discard executed[].fetchAdd(1, moRelaxed)

proc bpcProduce(n, depth: int, granularity: int32, executed: ptr Atomic[int]) =
  if depth <= 0:
    return
  # A producer for the next depth, followed by n consumers
  tp.spawn bpcProduce(n, depth-1, granularity, executed)
  for i in 0 ..< n:
    tp.spawn bpcConsume(granularity, executed)
  discard executed[].fetchAdd(1, moRelaxed)

suite "Single Thread BPC":
  setup:
    tp = Taskpool.new(numThreads = 1)

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "depth=100; tasks/depth=9; granularity=1":
    const
      depth = 100
      tasksPerDepth = 9
    var executed: Atomic[int]
    bpcProduce(tasksPerDepth, depth, 1, addr executed)
    tp.syncAll()
    check executed.load(moAcquire) == (tasksPerDepth + 1) * depth

  test "depth=1000; tasks/depth=9; granularity=0":
    const
      depth = 1000
      tasksPerDepth = 9
    var executed: Atomic[int]
    bpcProduce(tasksPerDepth, depth, 0, addr executed)
    tp.syncAll()
    check executed.load(moAcquire) == (tasksPerDepth + 1) * depth

  test "depth=1_000; tasks/depth=99; granularity=1":
    const
      depth = 1_000
      tasksPerDepth = 99
    var executed: Atomic[int]
    bpcProduce(tasksPerDepth, depth, 1, addr executed)
    tp.syncAll()
    check executed.load(moAcquire) == (tasksPerDepth + 1) * depth

  test "depth=1; no consumers":
    var executed: Atomic[int]
    bpcProduce(0, 1, 0, addr executed)
    tp.syncAll()
    check executed.load(moAcquire) == 1
