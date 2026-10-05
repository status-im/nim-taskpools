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

proc retint(): int =
  42

var gate: Atomic[bool]
var gateEntered: Atomic[bool]

proc gated(): int =
  while not gate.load(moAcquire):
    gateEntered.store(true, moRelease)
  1234

const grain = 4

proc parallelSum(lo, hi: int): int =
  ## Recursive divide-and-conquer sum over [lo, hi).
  let n = hi - lo
  if n <= 1:
    return if n == 1: lo else: 0
  let mid = lo + n div 2

  var rightFv: Flowvar[int]
  if n > grain:
    rightFv = tp.spawn parallelSum(mid, hi)

  let left = parallelSum(lo, mid)
  let right =
    if rightFv.isSpawned:
      sync(rightFv)
    else:
      parallelSum(mid, hi)
  left + right

proc seqSum(lo, hi: int): int =
  for i in lo ..< hi:
    result += i

suite "Flowvar":
  setup:
    tp = Taskpool.new(numThreads())

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "parallelSum (conditional spawn with Flowvar)":
    for n in [0, 1, 2, grain, grain + 1, 1000]:
      check parallelSum(0, n) == seqSum(0, n)

  test "isSpawned is false for a default (unspawned) Flowvar":
    var fv: Flowvar[int]
    check not fv.isSpawned

  test "isSpawned is true for a spawned Flowvar":
    let fv = tp.spawn retint()
    check fv.isSpawned
    check sync(fv) == 42

  test "isReady is false before the task completes and true after":
    gate.store(false, moRelease)
    let fv = tp.spawn gated()
    while not gateEntered.load(moAcquire):
      discard
    check not fv.isReady
    gate.store(true, moRelease)
    while not fv.isReady:
      discard
    check fv.isReady
    check sync(fv) == 1234

  test "isReady fails on non-spawned flowvar":
    var fv: Flowvar[int]
    expect AssertionDefect:
      discard isReady(fv)

  test "can only be sync'ed once":
    var fv = tp.spawn retint()
    check sync(fv) == 42
    check not compiles(var x = sync(fv))

  test "can only be sync'ed once variant":
    var fv = tp.spawn retint()
    check sync(move(fv)) == 42
    expect AssertionDefect:
      discard sync(move(fv))

  test "can only be sync'ed once variant 2":
    var x = newSeq[Flowvar[int]]()
    x.add(tp.spawn retint())
    try:
      for i in [0, 0]:
        check sync(move(x[i])) == 42
      check false
    except AssertionDefect:
      discard
