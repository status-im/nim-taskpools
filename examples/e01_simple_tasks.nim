import ../taskpools/taskpools

block: # Async without result

  proc display_int(x: int) =
    stdout.write(x)
    stdout.write(" - SUCCESS\n")

  proc main() =
    echo "\nSanity check 1: Printing 123456 654321 in parallel"

    var tp = Taskpool.new(numThreads = 4)
    tp.spawn display_int(123456)
    tp.spawn display_int(654321)
    tp.shutdown()

  main()

block: # Async/Await

  var tp: Taskpool


  proc async_fib(n: int): int =
    if n < 2:
      return n

    let x = tp.spawn async_fib(n-1)
    let y = async_fib(n-2)

    result = sync(x) + y

  proc main2() =
    echo "\nSanity check 2: fib(20)"

    tp = Taskpool.new()
    let f = async_fib(20)
    tp.shutdown()

    doAssert f == 6765

  main2()
