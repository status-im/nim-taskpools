import
  # STD lib
  os, strutils, system/ansi_c, cpuinfo, strformat, math,
  # Library
  ../../taskpools,
  # bench
  ../wtime, ../resources

# External-thread variant of the SPC (Single task Producer - multi Consumer) benchmark.

var NumTasksTotal: int32
var TaskGranularity: int32 # microsecond
var PollInterval: float64  # microsecond

var tp: Taskpool

var global_poll_elapsed {.threadvar.}: float64

template dummy_cpt(): untyped =
  var
    fib = 0
    f2 = 0
    f1 = 1
  for i in 2 .. 30:
    fib = f1 + f2
    f2 = f1
    f1 = fib

proc spc_consume(usec: int32) {.gcsafe, raises: [].} =
  let start = wtime_usec()
  let stop = usec.float64
  while true:
    let elapsed = wtime_usec() - start
    if elapsed >= stop:
      break
    dummy_cpt()

proc spc_produce(n: int32) {.thread.} =
  for i in 0 ..< n:
    tp.spawn spc_consume(TaskGranularity)

proc main() =
  NumTasksTotal = 1000000
  TaskGranularity = 10
  PollInterval = 10

  if paramCount() == 0:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <# of tasks:{NumTasksTotal}> " &
         &"<task granularity (us): {TaskGranularity}> " &
         &"[polling interval (us): task granularity]"
    echo &"Running with default config tasks = {NumTasksTotal}, granularity (us) = {TaskGranularity}, polling (us) = {PollInterval}"
  if paramCount() >= 1:
    NumTasksTotal = paramStr(1).parseInt.int32
  if paramCount() >= 2:
    TaskGranularity = paramStr(2).parseInt.int32
  if paramCount() == 3:
    PollInterval = paramStr(3).parseInt.float64
  else:
    PollInterval = TaskGranularity.float64
  if paramCount() > 3:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <# of tasks:{NumTasksTotal}> " &
         &"<task granularity (us): {TaskGranularity}> " &
         &"[polling interval (us): task granularity]"
    quit 1

  var nthreads: int
  if existsEnv"TP_NUM_THREADS":
    nthreads = getEnv"TP_NUM_THREADS".parseInt()
  else:
    nthreads = countProcessors()

  tp = Taskpool.new(numThreads = nthreads)

  var ru: Rusage
  getrusage(RusageSelf, ru)
  var
    rss = ru.ru_maxrss
    flt = ru.ru_minflt

  let start = wtime_msec()

  var producer: Thread[int32]
  createThread(producer, spc_produce, NumTasksTotal)
  joinThread(producer)

  tp.syncAll()

  let stop = wtime_msec()

  getrusage(RusageSelf, ru)
  rss = ru.ru_maxrss - rss
  flt = ru.ru_minflt - flt

  tp.shutdown()

  echo "--------------------------------------------------------------------------"
  echo "Scheduler:                                     Taskpool"
  echo "Benchmark:                                     SPC external (Single task Producer - multi Consumer)"
  echo "Threads:                                       ", nthreads
  echo "Time(ms)                                       ", round(stop - start, 3)
  echo "Max RSS (KB):                                  ", ru.ru_maxrss
  echo "Runtime RSS (KB):                              ", rss
  echo "# of page faults:                              ", flt
  echo "--------------------------------------------------------------------------"
  echo "# of tasks:                                    ", NumTasksTotal
  echo "Task granularity (us):                         ", TaskGranularity
  echo "Polling / manual load balancing interval (us): ", PollInterval

  quit 0

main()
