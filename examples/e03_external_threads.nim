import std/atomics
import ../taskpools

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
    for t in threads:
      joinThread(t)
    tp.shutdown()
    let got = counter.load(moRelaxed)
    echo "Got: " & $got
    doAssert got == workers * 1000

  main()
