import std/atomics
import ../taskpools

# https://github.com/nim-lang/Nim/issues/26354
when defined(windows):
  import std/winlean

  proc joinThreadByRef[T](t: var Thread[T]) =
    discard waitForSingleObject(t.sys, -1'i32)
else:
  proc pthread_join[S](t: S, res: ptr pointer): cint {.importc, header: "<pthread.h>".}

  proc joinThreadByRef[T](t: var Thread[T]) =
    discard pthread_join(t.sys, nil)

block:
  var counter: Atomic[int]
  counter.store(0, moRelaxed)

  var tp = Taskpool.new(numThreads = 4)

  proc increment() {.gcsafe, raises: [].} =
    discard counter.fetchAdd(1, moRelaxed)

  proc worker() {.thread.} =
    for _ in 0 ..< 1000:
      tp.spawn(increment())

  proc main() =
    echo "\nThread worker count"

    let workers = 16
    var threads = newSeq[Thread[void]](workers)
    for t in threads.mitems():
      createThread(t, worker)
    for t in mitems threads:
      joinThreadByRef(t)
    tp.shutdown()
    let got = counter.load(moRelaxed)
    echo "Got: " & $got
    doAssert got == workers * 1000

  main()
