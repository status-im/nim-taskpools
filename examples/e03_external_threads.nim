import std/atomics
import ../taskpools

block:
  var counter: Atomic[int]
  counter.store(0, moRelaxed)

  var tp = Taskpool.new(numThreads = 4)

  proc increment() {.gcsafe, raises: [].} =
    discard counter.fetchAdd(1, moRelaxed)

  # dummy int param to workaround:
  # https://github.com/nim-lang/Nim/issues/26354
  proc worker(_: int) {.thread.} =
    for _ in 0 ..< 1000:
      tp.spawn(increment())

  proc main() =
    echo "\nThread worker count"

    let workers = 16
    var threads = newSeq[Thread[int]](workers)
    for t in threads.mitems():
      createThread(t, worker, 42)
    for t in mitems threads:
      joinThread(t)
    tp.shutdown()
    let got = counter.load(moRelaxed)
    echo "Got: " & $got
    doAssert got == workers * 1000

  main()
