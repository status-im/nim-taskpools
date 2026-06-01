import
  # STD lib
  os, strutils, system/ansi_c, cpuinfo, strformat, math, atomics,
  # Library
  ../../taskpools,
  # bench
  ../wtime, ../resources

# Benchmark: Injection Queue Starvation (IQS)
#
# Known caveat: the MPMC injection queue (used when external threads call spawn)
# is drained by workers ONLY when their local Chase-Lev deque is empty.
#
# If tasks spawned from within the pool continuously refill local deques,
# external tasks pile up in the injection queue and are never consumed
# until all internal spawning stops and deques finally drain.
#
# This benchmark triggers the condition by running two concurrent workloads:
#
#   INTERNAL: the main pool worker spawns a binary tree of depth D
#             (2^(D+1)-1 tasks). Each internal task calls tp.spawn from
#             within a pool thread -> schedule() -> local Chase-Lev deque.
#             Workers stay perpetually busy at step 1.
#
#   EXTERNAL: NumExtThreads non-pool threads concurrently call tp.spawn,
#             which calls submitTask() -> injection queue (Treiber stack).
#             These tasks cannot be drained while deques are full.
#
# Key metric: starvation window
#   = T_all_done - T_submit_end
#   = time between "all external tasks submitted" and "syncAll() returns"
#
# A large starvation window means external tasks sat queued while the pool
# was busy with internal work. A small one means the injection queue was
# drained promptly alongside internal work.

var InternalDepth: int32    # binary-tree depth; internal tasks = 2^(D+1)-1
var NumExtThreads: int      # external (non-pool) producer threads
var NumTasksPerExtThread: int  # tasks each external thread submits

var tp: Taskpool
var externalCompleted: Atomic[int]

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
# Continuously refills deques, preventing workers from ever reaching
# drainInjectionQueue() while the tree is alive.
proc internalSpawn(depth: int32) {.gcsafe, raises: [].} =
  if depth > 0:
    tp.spawn internalSpawn(depth - 1)
    tp.spawn internalSpawn(depth - 1)
  dummy_cpt()

# Submitted from external threads -> goes to injection queue via submitTask().
# Starved until all internal work has drained the local deques.
proc externalTask() {.gcsafe, raises: [].} =
  dummy_cpt()
  discard externalCompleted.fetchAdd(1, moRelaxed)

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

  let numExtTasksTotal = NumExtThreads * NumTasksPerExtThread
  let numInternalTasksTotal = (1 shl (InternalDepth + 1)) - 1

  var nthreads: int
  if existsEnv"TASKPOOL_NUM_THREADS":
    nthreads = getEnv"TASKPOOL_NUM_THREADS".parseInt()
  else:
    nthreads = countProcessors()

  externalCompleted.store(0, moRelaxed)
  tp = Taskpool.new(numThreads = nthreads)

  var ru: Rusage
  getrusage(RusageSelf, ru)
  var
    rss = ru.ru_maxrss
    flt = ru.ru_minflt

  let start = wtime_msec()

  # Kick off the internal tree from the root pool worker.
  # This immediately starts filling local deques of all workers.
  tp.spawn internalSpawn(InternalDepth)

  # Launch external producers right after.
  # They will compete with the internal tree for injection queue drain time.
  var extThreads = newSeq[Thread[void]](NumExtThreads)
  for t in extThreads.mitems():
    createThread(t, externalProducer)
  for t in extThreads:
    joinThread(t)

  # All external tasks are now in the injection queue (or already consumed).
  let submitEnd = wtime_msec()

  # Wait for all work — internal tree + external tasks — to complete.
  tp.syncAll()

  let allDone = wtime_msec()

  getrusage(RusageSelf, ru)
  rss = ru.ru_maxrss - rss
  flt = ru.ru_minflt - flt

  tp.shutdown()

  let got = externalCompleted.load(moRelaxed)
  doAssert got == numExtTasksTotal,
    &"Expected {numExtTasksTotal} external tasks completed, got {got}"

  let totalMs       = round(allDone - start, 3)
  let submissionMs  = round(submitEnd - start, 3)
  let starvationMs  = round(allDone - submitEnd, 3)

  echo "--------------------------------------------------------------------------"
  echo "Scheduler:                                     Taskpool"
  echo "Benchmark:                                     IQS (Injection Queue Starvation)"
  echo "Pool threads:                                  ", nthreads
  echo "External producer threads:                     ", NumExtThreads
  echo "Time total (ms):                               ", totalMs
  echo "Max RSS (KB):                                  ", ru.ru_maxrss
  echo "Runtime RSS (KB):                              ", rss
  echo "# of page faults:                              ", flt
  echo "--------------------------------------------------------------------------"
  echo "Internal tree depth:                           ", InternalDepth
  echo "Internal tasks (2^(D+1)-1):                   ", numInternalTasksTotal
  echo "External tasks total:                          ", numExtTasksTotal
  echo "External tasks per thread:                     ", NumTasksPerExtThread
  echo "--------------------------------------------------------------------------"
  echo "External submission wall time (ms):            ", submissionMs
  echo "Starvation window (ms):                        ", starvationMs
  echo "  (time between last external submit and syncAll returning)"
  echo "  A large value means external tasks were starved in the injection queue"
  echo "  while pool workers were busy processing internal spawns."

  quit 0

main()
