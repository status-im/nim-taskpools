# Nim-Taskpools
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Taskpools
#
# This file implements a taskpool
#
# Implementation:
#
# It is a simple shared memory based work-stealing threadpool.
# The primary focus is:
# - Delegate compute intensive tasks to the threadpool.
# - Simple to audit by staying close to foundational papers
#   and using simple datastructures otherwise.
# - Low energy consumption:
#   threads should be put to sleep ASAP
#   instead of polling/spinning (energy vs latency tradeoff)
# - Decent performance:
#   Work-stealing has optimal asymptotic parallel speedup.
#   Work-stealing has significantly reduced contention
#   when many tasks are created,
#   for example by divide-and-conquer algorithms, compared to a global task queue
#
# Not a priority:
# - Handling trillions of very short tasks (less than 100µs).
# - Advanced task dependencies or events API.
# - Unbalanced parallel-for loops.
# - Handling services that should run for the lifetime of the program.
#
# Doing IO on a compute threadpool should be avoided
# In case a thread is blocked for IO, other threads can steal pending tasks in that thread.
# If all threads are pending for IO, the threadpool will not make any progress and be soft-locked.

{.push raises: [].}

import
  system/ansi_c,
  std/[random, cpuinfo, atomics, macros],
  ./channels_spsc_single,
  ./chase_lev_deques,
  ./event_notifiers,
  ./primitives/[barriers, allocs],
  ./instrumentation/[contracts, loggers],
  ./sparsesets,
  ./flowvars,
  ./ast_utils

export
  # flowvars
  Flowvar, isSpawned, isReady, sync

when defined(windows):
  import ./primitives/affinity_windows
else:
  import ./primitives/affinity_posix

when (NimMajor,NimMinor,NimPatch) >= (1,6,0):
  import std/tasks
else:
  import ./shims_pre_1_6/tasks

type
  WorkerID = int32

  TaskNode = ptr object
    # Linked list of tasks
    parent: TaskNode
    task: Task

  Signal = object
    terminate {.align: 64.}: Atomic[bool]

  WorkerContext = object
    ## Thread-local worker context

    # Params
    id: WorkerID
    taskpool: Taskpool

    # Tasks
    taskDeque: ptr ChaseLevDeque[TaskNode] # owned task deque
    currentTask: TaskNode

    # Synchronization
    eventNotifier: ptr EventNotifier # shared event notifier
    signal: ptr Signal               # owned signal

    # Thefts
    rng: Rand                        # RNG state to select victims
    numThreads: int
    otherDeques: ptr UncheckedArray[ChaseLevDeque[TaskNode]]
    victims: SparseSet

  Taskpool* = ptr object
    barrier: SyncBarrier
      ## Barrier for initialization and teardown
    # --- Align: 64
    eventNotifier: EventNotifier
      ## Puts thread to sleep

    numThreads*{.align: 64.}: int
    workerDeques: ptr UncheckedArray[ChaseLevDeque[TaskNode]]
      ## Direct access for task stealing
    workers: ptr UncheckedArray[Thread[(Taskpool, WorkerID)]]
    workerSignals: ptr UncheckedArray[Signal]
      ## Access signaledTerminate

# Thread-local config
# ---------------------------------------------

var workerContext {.threadvar.}: WorkerContext
  ## Thread-local Worker context

proc setupWorker() =
  ## Initialize the thread-local context of a worker
  ## Requires the ID and taskpool fields to be initialized
  template ctx: untyped = workerContext

  preCondition: not ctx.taskpool.isNil()
  preCondition: 0 <= ctx.id and ctx.id < ctx.taskpool.numThreads
  preCondition: not ctx.taskpool.workerDeques.isNil()
  preCondition: not ctx.taskpool.workerSignals.isNil()

  # Thefts
  ctx.rng = initRand(0xEFFACED + ctx.id)
  ctx.numThreads = ctx.taskpool.numThreads
  ctx.otherDeques = ctx.taskpool.workerDeques
  ctx.victims.allocate(ctx.taskpool.numThreads)

  # Synchronization
  ctx.eventNotifier = addr ctx.taskpool.eventNotifier
  ctx.signal = addr ctx.taskpool.workerSignals[ctx.id]
  ctx.signal.terminate.store(false, moRelaxed)

  # Tasks
  ctx.taskDeque = addr ctx.taskpool.workerDeques[ctx.id]
  ctx.currentTask = nil

  # Init
  ctx.taskDeque[].init()

proc teardownWorker() =
  ## Cleanup the thread-local context of a worker
  template ctx: untyped = workerContext
  ctx.taskDeque[].teardown()
  ctx.victims.delete()

proc eventLoop(ctx: var WorkerContext) {.raises:[Exception].}

proc workerEntryFn(params: tuple[taskpool: Taskpool, id: WorkerID])
       {.raises: [Exception].} =
  ## On the start of the threadpool workers will execute this
  ## until they receive a termination signal
  # We assume that thread_local variables start all at their binary zero value
  preCondition: workerContext == default(WorkerContext)

  template ctx: untyped = workerContext

  # If the following crashes, you need --tlsEmulation:off
  ctx.id = params.id
  ctx.taskpool = params.taskpool

  setupWorker()

  # 1 matching barrier in Taskpool.new() for root thread
  discard params.taskpool.barrier.wait()

  {.gcsafe.}: # Not GC-safe when multi-threaded due to thread-local variables
    ctx.eventLoop()

  debugTermination:
    log(">>> Worker %2d shutting down <<<\n", ctx.id)

  # 1 matching barrier in taskpool.shutdown() for root thread
  discard params.taskpool.barrier.wait()

  teardownWorker()

# Tasks
# ---------------------------------------------

proc new(T: type TaskNode, parent: TaskNode, task: sink Task): T =
  type TaskNodeObj = typeof(default(T)[])
  var tn = cast[TaskNode](c_calloc(1, csize_t sizeof(TaskNodeObj)))
  tn.parent = parent
  tn.task = task
  return tn

proc runTask(tn: var TaskNode) {.raises:[Exception], inline.} =
  ## Run a task and consumes the taskNode
  tn.task.invoke()
  tn.task.`=destroy`()
  tn.c_free()

proc schedule(ctx: WorkerContext, tn: sink TaskNode) {.inline.} =
  ## Schedule a task in the taskpool
  debug: log("Worker %2d: schedule task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, tn, tn.parent, ctx.currentTask)
  ctx.taskDeque[].push(tn)
  ctx.taskpool.eventNotifier.notify()

# Scheduler
# ---------------------------------------------

proc trySteal(ctx: var WorkerContext): TaskNode =
  ## Try to steal a task.

  ctx.victims.refill()
  ctx.victims.excl(ctx.id)

  while not ctx.victims.isEmpty():
    let target = ctx.victims.randomPick(ctx.rng)

    let stolenTask = ctx.otherDeques[target].steal()
    if not stolenTask.isNil:
      return stolenTask

    ctx.victims.excl(target)

  return nil

proc eventLoop(ctx: var WorkerContext) {.raises:[Exception].} =
  ## Each worker thread executes this loop over and over.
  while not ctx.signal.terminate.load(moRelaxed):
    # 1. Pick from local deque
    debug: log("Worker %2d: eventLoop 1 - searching task from local deque\n", ctx.id)
    while (var taskNode = ctx.taskDeque[].pop(); not taskNode.isNil):
      debug: log("Worker %2d: eventLoop 1 - running task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, taskNode, taskNode.parent, ctx.currentTask)
      taskNode.runTask()

    # 2. Run out of tasks, become a thief
    debug: log("Worker %2d: eventLoop 2 - becoming a thief\n", ctx.id)
    var stolenTask = ctx.trySteal()
    if not stolenTask.isNil:
      # 2.a Run task
      debug: log("Worker %2d: eventLoop 2.a - stole task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, stolenTask, stolenTask.parent, ctx.currentTask)
      stolenTask.runTask()
    else:
      # 2.b Park the thread until a new task enters the taskpool
      debug: log("Worker %2d: eventLoop 2.b - sleeping\n", ctx.id)
      ctx.eventNotifier[].park()
      debug: log("Worker %2d: eventLoop 2.b - waking\n", ctx.id)

# Tasking
# ---------------------------------------------

const RootTask = default(Task) # TODO: sentinel value different from null task

template isRootTask(task: Task): bool =
  task == RootTask

proc forceFuture*[T](fv: Flowvar[T], parentResult: var T) {.raises:[Exception].} =
  ## Eagerly complete an awaited FlowVar

  template ctx: untyped = workerContext

  template isFutReady(): untyped =
    fv.chan[].tryRecv(parentResult)

  if isFutReady():
    return

  ## 1. Process all the children of the current tasks.
  ##    This ensures that we can give control back ASAP.
  debug: log("Worker %2d: sync 1 - searching task from local deque\n", ctx.id)
  while (var taskNode = ctx.taskDeque[].pop(); not taskNode.isNil):
    if taskNode.parent != ctx.currentTask:
      debug: log("Worker %2d: sync 1 - skipping non-direct descendant task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, taskNode, taskNode.parent, ctx.currentTask)
      ctx.schedule(taskNode)
      break
    debug: log("Worker %2d: sync 1 - running task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, taskNode, taskNode.parent, ctx.currentTask)
    taskNode.runTask()
    if isFutReady():
      debug: log("Worker %2d: sync 1 - future ready, exiting\n", ctx.id)
      return

  ## 2. We run out-of-tasks or out-of-direct-child of our current awaited task
  ##    So the task is bottlenecked by dependencies in other threads,
  ##    hence we abandon our enqueued work and steal in the others' queues
  ##    in hope it advances our awaited task. This prioritizes latency over throughput.
  debug: log("Worker %2d: sync 2 - future not ready, becoming a thief (currentTask 0x%.08x)\n", ctx.id, ctx.currentTask)
  while not isFutReady():
    var taskNode = ctx.trySteal()

    if not taskNode.isNil:
      # We stole some task, we hope we advance our awaited task
      debug: log("Worker %2d: sync 2.1 - stole task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, taskNode, taskNode.parent, ctx.currentTask)
      taskNode.runTask()
    # elif (taskNode = ctx.taskDeque[].pop(); not taskNode.isNil):
    #   # We advance our own queue, this increases throughput but may impact latency on the awaited task
    #   debug: log("Worker %2d: sync 2.2 - couldn't steal, running own task\n", ctx.id)
    #   taskNode.runTask()
    else:
      # We don't park as there is no notif for task completion
      cpuRelax()

proc syncAll*(pool: Taskpool) {.raises: [Exception].} =
  ## Blocks until all pending tasks are completed
  ## This MUST only be called from
  ## the root scope that created the taskpool
  template ctx: untyped = workerContext

  debugTermination:
    log(">>> Worker %2d enters barrier <<<\n", ctx.id)

  preCondition: ctx.id == 0
  preCondition: ctx.currentTask.task.isRootTask()

  # Empty all tasks
  var foreignThreadsParked = false
  while not foreignThreadsParked:
    # 1. Empty local tasks
    debug: log("Worker %2d: syncAll 1 - searching task from local deque\n", ctx.id)
    while (var taskNode = ctx.taskDeque[].pop(); not taskNode.isNil):
      debug: log("Worker %2d: syncAll 1 - running task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, taskNode, taskNode.parent, ctx.currentTask)
      taskNode.runTask()

    if ctx.numThreads == 1 or foreignThreadsParked:
      break

    # 2. Help other threads
    debug: log("Worker %2d: syncAll 2 - becoming a thief\n", ctx.id)
    var taskNode = ctx.trySteal()

    if not taskNode.isNil:
      # 2.1 We stole some task
      debug: log("Worker %2d: syncAll 2.1 - stole task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, taskNode, taskNode.parent, ctx.currentTask)
      taskNode.runTask()
    else:
      # 2.2 No task to steal
      if pool.eventNotifier.getParked() == pool.numThreads - 1:
        # 2.2.1 all threads besides the current are parked
        debugTermination:
          log("Worker %2d: syncAll 2.2.1 - termination, all other threads sleeping\n", ctx.id)
        foreignThreadsParked = true
      else:
        # 2.2.2 We don't park as there is no notif for task completion
        cpuRelax()

  debugTermination:
    log(">>> Worker %2d leaves barrier <<<\n", ctx.id)

# Runtime
# ---------------------------------------------

proc new*(T: type Taskpool, numThreads = countProcessors(), pinThreadsToCores = false): T {.raises: [Exception].} =
  ## Initialize a threadpool that manages `numThreads` threads.
  ## Default to the number of logical processors available.
  ##
  ## If pinToCPU is set, threads spawned will be pinned to the core that spawned them.
  ## This improves performance of memory-intensive workloads by avoiding
  ## thrashing and reloading core caches when a thread moves around.
  ##
  ## pinThreadsToCores option is ignored in:
  ## - In C++ compilation with Microsoft Visual Studio Compiler
  ## - MacOS
  ## - Android
  #
  # pinThreadsToCores Status:
  # - C++ MSVC: implementation missing (need to wrap reinterpret_cast)
  # - Android: API missing and unclear benefits due to Big.Little architecture
  # - MacOS: API missing

  type TpObj = typeof(default(Taskpool)[])
  # Event notifier requires an extra 64 bytes for alignment
  var tp = wv_allocAligned(TpObj, sizeof(TpObj) + 64, 64)

  tp.barrier.init(numThreads.int32)
  tp.eventNotifier.initialize()
  tp.numThreads = numThreads
  tp.workerDeques = wv_allocArrayAligned(ChaseLevDeque[TaskNode], numThreads, alignment = 64)
  tp.workers = wv_allocArrayAligned(Thread[(Taskpool, WorkerID)], numThreads, alignment = 64)
  tp.workerSignals = wv_allocArrayAligned(Signal, numThreads, alignment = 64)

  # Setup master thread
  workerContext.id = 0
  workerContext.taskpool = tp

  if pinThreadsToCores:
    when not(defined(cpp) and defined(vcc)):
      # TODO: Nim casts between Windows Handles but that requires reinterpret cast for C++
      pinToCpu(0)

  # Start worker threads
  for i in 1 ..< numThreads:
    createThread(tp.workers[i], worker_entry_fn, (tp, WorkerID(i)))

    if pinThreadsToCores:
      # TODO: we might want to take into account Hyper-Threading (HT)
      #       and allow spawning tasks and pinning to cores that are not HT-siblings.
      #       This is important for memory-bound workloads (like copy, addition, ...)
      #       where both sibling cores will compete for L1 and L2 cache, effectively
      #       halving the memory bandwidth or worse, flushing what the other put in cache.
      #       Note that while 2x siblings is common, Xeon Phi has 4x Hyper-Threading.
      when not(defined(cpp) and defined(vcc)):
        # TODO: Nim casts between Windows Handles but that requires reinterpret cast for C++
        pinToCpu(tp.workers[i], i)

  # Root worker
  setupWorker()

  # Root task, this is a sentinel task that is never called.
  workerContext.currentTask = TaskNode.new(
    parent = nil,
    task = default(Task) # TODO RootTask, somehow this uses `=copy`
  )

  # Wait for the child threads
  discard tp.barrier.wait()
  return tp

proc cleanup(tp: var TaskPool) {.raises: [OSError].} =
  ## Cleanup all resources allocated by the taskpool
  preCondition: workerContext.currentTask.task.isRootTask()

  for i in 1 ..< tp.numThreads:
    joinThread(tp.workers[i])

  tp.workerSignals.wv_freeAligned()
  tp.workers.wv_freeAligned()
  tp.workerDeques.wv_freeAligned()
  `=destroy`(tp.eventNotifier)
  tp.barrier.delete()

  tp.wv_freeAligned()

proc shutdown*(tp: var TaskPool) {.raises:[Exception].} =
  ## Wait until all tasks are processed and then shutdown the taskpool
  preCondition: workerContext.currentTask.task.isRootTask()
  tp.syncAll()

  # Signal termination to all threads
  for i in 0 ..< tp.numThreads:
    tp.workerSignals[i].terminate.store(true, moRelaxed)

  let parked = tp.eventNotifier.getParked()
  for i in 0 ..< parked:
    tp.eventNotifier.notify()

  # 1 matching barrier in worker_entry_fn
  discard tp.barrier.wait()

  teardownWorker()
  tp.cleanup()

  # Dealloc dummy task
  workerContext.currentTask.c_free()

# Task parallelism
# ---------------------------------------------
{.pop.} # raises:[]

macro spawn*(tp: TaskPool, fnCall: typed): untyped =
  ## Spawns the input function call asynchronously, potentially on another thread of execution.
  ##
  ## If the function calls returns a result, spawn will wrap it in a Flowvar.
  ## You can use `sync` to block the current thread and extract the asynchronous result from the flowvar.
  ## You can use `isReady` to check if result is available and if subsequent
  ## `spawn` returns immediately.
  ##
  ## Tasks are processed approximately in Last-In-First-Out (LIFO) order
  result = newStmtList()

  let fn = fnCall[0]
  let fnName = $fn

  # Get the return type if any
  let retType = fnCall[0].getImpl[3][0]
  let needFuture = retType.kind != nnkEmpty

  # Package in a task
  let taskNode = ident("taskNode")
  let task = ident("task")
  if not needFuture:
    result.add quote do:
      let `task` = toTask(`fnCall`)
      let `taskNode` = TaskNode.new(workerContext.currentTask, `task`)
      schedule(workerContext, `taskNode`)

  else:
    # tasks have no return value.
    # 1. We create a channel/flowvar to transmit the return value to awaiter/sync
    # 2. We create a wrapper async_fn without return value that send the return value in the channel
    # 3. We package that wrapper function in a task

    # 1. Create the channel
    let fut = ident("fut")
    let futTy = nnkBracketExpr.newTree(
      bindSym"FlowVar",
      retType
    )
    result.add quote do:
      let `fut` = newFlowVar(type `retType`)

    # 2. Create a wrapper function that sends result to the channel
    # TODO, upstream "getImpl" doesn't return the generic params
    let genericParams = fn.getImpl()[2].replaceSymsByIdents()
    let formalParams = fn.getImpl()[3].replaceSymsByIdents()

    var asyncParams = nnkFormalParams.newTree(
      newEmptyNode()
    )
    var fnCallIdents = nnkCall.newTree(
      fnCall[0]
    )
    for i in 1 ..< formalParams.len:
      let ident = formalParams[i].replaceSymsByIdents()
      asyncParams.add ident
      for j in 0 ..< ident.len - 2:
        # Handle "a, b: int"
        fnCallIdents.add ident[j]

    let futFnParam = ident("fut")
    asyncParams.add newIdentDefs(futFnParam, futTy)

    let asyncBody = quote do:
      # XXX: can't test that when the RootTask is default(Task) instead of a sentinel value
      # preCondition: not isRootTask(workerContext.currentTask.task)

      let res = `fnCallIdents`
      readyWith(`futFnParam`, res)

    let asyncFn = ident("taskpool_" & fnName)
    result.add nnkProcDef.newTree(
      asyncFn,
      newEmptyNode(),
      genericParams,
      asyncParams,
      nnkPragma.newTree(ident("nimcall")),
      newEmptyNode(),
      asyncBody
    )

    var asyncCall = newCall(asyncFn)
    for i in 1 ..< fnCall.len:
      asyncCall.add fnCall[i].replaceSymsByIdents()
    asyncCall.add fut

    result.add quote do:
      let `task` = toTask(`asyncCall`)
      let `taskNode` = TaskNode.new(workerContext.currentTask, `task`)
      schedule(workerContext, `taskNode`)

      # Return the future / flowvar
      `fut`

  # Wrap in a block for namespacing
  result = nnkBlockStmt.newTree(newEmptyNode(), result)
  # echo result.toStrLit()
