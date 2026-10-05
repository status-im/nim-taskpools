# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Test based on benchmarks/dfs
#
# Spawns a tree of `breadth` children per node, `depth` levels deep, and sums
# the leaves; each node holds a seq of Flowvars while its children run.
# The sum is breadth^depth.

{.push raises: [], gcsafe.}

import
  std/math,
  unittest2,
  ./utils,
  ../taskpools

var tp: Taskpool

proc dfs(depth, breadth: int): uint32 =
  if depth == 0:
    return 1

  var sums = newSeq[Flowvar[uint32]](breadth)
  for i in 0 ..< breadth:
    sums[i] = tp.spawn dfs(depth - 1, breadth)
  for i in 0 ..< breadth:
    result += sync(move(sums[i]))

suite "Depth First Search":
  setup:
    tp = Taskpool.new(numThreads())

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "leaf and empty tree":
    check sync(tp.spawn dfs(0, 8)) == 1
    check sync(tp.spawn dfs(1, 0)) == 0

  test "dfs(depth, breadth) == breadth^depth":
    for depth in 1 .. 4:
      for breadth in 1 .. 4:
        check sync(tp.spawn dfs(depth, breadth)) == uint32(breadth ^ depth)

  test "deep and narrow: dfs(16, 2)":
    check sync(tp.spawn dfs(16, 2)) == 65536'u32

  test "shallow and wide: dfs(2, 256)":
    check sync(tp.spawn dfs(2, 256)) == 65536'u32

  test "dfs(7, 7)":
    # ~1M tasks
    check sync(tp.spawn dfs(7, 7)) == uint32(7 ^ 7)
