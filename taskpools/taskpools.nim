# taskpools
# Copyright (c) 2021-2025 Status Research & Development GmbH
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

{.push raises: [], gcsafe.} # Ensure no exceptions can happen

import
  system/ansi_c,
  std/[atomics, cpuinfo, isolation, macros, random, typetraits],
  ./[
    ast_utils, backoff, chase_lev_deques, flowvars,
    injection_queues, sparsesets,
  ],
  ./primitives/[barriers, allocs],
  ./instrumentation/[contracts, loggers]

export
  # flowvars
  Flowvar, isSpawned, isReady, sync, isolation

const sharedHeap = defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc)

type
  WorkerID = int32

  TaskCallback = proc(args: pointer) {.nimcall, gcsafe, raises: [].}
  TaskNode = ptr object
    # Linked list of tasks
    parent: TaskNode
    callback*: TaskCallback
    args*: pointer
    # intrusive link for the InjectionQueue Treiber stack
    injectionNext*: TaskNode

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
    signal: ptr Signal               # owned signal

    # Thefts
    rng: Rand                        # RNG state to select victims
    otherDeques: ptr UncheckedArray[ChaseLevDeque[TaskNode]]
    victims: SparseSet

  Taskpool* = ptr object
    ## A taskpool schedules procedures to be executed in parallel
    barrier {.align: 64.}: SyncBarrier
      ## Barrier for initialization and teardown
    # --- Align: 64
    globalBackoff {.align: 64.}: EventCount
      ## Multi-producer multi-consumer backoff
    # --- Align: 64
    numThreads* {.align: 64.}: int
    workerDeques: ptr UncheckedArray[ChaseLevDeque[TaskNode]]
      ## Direct access for task stealing
    workers: ptr UncheckedArray[Thread[(Taskpool, WorkerID)]]
    workerSignals: ptr UncheckedArray[Signal]
      ## Access signaledTerminate

    injectionQueue {.align: 64.}: InjectionQueue[TaskNode]
      ## Lock-free MPMC queue for tasks submitted by threads that are not
      ## currently running the scheduler (external threads or foreign pools).

when not sharedHeap:
  proc supportsThreadMove*(T: type): bool {.compileTime.} =
    # Similar to `supportsCopyMem` but allows types with disabled `=copy`. Not
    # perfect - in particular, doesn't allow `proc (...) {.nimcall.}`
    when T is object | tuple:
      for f in fields(cast[ptr T](0)[]):
        if not supportsThreadMove(typeof(f)):
          return false
      true
    elif T is distinct:
      supportsThreadMove(distinctBase(T))
    elif T is array:
      supportsThreadMove(elementType(cast[ptr T](0)[]))
    elif T is
        SomeOrdinal | pointer | ptr | cstring | char | float | float32 | float64 | set:
      true
    else: # string | seq | ref | proc | iterator - last two are tricky
      false

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
  ctx.otherDeques = ctx.taskpool.workerDeques
  ctx.victims.allocate(ctx.taskpool.numThreads)

  # Synchronization
  ctx.signal = addr ctx.taskpool.workerSignals[ctx.id]
  ctx.signal.terminate.store(false, moRelaxed)

  # Tasks
  ctx.taskDeque = addr ctx.taskpool.workerDeques[ctx.id]
  ctx.currentTask = nil

  # Init
  ctx.taskDeque[].init(initialCapacity = 32)

proc teardownWorker() =
  ## Cleanup the thread-local context of a worker
  template ctx: untyped = workerContext
  ctx.taskDeque[].teardown()
  ctx.victims.delete()

proc eventLoop(ctx: var WorkerContext) {.raises:[].}

proc workerEntryFn(params: tuple[taskpool: Taskpool, id: WorkerID]) =
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

proc new(T: type TaskNode, parent: TaskNode, callback: TaskCallback, args: pointer): T =
  var tn = tp_allocPtr(TaskNode)
  tn.parent = parent
  tn.callback = callback
  tn.args = args
  return tn

proc runTask(tn: var TaskNode) {.inline.} =
  ## Run a task and consumes the taskNode
  tn.callback(tn.args)
  tn.tp_free()

proc schedule(ctx: WorkerContext, tn: sink TaskNode, forceWake = false) {.inline.} =
  ## Schedule a task in the taskpool.
  ## This wakes another worker if our local queue is empty
  ## or forceWake is true.
  debug: log("Worker %2d: schedule task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, tn, tn.parent, ctx.currentTask)

  # Instead of notifying every time a task is scheduled, we notify
  # only when the worker queue is empty. This is a good approximation
  # of starvation in work-stealing.
  let wasEmpty = ctx.taskDeque[].peek() == 0
  ctx.taskDeque[].push(tn)
  if forceWake or wasEmpty:
    ctx.taskpool.globalBackoff.wake()

proc submitTask(tp: Taskpool, tn: TaskNode) {.inline.} =
  ## Push a task onto the injection queue from any thread.
  ## Workers will drain the queue into their Chase-Lev deques, making tasks stealable.
  var wasEmpty = false
  tp.injectionQueue.push(tn, wasEmpty)
  if wasEmpty:
    # only one wake is needed; the worker will wake one after draining the queue,
    # the next worker will wake one after steal, and so on.
    tp.globalBackoff.wake()

proc drainInjectionQueue(ctx: var WorkerContext) {.inline.} =
  ## Atomically claim the entire injection queue and push all tasks into
  ## the calling worker's Chase-Lev deque, where they become stealable.
  ## Only one worker wins the exchange; the others drain nothing.
  for node in ctx.taskpool.injectionQueue.drain():
    ctx.taskDeque[].push(node)

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

proc eventLoop(ctx: var WorkerContext) =
  ## Each worker thread executes this loop over and over.
  while true:
    # 1. Pick from local deque
    debug: log("Worker %2d: eventLoop 1 - searching task from local deque\n", ctx.id)
    var processed = 0'u32
    while (var taskNode = ctx.taskDeque[].pop(); not taskNode.isNil):
      debug: log("Worker %2d: eventLoop 1 - running task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, taskNode, taskNode.parent, ctx.currentTask)
      taskNode.runTask()
      inc processed
      if processed >= tasksBetweenInjectionDrains:
        processed = 0
        ctx.drainInjectionQueue()

    let ticket = ctx.taskpool.globalBackoff.sleepy()

    # Drain the injection queue into our Chase-Lev deque so externally submitted
    # tasks become local work (and stealable by other workers).
    ctx.drainInjectionQueue()

    if (var taskNode = ctx.taskDeque[].pop(); not taskNode.isNil):
      # 2. Local queue contains injected tasks.
      debug: log("Worker %2d: eventLoop 2 - running injected task 0x%.08x\n", ctx.id, taskNode)
      ctx.taskpool.globalBackoff.cancelSleep()
      ctx.taskpool.globalBackoff.wake()
      taskNode.runTask()
    elif (var stolenTask = ctx.trySteal(); not stolenTask.isNil):
      # 3. Run stolen task
      debug: log("Worker %2d: eventLoop 3 - stole task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, stolenTask, stolenTask.parent, ctx.currentTask)
      # We managed to steal a task, cancel sleep
      ctx.taskpool.globalBackoff.cancelSleep()
      # Theft successful, there might be more work for idle threads, wake one
      # cancelSleep must be done before as wake has an optimization
      # to not notify when a thread is sleepy
      ctx.taskpool.globalBackoff.wake()
      stolenTask.runTask()
    elif ctx.signal.terminate.load(moAcquire):
      # 4. Taskpool has no more tasks and we were signaled to terminate
      ctx.taskpool.globalBackoff.cancelSleep()
      debug: log("Worker %2d: eventLoop 4 - terminated\n", ctx.id)
      break
    else:
      # 5. Park the thread until a new task enters the taskpool
      debug: log("Worker %2d: eventLoop 5.a - sleeping\n", ctx.id)
      ctx.taskpool.globalBackoff.sleep(ticket)
      debug: log("Worker %2d: eventLoop 5.b - waking\n", ctx.id)

# Tasking
# ---------------------------------------------

proc RootTask(args: pointer) =
  discard

template isRootTask(task: TaskNode): bool {.used.} =
  task.callback == RootTask

proc forceFuture*[T](fv: Flowvar[T], parentResult: var T) =
  ## Eagerly complete an awaited Flowvar

  template ctx: untyped = workerContext

  template isFutReady(): untyped =
    fv.tryComplete(parentResult)

  if isFutReady():
    return

  # External thread: no Chase-Lev deque and no steal peers available.
  # Busy-wait while pool workers make progress on the task.
  if ctx.taskpool.isNil:
    while not isFutReady():
      cpuRelax()
    return

  ## 1. Process all the children of the current tasks.
  ##    This ensures that we can give control back ASAP.
  debug: log("Worker %2d: sync 1 - searching task from local deque\n", ctx.id)
  while (var taskNode = ctx.taskDeque[].pop(); not taskNode.isNil):
    if taskNode.parent != ctx.currentTask:
      debug: log("Worker %2d: sync 1 - skipping non-direct descendant task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, taskNode, taskNode.parent, ctx.currentTask)
      ctx.schedule(taskNode, forceWake = true) # reschedule task and wake a sibling to take it over.
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
      # Theft successful, there might be more work for idle threads, wake one
      ctx.taskpool.globalBackoff.wake()
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

proc syncAll*(tp: Taskpool) =
  ## Blocks until all pending tasks are completed.
  ## This MUST only be called from the root scope that created the taskpool.
  ##
  ## All external threads MUST stop calling spawn before syncAll is called.
  ## There is an inherent race between the termination check and the injection
  ## queue: a task pushed after syncAll begins its final drain may not be
  ## waited for.
  template ctx: untyped = workerContext

  debugTermination:
    log(">>> Worker %2d enters barrier <<<\n", ctx.id)

  preCondition: ctx.id == 0
  preCondition: ctx.currentTask.isRootTask()

  # Empty all tasks
  while true:
    # 1. Empty local tasks
    debug: log("Worker %2d: syncAll 1 - searching task from local deque\n", ctx.id)
    while (var taskNode = ctx.taskDeque[].pop(); not taskNode.isNil):
      debug: log("Worker %2d: syncAll 1 - running task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, taskNode, taskNode.parent, ctx.currentTask)
      taskNode.runTask()

    # Drain injection queue into local deque so externally submitted tasks
    # are not left stranded while we wait for the pool to go idle.
    ctx.drainInjectionQueue()

    if (var taskNode = ctx.taskDeque[].pop(); not taskNode.isNil):
      # 2. Local queue contains injected tasks.
      debug: log("Worker %2d: syncAll 2 - running injected task 0x%.08x\n", ctx.id, taskNode)
      ctx.taskpool.globalBackoff.wake()
      taskNode.runTask()
    elif (var taskNode = ctx.trySteal(); not taskNode.isNil):
      # 3. We stole some task
      debug: log("Worker %2d: syncAll 3 - stole task 0x%.08x (parent 0x%.08x, current 0x%.08x)\n", ctx.id, taskNode, taskNode.parent, ctx.currentTask)
      # Theft successful, there might be more work for idle threads, wake one
      ctx.taskpool.globalBackoff.wake()
      taskNode.runTask()
    elif tp.globalBackoff.getNumWaiters() == (0'i32, int32(tp.numThreads - 1)):
      # 4. all threads besides the current are parked (and none are
      #    in pre-sleep, so none can still grab a task and create work)
      debugTermination:
        log("Worker %2d: syncAll 4 - termination, all other threads sleeping\n", ctx.id)
      break
    else:
      # 5. We don't park as there is no notif for task completion
      cpuRelax()

  debugTermination:
    log(">>> Worker %2d leaves barrier <<<\n", ctx.id)

# Runtime
# ---------------------------------------------

proc new*(T: type Taskpool, numThreads = countProcessors()): T {.raises: [CatchableError].} =
  ## Initialize a threadpool that manages `numThreads` threads.
  ## Default to the number of logical processors available.

  type TpObj = typeof(default(Taskpool)[])
  # Event notifier requires an extra 64 bytes for alignment
  var tp = tp_allocAligned(TpObj, sizeof(TpObj) + 64, 64)

  tp.barrier.init(numThreads.int32)
  tp.globalBackoff.initialize()
  tp.numThreads = numThreads
  tp.injectionQueue.init()
  tp.workerDeques = tp_allocArrayAligned(ChaseLevDeque[TaskNode], numThreads, alignment = 64)
  tp.workers = tp_allocArrayAligned(Thread[(Taskpool, WorkerID)], numThreads, alignment = 64)
  tp.workerSignals = tp_allocArrayAligned(Signal, numThreads, alignment = 64)

  # Setup master thread
  workerContext.id = 0
  workerContext.taskpool = tp

  # Start worker threads
  for i in 1 ..< numThreads:
    createThread(tp.workers[i], workerEntryFn, (tp, WorkerID(i)))

  # Root worker
  setupWorker()

  # Root task, this is a sentinel task that is never called.
  workerContext.currentTask =
    TaskNode.new(parent = nil, callback = RootTask, args = nil)

  # Wait for the child threads
  discard tp.barrier.wait()
  return tp

proc cleanup(tp: var Taskpool) =
  ## Cleanup all resources allocated by the taskpool
  preCondition: workerContext.currentTask.isRootTask()

  for i in 1 ..< tp.numThreads:
    joinThread(tp.workers[i])

  tp.workerSignals.tp_freeAligned()
  tp.workers.tp_freeAligned()
  tp.workerDeques.tp_freeAligned()
  `=destroy`(tp.globalBackoff)
  tp.barrier.delete()

  tp.tp_freeAligned()

proc shutdown*(tp: var Taskpool) =
  ## Wait until all tasks are processed and then shutdown the taskpool
  preCondition: workerContext.currentTask.isRootTask()
  tp.syncAll()

  # Signal termination to all threads
  for i in 0 ..< tp.numThreads:
    tp.workerSignals[i].terminate.store(true, moRelease)

  tp.globalBackoff.wakeAll()

  # 1 matching barrier in worker_entry_fn
  discard tp.barrier.wait()

  teardownWorker()
  tp.cleanup()

  # Dealloc dummy task
  workerContext.currentTask.c_free()

# Task parallelism
# ---------------------------------------------
{.pop.} # raises:[]

macro spawn*(tp: Taskpool, fnCall: typed): untyped =
  ## Spawns the input function call asynchronously, potentially on another thread of execution.
  ## Safe to call from any thread, including threads that are not part of the taskpool.
  ##
  ## If the function calls returns a result, spawn will wrap it in a Flowvar.
  ## You can use `sync` to block the current thread and extract the asynchronous result from the flowvar.
  ## You can use `isReady` to check if result is available and if subsequent
  ## `spawn` returns immediately.
  ##
  ## Tasks are processed approximately in Last-In-First-Out (LIFO) order
  fnCall.expectKind(nnkCall)

  let fn = fnCall[0]

  if hasClosure(fn):
    error("Closure calls cannot be spawned", fnCall)

  let
    argsTup = nnkTupleConstr.newTree()
      # Tuple for collecting function arguments and storage for return value
    fwdCall = nnkCall.newTree(fn)
      # same as fnCall, but with parameters forwarded from the closure environment
    env = genSym(nskTemp, "env") # closure environment

  result = newStmtList()

  # A task is similar to a closure proc but with the closure environment
  # allocated in shared memory.
  #
  # The closure environment is a tuple that holds:
  #
  # * runtime parameters, ie those that are not constants / literals / etc
  # * Flowvar for return value, if any
  #
  # Start with the runtime parameters:
  var j = 0
  for i in 1 ..< fnCall.len:
    let p = fnCall[i]
    if isStatic(p):
      # Literals can be passed as-is to the callee
      fwdCall.add p
    else:
      # Non-literals must be copied to shared memory - add them to a tuple
      # then extract them from the tuple on the calling side
      let jl = newLit(j)
      j += 1

      when sharedHeap:
        # In ORC, we can isolate values and move them between tasks
        argsTup.add quote do:
          isolate(`p`)
        fwdCall.add quote do:
          extract(`env`[][`jl`])
      else:
        # `move` to support move-only types in refc
        argsTup.add p
        let hasClosure = newLit(p.kind == nnkSym and hasClosure(p))

        # `refc` uses a thread-local heap - therefore, anything heap-allocated
        # cannot traverse thread boundaries, even if it's isolated - since
        # tasks are likely to end up on a different thread, block their
        # construction here.
        fwdCall.add quote do:
          when `hasClosure` or not supportsThreadMove(typeof(`p`)):
            {.
              error:
                "Garbage-collected types (seq, string, ref, closures) cannot be used as task arguments: " &
                $(typeof(`p`))
            .}

          move(`env`[][`jl`])
  let
    envp = genSym(nskParam, "envp")
      # closure environment, untyped pointer version in `fwdCall`
    retType = fn.getImpl().params()[0]
    argsTy = genSym(nskType, "ArgsType")

    (fut, body) =
      if retType.kind != nnkEmpty:
        # if the call returns a value, create a `Flowvar` which can transfer
        # the result back to the caller, similar to a Future.
        #
        # The Flowvar is added to the argument tuple, similar to the function
        # arguments.
        let
          fut = genSym(nskTemp, "fut")
          retIdx = newLit(argsTup.len)

          body = quote:
            let `env` = cast[ptr `argsTy`](`envp`)
            readyWith(`env`[][`retIdx`], `fwdCall`)

        argsTup.add fut

        result.add quote do:
          let `fut` = newFlowVar(type `retType`)

        (fut, body)
      elif argsTup.len > 0:
        let body = quote:
          let `env` = cast[ptr `argsTy`](`envp`)
          `fwdCall`

        (newEmptyNode(), body)
      else:
        (newEmptyNode(), fwdCall)

    args =
      if argsTup.len > 0:
        let args = genSym(nskTemp, "args")

        # Allocate the tuple that will hold the arguments that need to be passed
        # to the task, potentially on a different thread
        result.add quote do:
          type `argsTy` = typeof(`argsTup`)
          let `args` = tp_alloc(`argsTy`, zero = true)
          `args`[] = `argsTup`

        # ... and free it after the task has finished running - because we moved
        # the values out of the environment when calling the function, there's
        # nothing left to process
        body.add quote do:
          wasMoved(`env`[])
          tp_free(`env`)
        args
      else:
        newNilLit()
    taskFn = genSym(nskProc, $fn & "_task")
      # Function that calls `fn` inside within the taskpool thread

  result.add quote do:
    proc `taskFn`(`envp`: pointer) {.nimcall, gcsafe, raises: [].} =
      `body`

    if workerContext.taskpool != `tp`:
      let taskNode = TaskNode.new(nil, `taskFn`, `args`)
      submitTask(`tp`, taskNode)
    else:
      let taskNode = TaskNode.new(workerContext.currentTask, `taskFn`, `args`)
      schedule(workerContext, taskNode)

    `fut`

  # Wrap in a block for namespacing
  result = nnkBlockStmt.newTree(newEmptyNode(), result)
  # echo result.toStrLit()
