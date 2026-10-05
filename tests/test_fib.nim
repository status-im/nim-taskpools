# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Test based on benchmarks/fibonacci
#
# The naive recursive fibonacci: a task spawns a task per recursion and syncs
# on it, i.e. worker threads block on children they may have to run themselves.

{.push raises: [], gcsafe.}

import
  unittest2,
  ./utils,
  ../taskpools

var tp: Taskpool

proc fib(n: int): int =
  if n < 2:
    return n
  let x = tp.spawn fib(n-1)
  let y = fib(n-2)
  sync(x) + y

proc fibSeq(n: int): int =
  var
    f2 = 0
    f1 = 1
  if n < 2:
    return n
  for i in 2 .. n:
    result = f1 + f2
    f2 = f1
    f1 = result

suite "Fibonacci":
  setup:
    tp = Taskpool.new(numThreads())

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "fib(n) for n in 0 .. 20":
    for n in 0 .. 20:
      check fib(n) == fibSeq(n)

  test "base cases spawn no work":
    check sync(tp.spawn fib(0)) == 0
    check sync(tp.spawn fib(1)) == 1

  test "fib(24) from a task":
    # The root itself is a task, so every sync happens on a worker thread
    check sync(tp.spawn fib(24)) == 46368

  test "concurrent independent trees":
    var futs: array[8, Flowvar[int]]
    for i in 0 ..< futs.len:
      futs[i] = tp.spawn fib(20)
    for i in 0 ..< futs.len:
      check sync(move(futs[i])) == 6765
