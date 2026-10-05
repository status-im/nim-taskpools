# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  std/[atomics, os],
  unittest2,
  ./utils,
  ../taskpools

# Per-task backoff: a thread awaiting a Flowvar with no work left to do parks on
# the awaited task itself and is woken by the thread that completes it.
#
# These tests make the awaiting thread park deterministically: the awaited task
# is picked up by another thread and cannot complete until a third party opens a
# gate, by which time the awaiting thread has run out of work. A lost wakeup
# does not fail these tests, it hangs them - it is a liveness bug, invisible to
# ThreadSanitizer.

var
  tp: Taskpool
  gate: Atomic[bool]
  running: Atomic[bool]

proc gated(): int =
  ## Occupies a worker until the gate opens.
  running.store(true, moRelease)
  while not gate.load(moAcquire):
    cpuRelax()
  42

proc openGate(delayMs: int) {.thread.} =
  sleep(delayMs)
  gate.store(true, moRelease)

proc awaitGated(tp: Taskpool) {.thread.} =
  ## Spawns and awaits from a thread that is not managed by the taskpool.
  let fv = tp.spawn gated()
  doAssert sync(fv) == 42

suite "Per-task backoff":
  setup:
    tp = Taskpool.new(numThreads())
    gate.store(false, moRelease)
    running.store(false, moRelease)

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "a worker parks until the awaited task completes":
    let fv = tp.spawn gated()
    # Wait until another worker picked up the task: the root thread is then out
    # of work and parks in `sync` instead of running the task itself.
    while not running.load(moAcquire):
      cpuRelax()
    var opener: Thread[int]
    createThread(opener, openGate, 100)
    check sync(fv) == 42
    joinThread(opener)

  test "an external thread parks until the awaited task completes":
    var awaiter: Thread[Taskpool]
    createThread(awaiter, awaitGated, tp)
    while not running.load(moAcquire):
      cpuRelax()
    sleep(100) # Let the awaiting thread reach the park
    gate.store(true, moRelease)
    joinThread(awaiter)

  test "park and completion race, 1000 rounds":
    # No delay here: the gate opens while the awaiting thread is on its way to
    # park. This races publishing "a waiter is sleeping" against the completion
    # of the task, the case a missing barrier would turn into a lost wakeup.
    for _ in 0 ..< 1000:
      gate.store(false, moRelease)
      running.store(false, moRelease)
      let fv = tp.spawn gated()
      while not running.load(moAcquire):
        cpuRelax()
      gate.store(true, moRelease)
      check sync(fv) == 42

# Stress
# ---------------------------------------------------------------------------
#
# The tests above pin the mechanism down with a gate, so the awaiting thread is
# guaranteed to park. The ones below drive the same paths under contention,
# where parking is incidental: whether a given await parks depends on whether a
# thief got to the task first. They cover the two failure modes of the handover
# in `flowvars.nim`, both of which manifest as a hang rather than a wrong value:
#
# - a lost wakeup: the runner completes the task without seeing the waiter that
#   registered concurrently, and nobody ever wakes it;
# - a lost ownership transfer: the waiter registers *after* the runner already
#   released the node, and its `fetchAdd` clobbers `canBeFreed`, leaving
#   `cleanup` spinning on a flag that will never be set again.
#
# Both need the waiter's registration and the task's completion to land within
# a few instructions of each other, so the tests sweep the task's runtime
# rather than fixing it.

var executed: Atomic[int]

proc counted(spins: int): int =
  ## A task with a tunable runtime. Sweeping `spins` walks the completion of the
  ## awaited task across the awaiting thread's whole path to the park.
  for _ in 0 ..< spins:
    cpuRelax()
  1

proc bump() =
  ## Result-less task: the runner owns and frees the node, no handover.
  discard executed.fetchAdd(1, moRelaxed)

proc chain(depth: int): int =
  ## Each level spawns exactly one child then awaits it. A level that still has
  ## its child runs it inline; a level whose child was stolen has an empty deque
  ## and nothing to steal, so it parks on it. Both happen along the chain.
  ##
  ## Keep the depth well under 500: a level that runs its child inline nests
  ## four frames deep, and `nimCallDepthLimit` caps that at 2000 in any build
  ## with stack traces (which is every build the nimble test task produces).
  if depth == 0:
    return 0
  let fv = tp.spawn chain(depth - 1)
  sync(fv) + 1

proc tree(depth: int): int =
  ## Fork-join. Both children are spawned before either is awaited, so the
  ## awaiting thread reaches the park only after draining its own deque -
  ## the invariant that keeps a parked thread from stranding tasks behind it.
  if depth == 0:
    return 1
  let
    left = tp.spawn tree(depth - 1)
    right = tp.spawn tree(depth - 1)
  sync(left) + sync(right)

type
  StressCtx = tuple
    tp: Taskpool
    rounds: int

proc extAwaiter(ctx: StressCtx) {.thread.} =
  ## An external thread has no deque and no peer to steal from, so every await
  ## goes straight to the park: each round is a full park/wake cycle.
  for i in 0 ..< ctx.rounds:
    let fv = ctx.tp.spawn counted(i mod 64)
    doAssert sync(fv) == 1
    discard executed.fetchAdd(1, moRelaxed)

proc extSubmitter(ctx: StressCtx) {.thread.} =
  ## Fire-and-forget injections landing while workers are parked on futures.
  ## A parked worker does not drain the injection queue, so these tasks are only
  ## picked up once the pool comes back up for air.
  for _ in 0 ..< ctx.rounds:
    ctx.tp.spawn bump()

var
  handoff: Flowvar[int]
  handoffFilled: Atomic[bool]

proc handoffAwaiter(rounds: int) {.thread.} =
  ## Awaits a future created by another thread. The waiter is neither the task's
  ## creator nor a thread that ever had it in a deque, so it can only park: it
  ## has no way to run the task itself, whoever ends up running it must wake it.
  for _ in 0 ..< rounds:
    while not handoffFilled.load(moAcquire):
      cpuRelax()
    doAssert sync(move(handoff)) == 1
    handoffFilled.store(false, moRelease)

# Reverse-order await
# ---------------------------------------------------------------------------

proc reverseInner(spins: int): int =
  ## Awaited first. Spawns a fire-and-forget grandchild, then returns without
  ## awaiting it, leaving it queued with *this* task as its parent.
  tp.spawn bump()
  for _ in 0 ..< spins:
    cpuRelax()
  2

proc reverseOuter(spins: int): int =
  ## Spawns two children and awaits them in the opposite order of their spawn.
  let a = tp.spawn counted(spins)
  let b = tp.spawn reverseInner(spins)
  let rb = sync(b)
  let ra = sync(a)
  ra + rb # counted -> 1, reverseInner -> 2

suite "Per-task backoff stress":
  setup:
    tp = Taskpool.new(numThreads())
    executed.store(0, moRelease)

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "park vs completion sweep; 256 runtimes x 64 rounds":
    # The awaiting thread hands the task to a thief (by idling just long enough
    # for one to steal it), then races that thief to the park. `spins` moves the
    # completion point across the register-waiter / set-completed / hand-over
    # window one step at a time.
    for spins in 0 ..< 256:
      for _ in 0 ..< 64:
        let fv = tp.spawn counted(spins)
        for _ in 0 ..< 64:
          cpuRelax() # give a thief time to take the task
        check sync(fv) == 1

  test "many live futures awaited out of order":
    # Keeps a crowd of nodes alive at once, each in a different phase of the
    # handover: some completed and waiting to be freed, some still running, some
    # not yet picked up. Awaiting the odd indices first means the awaited node is
    # rarely the one on top of our own deque, so the await rarely resolves inline.
    const rounds = 300
    let n = numThreads() * 16
    for _ in 0 ..< rounds:
      var futs = newSeq[Flowvar[int]](n)
      for i in 0 ..< n:
        futs[i] = tp.spawn counted((i * 7) mod 96)
      var total = 0
      for i in countup(1, n - 1, 2):
        total += sync(move(futs[i]))
      for i in countup(0, n - 1, 2):
        total += sync(move(futs[i]))
      check total == n

  test "a future awaited by a thread other than its creator; 5000 rounds":
    # The root spawns but never awaits: it leaves the task in its own deque and
    # spins. Only a thief can complete it, and only the completion can release
    # the parked awaiter, so every round is a wake that nobody else can supply.
    const rounds = 5000
    handoffFilled.store(false, moRelease)
    var awaiter: Thread[int]
    createThread(awaiter, handoffAwaiter, rounds)
    for _ in 0 ..< rounds:
      handoff = tp.spawn counted(0)
      handoffFilled.store(true, moRelease)
      while handoffFilled.load(moAcquire):
        cpuRelax()
    joinThread(awaiter)

  test "dependency chain; depth=200 x 500 rounds":
    for _ in 0 ..< 500:
      check sync(tp.spawn chain(200)) == 200

  test "reverse-order await meets a grandchild; 128 runtimes x 16 rounds":
    # Pathological case that hit the parent-mismatch branch in sync.
    const rounds = 16
    for spins in 0 ..< 128:
      for _ in 0 ..< rounds:
        check sync(tp.spawn reverseOuter(spins)) == 3
    tp.syncAll()
    check executed.load(moAcquire) == 128 * rounds

  test "fork-join tree; depth=12 x 50 rounds":
    for _ in 0 ..< 50:
      check sync(tp.spawn tree(12)) == 1 shl 12

  test "external threads park on every await; 4 threads x 20_000 rounds":
    const
      externalThreads = 4
      rounds = 20_000
    var threads = newSeq[Thread[StressCtx]](externalThreads)
    for t in mitems(threads):
      createThread(t, extAwaiter, (tp, rounds))
    joinThreads(threads)
    check executed.load(moAcquire) == externalThreads * rounds

  test "workers parked on futures while tasks are injected":
    # Two independent liveness claims at once: the injected tasks must still be
    # drained even though every worker that parks stops looking at the injection
    # queue, and the chains must still complete while the queue churns.
    const
      externalThreads = 4
      rounds = 50_000
      chains = 200
    var threads = newSeq[Thread[StressCtx]](externalThreads)
    for t in mitems(threads):
      createThread(t, extSubmitter, (tp, rounds))
    for _ in 0 ..< chains:
      check sync(tp.spawn chain(100)) == 100
    joinThreads(threads)
    tp.syncAll()
    check executed.load(moAcquire) == externalThreads * rounds

suite "Per-task backoff stress, oversubscribed":
  # A 2-worker pool: far more awaits than workers, so an await that cannot be
  # served inline parks almost every time instead of finding something to steal.
  setup:
    tp = Taskpool.new(2)
    executed.store(0, moRelease)

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "dependency chain; depth=200 x 500 rounds":
    for _ in 0 ..< 500:
      check sync(tp.spawn chain(200)) == 200

  test "fork-join tree; depth=12 x 50 rounds":
    for _ in 0 ..< 50:
      check sync(tp.spawn tree(12)) == 1 shl 12

  test "8 external threads await on a 2-worker pool; 10_000 rounds each":
    const
      externalThreads = 8
      rounds = 10_000
    var threads = newSeq[Thread[StressCtx]](externalThreads)
    for t in mitems(threads):
      createThread(t, extAwaiter, (tp, rounds))
    joinThreads(threads)
    check executed.load(moAcquire) == externalThreads * rounds

suite "Per-task backoff, section-1 parent mismatch":
  # Pins the parent-mismatch branch down deterministically, the way the first
  # suite pins parking down: a 2-worker pool where the only non-root worker is
  # held on the gate, so nothing the root spawns afterwards can be stolen and the
  # scheduling is forced.
  setup:
    tp = Taskpool.new(2)
    gate.store(false, moRelease)
    running.store(false, moRelease)
    executed.store(0, moRelease)

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "a non-descendant task in sync is rescheduled":
    # The grandchild is on our deque with a parent that is not our current task,
    # so section 1 hands it back to the pool instead of running it. What must
    # hold is that it is still *somewhere*: a section 1 that broke out without
    # rescheduling would leak the node, and no drain would ever find it again.
    let a = tp.spawn gated()
    while not running.load(moAcquire):
      cpuRelax()
    let b = tp.spawn reverseInner(0)
    check sync(b) == 2
    var opener: Thread[int]
    createThread(opener, openGate, 100)
    check sync(a) == 42
    joinThread(opener)
    tp.syncAll()
    check executed.load(moAcquire) == 1
