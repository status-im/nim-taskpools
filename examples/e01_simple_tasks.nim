import ../taskpools

block: # Async without result

  proc displayInt(x: int) =
    try:
      stdout.write(x)
      stdout.write(" - SUCCESS\n")
    except IOError:
      quit 1 # can't do anything productive

  proc main() =
    echo "\nSanity check 1: Printing 123456 654321 in parallel"

    var tp = Taskpool.new(numThreads = 4)
    tp.spawn displayInt(123456)
    tp.spawn displayInt(654321)
    tp.shutdown()

  main()

block: # Async/Await

  var tp: Taskpool


  proc asyncFib(n: int): int {.gcsafe.} =
    if n < 2:
      return n

    let x = tp.spawn asyncFib(n-1)
    let y = asyncFib(n-2)

    result = sync(x) + y

  proc main2() =
    echo "\nSanity check 2: fib(20)"

    tp = Taskpool.new()
    let f = asyncFib(20)
    tp.shutdown()

    doAssert f == 6765

  main2()
