# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  unittest2,
  ./utils,
  ../taskpools

proc nothing() =
  discard

proc retint(): int =
  42

proc argint(v: int) =
  doAssert v == 42

proc retargint(v: int): int =
  v

proc arggen*[T](v: T): int =
  5

proc argtuple(v: (int, int)) =
  discard

proc argstr(s: string): int =
  s.len

proc argumulti(b: bool, v: array[2, int], p: ptr int) =
  discard

type MoveOnly = object

proc `=copy`(a: var MoveOnly, b: MoveOnly) {.error.}

proc moveit(v: sink MoveOnly) =
  discard

suite "Call types":
  setup:
    var tp = Taskpool.new()

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "no arguments, no result":
    tp.spawn(nothing())

  test "result, no arguments":
    check sync(tp.spawn(retint())) == 42

  test "argument, no result":
    tp.spawn(argint(42))

  test "argument and result":
    check sync(tp.spawn(retargint(42))) == 42

  test "generic argument":
    check sync(tp.spawn(arggen(42))) == 5

  test "const argument":
    const x = 42
    tp.spawn(argint(x))

  test "tuple argument":
    tp.spawn(argtuple((1, 2)))

  test "multiple arguments":
    var varray: array[2, int]
    tp.spawn(argumulti(false, varray, nil))

  test "move-only argument":
    var v: MoveOnly
    tp.spawn(moveit(v))

  when supportsGcTypes:
    test "string argument":
      var futs: seq[Flowvar[int]]
      var expected = 0
      for i in 0 ..< 64:
        let s = "item" & $i
        expected += s.len
        futs.add tp.spawn(argstr(s))
      var total = 0
      for i in 0 ..< 64:
        total += sync futs[i]
      check total == expected
