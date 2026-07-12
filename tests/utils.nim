# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[monotimes, times, cpuinfo]

const supportsGcTypes* = defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc)

template withGranularity*(x: int32, body: untyped): untyped =
  ## Runs `body` in a loop for at least `x` microseconds.
  let start = getMonoTime()
  let stop = int64(x)
  while inMicroseconds(getMonoTime() - start) < stop:
    body

template dummyCpt*(): untyped =
  ## Dummy computation. Calculate fib(30) iteratively
  var
    fib = 0
    f2 = 0
    f1 = 1
  for i in 2 .. 30:
    fib = f1 + f2
    f2 = f1
    f1 = fib

proc numThreads*(minThreads = 2): int =
  max(minThreads, countProcessors())
