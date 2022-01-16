# Taskpools

This implements a lightweight, energy-efficient, easily auditable multithreaded taskpools.

This taskpools will be used in a highly security-sensitive blockchain application
targeted at resource-restricted devices hence desirable properties are:

- Ease of auditing and maintenance.
  - Formally verified synchronization primitives are highly-sought after.
  - Otherwise primitives are implemented from papers or ported from proven codebases
    that can serve as reference for auditors.
- Resource-efficient. Threads spindown to save power, low memory use.
- Decent performance and scalability. The CPU should spent its time processing user workloads
  and not dealing with threadpool contention, latencies and overheads.

## Example usage

```Nim
# Demo of API using a very inefficient π approcimation algorithm.

import
  std/[strutils, math, cpuinfo],
  taskpools

# From https://github.com/nim-lang/Nim/blob/v1.6.2/tests/parallel/tpi.nim
# Leibniz Formula https://en.wikipedia.org/wiki/Leibniz_formula_for_%CF%80
proc term(k: int): float =
  if k mod 2 == 1:
    -4'f / float(2*k + 1)
  else:
    4'f / float(2*k + 1)

proc piApprox(tp: Taskpool, n: int): float =
  var pendingFuts = newSeq[FlowVar[float]](n)
  for k in 0 ..< pendingFuts.len:
    pendingFuts[k] = tp.spawn term(k) # Schedule a task on the threadpool a return a handle to retrieve the result.
  for k in 0 ..< pendingFuts.len:
    result += sync pendingFuts[k]     # Block until the result is available.

proc main() =
  var n = 1_000_000
  var nthreads = countProcessors()

  var tp = Taskpool.new(num_threads = nthreads) # Default to the number of hardware threads.

  echo formatFloat(tp.piApprox(n))

  tp.syncAll()                                  # Block until all pending tasks are processed (implied in tp.shutdown())
  tp.shutdown()

# Compile with nim c -r -d:release --threads:on --outdir:build example.nim
main()
```

## API

The API follows the spec proposed here https://github.com/nim-lang/RFCs/issues/347#task-parallelism-api

The following types and procedures are exposed:

- Taskpool:
  - ```Nim
    type Taskpool* = ptr object
      ## A taskpool schedules procedures to be executed in parallel
    ```
  - ```Nim
    proc new(T: type Taskpool, numThreads = countProcessor()): T
      ## Initialize a threadpool that manages `numThreads` threads.
      ## Default to the number of logical processors available.
    ```
  - ```Nim
    proc syncAll*(pool: Taskpool) =
      ## Blocks until all pending tasks are completed.
      ##
      ## This MUST only be called from
      ## the root thread that created the taskpool
    ```
  - ```Nim
    proc shutdown*(tp: var TaskPool) =
      ## Wait until all tasks are completed and then shutdown the taskpool.
      ##
      ## This MUST only be called from
      ## the root scope that created the taskpool.
    ```
  - ```Nim
    macro spawn*(tp: TaskPool, fnCall: typed): untyped =
      ## Spawns the input function call asynchronously, potentially on another thread of execution.
      ##
      ## If the function calls returns a result, spawn will wrap it in a Flowvar.
      ## You can use `sync` to block the current thread and extract the asynchronous result from the flowvar.
      ## You can use `isReady` to check if result is available and if subsequent
      ## `spawn` returns immediately.
      ##
      ## Tasks are processed approximately in Last-In-First-Out (LIFO) order
    ```
    In practice the signature is one of the following
    ```Nim
    proc spawn*(tp: TaskPool, fnCall(args) -> T): Flowvar[T]
    proc spawn*(tp: TaskPool, fnCall(args) -> void): void
    ```
- Flowvar, a handle on an asynchronous computation scheduled on the threadpool
  - ```Nim
    type Flowvar*[T] = object
      ## A Flowvar is a placeholder for a future result that may be computed in parallel
    ```
  - ```Nim
    func isSpawned*(fv: Flowvar): bool =
      ## Returns true if a flowvar is spawned
      ## This may be useful for recursive algorithms that
      ## may or may not spawn a flowvar depending on a condition.
      ## This is similar to Option or Maybe types
    ```
  - ```Nim
    func isReady*[T](fv: Flowvar[T]): bool =
      ## Returns true if the result of a Flowvar is ready.
      ## In that case `sync` will not block.
      ## Otherwise the current will block to help on all the pending tasks
      ## until the Flowvar is ready.
    ```
  - ```Nim
    proc sync*[T](fv: sink Flowvar[T]): T =
      ## Blocks the current thread until the flowvar is available
      ## and returned.
      ## The thread is not idle and will complete pending tasks.
    ```

### Non-goals

The following are non-goals:

- Supporting GC-ed memory on Nim default GC (sequences and strings)
- Having async-awaitable tasks
- Running on environments without dynamic memory allocation
- High-Performance Computing specificities (distribution on many machines or GPUs or machines with 200+ cores or multi-sockets)

### Comparison with Weave

Compared to [Weave](https://github.com/mratsim/weave), here are the tradeoffs:
- Taskpools only provide spawn/sync (task parallelism).\
  There is no (extremely) optimized parallel for (data parallelism)\
  or precise in/out dependencies (events / dataflow parallelism).
- Weave can handle trillions of small tasks that require only 10µs per task. (Load Balancing overhead)
- Weave maintains an adaptive memory pool to reduce memory allocation overhead,
  Taskpools allocations are as-needed. (Scheduler overhead)

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. This file may not be copied, modified, or distributed except according to those terms.
