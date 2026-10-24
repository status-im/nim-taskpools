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

proc argvoid(v: int): void =
  doAssert v == 42

proc retargint(v: int): int =
  v

proc retauto(v: int): auto =
  v

proc arggen[T](v: T): int =
  5

proc retgen[T](v: T): T =
  v

proc argtuple(v: (int, int)) =
  discard

proc argstr(s: string): int =
  s.len

proc retstr(x: int): string =
  $x

proc argseq(s: seq[int]): int =
  s.len

proc retseq(s: seq[int]): seq[int] =
  s

proc retref(): ref string =
  var ret = new string
  ret[] = "hello"
  ret

proc argumulti(b: bool, v: array[2, int], p: ptr int) =
  discard

proc argproc(f: proc(v: int): int {.nimcall, gcsafe, raises: [].}): int =
  f(42)

let procvar: proc(v: int): int {.nimcall, gcsafe, raises: [].} = retargint

var
  mutableprocvar: proc(v: int): int {.nimcall, gcsafe, raises: [].} = retargint
  threadprocvar {.threadvar.}: proc(v: int): int {.nimcall, gcsafe, raises: [].}

type MoveOnly = object

proc `=copy`(a: var MoveOnly, b: MoveOnly) {.error.}

proc moveit(v: sink MoveOnly) =
  discard

type CaseObject[T] = object
  case kind: bool
  of false:
    discard
  of true:
    case nested: bool
    of false:
      p: ptr T
    of true:
      value: T

func argcase(v: CaseObject[int]): int =
  v.value

func retcase(v: int): CaseObject[int] =
  CaseObject[int](kind: true, nested: true, value: v)

func argcasestr(v: CaseObject[string]): int =
  v.value.len

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

  test "argument, void result":
    tp.spawn(argvoid(42))

  test "argument and result":
    check sync(tp.spawn(retargint(42))) == 42

  test "argument and auto result":
    check sync(tp.spawn(retauto(42))) == 42

  test "generic argument":
    check sync(tp.spawn(arggen(42))) == 5

  test "generic result":
    check sync(tp.spawn(retgen(42))) == 42

  test "const argument":
    const x = 42
    tp.spawn(argint(x))

  test "tuple argument":
    tp.spawn(argtuple((1, 2)))

  test "multiple arguments":
    var varray: array[2, int]
    tp.spawn(argumulti(false, varray, nil))

  test "proc argument":
    check sync(tp.spawn(argproc(retargint))) == 42

  test "proc variable":
    check sync(tp.spawn(procvar(42))) == 42

  test "mutable proc variable":
    check not compiles(tp.spawn(mutableprocvar(42)))

  test "threadvar proc variable":
    check not compiles(tp.spawn(threadprocvar(42)))

  test "move-only argument":
    var v: MoveOnly
    tp.spawn(moveit(v))

  test "case object argument":
    var v = CaseObject[int](kind: true, nested: true, value: 42)
    check sync(tp.spawn(argcase(v))) == 42

  test "case object return":
    check sync(tp.spawn(retcase(42))).value == 42

  when not supportsGcTypes:
    test "string argument":
      var s = "item"
      check not compiles(tp.spawn(argstr(s)))

    #test "string return":
    #  check not compiles(tp.spawn(retstr(42)))

    #test "ref return":
    #  check not compiles(tp.spawn(retref()))

    test "case object string argument":
      var v = CaseObject[string](kind: true, nested: true, value: "item")
      check not compiles(tp.spawn(argcasestr(v)))

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

    test "string argument variant":
      var s = "foo"
      let fv = tp.spawn argstr(s)
      # force run in another thread
      while not isReady(fv):
        discard
      check sync(fv) == 3

    test "string return":
      var futs: seq[Flowvar[string]]
      for i in 0 ..< 64:
        futs.add tp.spawn(retstr(i))
      for i in 0 ..< 64:
        check sync(futs[i]) == $i

    test "string return variant":
      let fv = tp.spawn retstr(42)
      while not isReady(fv):
        discard
      check sync(fv) == "42"

    test "seq argument":
      var futs: seq[Flowvar[int]]
      var expected = 0
      for i in 0 ..< 64:
        let s = @[i]
        expected += s.len
        futs.add tp.spawn(argseq(s))
      var total = 0
      for i in 0 ..< 64:
        total += sync futs[i]
      check total == expected

    test "seq argument variant":
      var s = @[1, 2, 3]
      let fv = tp.spawn argseq(s)
      while not isReady(fv):
        discard
      check sync(fv) == 3

    test "seq return":
      var futs: seq[Flowvar[seq[int]]]
      for i in 0 ..< 64:
        let s = @[i]
        futs.add tp.spawn(retseq(s))
      for i in 0 ..< 64:
        check sync(futs[i]) == @[i]

    test "seq return variant":
      var s = @[1, 2, 3]
      let fv = tp.spawn retseq(s)
      while not isReady(fv):
        discard
      check sync(fv) == @[1, 2, 3]

    test "ref return":
      var futs: seq[Flowvar[ref string]]
      for i in 0 ..< 64:
        futs.add tp.spawn(retref())
      for i in 0 ..< 64:
        check sync(futs[i])[] == "hello"

    test "ref return variant":
      let fv = tp.spawn retref()
      while not isReady(fv):
        discard
      check sync(fv)[] == "hello"

    test "case object string argument":
      var v = CaseObject[string](kind: true, nested: true, value: "item")
      check sync(tp.spawn(argcasestr(v))) == 4
