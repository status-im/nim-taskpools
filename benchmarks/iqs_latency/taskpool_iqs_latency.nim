import
  os, strutils, cpuinfo, strformat, math, atomics,
  ../../taskpools,
  ../wtime

# Benchmark: Injection Queue Starvation (IQS) - external-task latency
#
# The MPMC injection queue (used when external threads call spawn) is drained
# by workers between local tasks. If tasks spawned from within the pool
# continuously refill the local Chase-Lev deques, externally submitted tasks
# can pile up in the injection queue and be consumed only slowly.
#
# This benchmark runs two concurrent workloads:
#
#   INTERNAL: the root pool worker spawns a binary tree of depth D
#             (2^(D+1)-1 tasks). Each internal task calls tp.spawn from within
#             a pool thread -> schedule() -> local Chase-Lev deque, keeping the
#             workers perpetually busy on local work.
#
#   EXTERNAL: NumExtThreads non-pool threads concurrently call tp.spawn, which
#             calls submitTask() -> injection queue (Treiber stack).
#
# Key metric: external-task latency
#   = T_last_external_done - T_submit_end
#   = wall time between "all external tasks submitted" and "the last external
#     task actually completed".
#
# Unlike a "starvation window" measured against syncAll() (which is bound by
# the TOTAL workload, since syncAll waits for everything), this isolates how
# long externally injected tasks sit unconsumed while workers churn through a
# continuously refilled local deque. A large value means external tasks were
# starved; a small value means the injection queue was drained promptly.

var InternalDepth: int32       # binary-tree depth; internal tasks = 2^(D+1)-1
var NumExtThreads: int         # external (non-pool) producer threads
var NumTasksPerExtThread: int  # tasks each external thread submits

var tp: Taskpool
var externalCompleted: Atomic[int]
var numExtTasksTotal: int
var submitEndMs: float64
var lastExtDoneMs: Atomic[int]  # msec*1000 stored as int for atomicity

template dummy_cpt(): untyped =
  # Minimal CPU burn so tasks are not zero-cost (helps keep deques non-empty)
  var fib = 0
  var f2 = 0
  var f1 = 1
  for i in 2 .. 30:
    fib = f1 + f2
    f2 = f1
    f1 = fib

# Spawned from within pool workers -> goes to local Chase-Lev deque via schedule().
# Continuously refills deques, keeping workers busy on local work.
proc internalSpawn(depth: int32) {.gcsafe, raises: [].} =
  if depth > 0:
    tp.spawn internalSpawn(depth - 1)
    tp.spawn internalSpawn(depth - 1)
  dummy_cpt()

# Submitted from external threads -> goes to injection queue via submitTask().
# The last one to complete records the timestamp used for the latency metric.
proc externalTask() {.gcsafe, raises: [].} =
  dummy_cpt()
  let n = externalCompleted.fetchAdd(1, moRelaxed) + 1
  if n == numExtTasksTotal:
    lastExtDoneMs.store(int(wtime_msec() * 1000), moRelaxed)

proc externalProducer() {.thread.} =
  for _ in 0 ..< NumTasksPerExtThread:
    tp.spawn externalTask()

proc main() =
  InternalDepth = 20          # 2^21 - 1 ~ 2 M internal tasks
  NumExtThreads = 16
  NumTasksPerExtThread = 10000

  if paramCount() == 0:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <internal tree depth: {InternalDepth}> " &
         &"<# of external threads: {NumExtThreads}> " &
         &"<tasks per external thread: {NumTasksPerExtThread}>"
    echo &"Running with defaults: depth={InternalDepth}, " &
         &"extThreads={NumExtThreads}, tasksPerThread={NumTasksPerExtThread}"
  if paramCount() >= 1:
    InternalDepth = paramStr(1).parseInt().int32
  if paramCount() >= 2:
    NumExtThreads = paramStr(2).parseInt()
  if paramCount() >= 3:
    NumTasksPerExtThread = paramStr(3).parseInt()
  if paramCount() > 3:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <internal tree depth: {InternalDepth}> " &
         &"<# of external threads: {NumExtThreads}> " &
         &"<tasks per external thread: {NumTasksPerExtThread}>"
    quit 1

  numExtTasksTotal = NumExtThreads * NumTasksPerExtThread
  let numInternalTasksTotal = (1 shl (InternalDepth + 1)) - 1

  var nthreads: int
  if existsEnv"TASKPOOL_NUM_THREADS":
    nthreads = getEnv"TASKPOOL_NUM_THREADS".parseInt()
  else:
    nthreads = countProcessors()

  externalCompleted.store(0, moRelaxed)
  lastExtDoneMs.store(0, moRelaxed)
  tp = Taskpool.new(numThreads = nthreads)

  let start = wtime_msec()

  # Kick off the internal tree from the root pool worker; this immediately
  # starts filling the local deques of all workers.
  tp.spawn internalSpawn(InternalDepth)

  # Launch external producers right after; they compete with the internal tree
  # for injection queue drain time.
  var extThreads = newSeq[Thread[void]](NumExtThreads)
  for t in extThreads.mitems():
    createThread(t, externalProducer)
  for t in extThreads:
    joinThread(t)

  # All external tasks are now submitted (in the injection queue or consumed).
  submitEndMs = wtime_msec()

  # Wait for all work — internal tree + external tasks — to complete.
  tp.syncAll()
  let allDone = wtime_msec()

  tp.shutdown()

  let got = externalCompleted.load(moRelaxed)
  doAssert got == numExtTasksTotal,
    &"Expected {numExtTasksTotal} external tasks completed, got {got}"

  let lastExtDone   = lastExtDoneMs.load(moRelaxed).float64 / 1000.0
  let extLatencyMs  = round(lastExtDone - submitEndMs, 3)
  let totalMs       = round(allDone - start, 3)
  let submissionMs  = round(submitEndMs - start, 3)

  echo "--------------------------------------------------------------------------"
  echo "Scheduler:                                     Taskpool"
  echo "Benchmark:                                     IQS (Injection Queue Starvation)"
  echo "Pool threads:                                  ", nthreads
  echo "External producer threads:                     ", NumExtThreads
  echo "Time total (ms):                               ", totalMs
  echo "--------------------------------------------------------------------------"
  echo "Internal tree depth:                           ", InternalDepth
  echo "Internal tasks (2^(D+1)-1):                    ", numInternalTasksTotal
  echo "External tasks total:                          ", numExtTasksTotal
  echo "External tasks per thread:                     ", NumTasksPerExtThread
  echo "--------------------------------------------------------------------------"
  echo "External submission wall time (ms):            ", submissionMs
  echo "External task latency (ms):                    ", extLatencyMs
  echo "  (time between last external submit and the last external task done)"
  echo "  A large value means external tasks were starved in the injection queue"
  echo "  while pool workers were busy processing internal spawns."

  quit 0

main()
