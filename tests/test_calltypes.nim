import ../taskpools

var tp = Taskpool.new()

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

tp.spawn(nothing())
doAssert sync(tp.spawn(retint())) == 42

tp.spawn(argint(42))

doAssert sync(tp.spawn(retargint(42))) == 42
doAssert sync(tp.spawn(arggen(42))) == 5

const x = 42

tp.spawn(argint(x))

proc argtuple(v: (int, int)) =
  discard

tp.spawn(argtuple((1, 2)))

type MoveOnly = object

proc `=copy`(a: var MoveOnly, b: MoveOnly) {.error.}

proc moveit(v: sink MoveOnly) =
  discard

proc test() =
  var v: MoveOnly
  tp.spawn(moveit(v))

test()

tp.syncAll()
tp.shutdown()
