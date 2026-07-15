# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2,
  ./utils,
  ../taskpools

template dummyCpt(): untyped =
  # Dummy computation
  # Calculate fib(30) iteratively
  var
    fib = 0
    f2 = 0
    f1 = 1
  for i in 2 .. 30:
    fib = f1 + f2
    f2 = f1
    f1 = fib

proc spcConsume(usec: int32) =
  withGranularity(usec):
    dummyCpt()

suite "Single Task Producer":
  setup:
    var tp = Taskpool.new(numThreads())

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "tasks=100_000; granularity=10":
    for i in 0 ..< 100_000:
      tp.spawn spcConsume(10)

  when defined(release) or defined(danger):
    test "tasks=1_000_000; granularity=10":
      for i in 0 ..< 1_000_000:
        tp.spawn spcConsume(10)

    test "tasks=1_000_000; granularity=0":
      for i in 0 ..< 1_000_000:
        tp.spawn spcConsume(0)
