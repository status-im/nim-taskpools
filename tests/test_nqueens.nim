# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Test based on benchmarks/nqueens
#
# Counts the solutions of the N-queens problem: queen `j` is placed in every
# valid column and each placement is explored by a task.
#
# The benchmark passes the board around as alloca'd stack memory. Here it is a
# fixed size array instead, so the board is copied into the task and stays
# valid whatever the worker does with it. A seq would not do: `toTask` rejects
# GC-ed types under refc.

{.push raises: [], gcsafe.}

import
  unittest2,
  ./utils,
  ../taskpools

const
  maxN = 11
  solutions = [
    1,
    0,
    0,
    2,
    10, # 5x5
    4,
    40,
    92, # 8x8
    352,
    724, # 10x10
    2680,
    14200,
    73712,
    365596,
    2279184, # 15x15
    14772512
  ]

type Board = array[maxN, char]

var tp: Taskpool

func isValid(a: Board, n: int): bool =
  ## `a` holds the column of the queen of each of the first `n` rows.
  ## Returns true if none of those queens conflict.
  for i in 0 ..< n:
    let p = int(a[i])
    for j in i+1 ..< n:
      let q = int(a[j])
      if q == p or q == p - (j-i) or q == p + (j-i):
        return false
  true

proc nqueensSer(n, j: int, a: Board): int =
  if n == j:
    return 1
  var b = a
  for i in 0 ..< n:
    b[j] = char(i)
    if b.isValid(j+1):
      result += nqueensSer(n, j+1, b)

proc nqueensPar(n, j: int, a: Board): int =
  if n == j:
    return 1

  var localCounts = newSeq[Flowvar[int]](n)
  # Try each position for queen `j`
  for i in 0 ..< n:
    var b = a
    b[j] = char(i)
    if b.isValid(j+1):
      localCounts[i] = tp.spawn nqueensPar(n, j+1, b)

  for i in 0 ..< n:
    if localCounts[i].isSpawned():
      result += sync(move(localCounts[i]))

suite "N-Queens":
  setup:
    tp = Taskpool.new(numThreads())

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "solution counts for boards 1x1 .. 10x10":
    for n in 1 .. 10:
      check nqueensPar(n, 0, default(Board)) == solutions[n-1]

  test "parallel matches serial":
    for n in 1 .. 9:
      check nqueensPar(n, 0, default(Board)) == nqueensSer(n, 0, default(Board))

  test "spawned root: 11x11":
    check sync(tp.spawn nqueensPar(maxN, 0, default(Board))) == solutions[maxN-1]
