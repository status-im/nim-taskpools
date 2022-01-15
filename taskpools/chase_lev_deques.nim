# Nim-Taskpools
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# chase_lev_deques.nim
# --------------------
# This file implements a Chase-Lev deque
# This is a single-consumer multi-consumer concurrent queue
# for work-stealing schedulers.
#
# Papers:
# - Dynamic Circular Work-Stealing Deque
#   David Chase, Yossi Lev, 1993
#   https://www.dre.vanderbilt.edu/~schmidt/PDF/work-stealing-dequeue.pdf
#
# - Correct and Efficient Work-Stealing for Weak Memory Models
#   Nhat Minh Lê, Antoniu Pop, Albert Cohen, Francesco Zappa Nardelli, 2013
#   https://fzn.fr/readings/ppopp13.pdf
#
# We straight translate the second paper which includes formal proofs of correctness,
# and uses modern C++11 code.
#
# A Chase-lev dequeue implements the following push, pop, steal.
#
#     top                                            bottom
#               ---------------------------------
#               |         |          |          | <- push()
#  steal()   <- | Task 0  |  Task 1  |  Task 2  | -> pop()
#  any thread   |         |          |          |    owner-only
#               ---------------------------------
#
# To reduce contention, stealing is done on the opposite end from push/pop
# so that there is a race only for the very last task.

{.push raises: [].}          # Ensure no exceptions can happen
{.push overflowChecks: off.} # We don't want exceptions (for Defect) in a multithreaded context
                             # but we don't to deal with underflow of unsigned int either
                             # say "if a < b - c" with c > b

import
  system/ansi_c,
  std/[locks, typetraits, atomics],
  ./instrumentation/[contracts, loggers],
  ./primitives/allocs

type
  Buf[T] = object
    ## Backend buffer of a ChaseLevDeque
    ## `capacity` MUST be a power of 2

    # Unused. There is no memory reclamation scheme.
    prev: ptr Buf[T]

    capacity: int
    mask: int        # == capacity-1 implies (i and mask) == (i mod capacity)
    rawBuffer: UncheckedArray[Atomic[T]]

  ChaseLevDeque*[T] = object
    ## This implements a lock-free, growable, work-stealing deque.
    ## The owning thread enqueues and dequeues at the bottom
    ## Foreign threads steal at the top.
    ##
    ## There is no memory reclamation scheme for simplicity.
    top {.align: 64.}: Atomic[int]
    bottom: Atomic[int]
    buf: Atomic[ptr Buf[T]]
    garbage: ptr Buf[T]

func isPowerOfTwo(n: int): bool {.inline.} =
  (n and (n - 1)) == 0 and (n != 0)

proc newBuf(T: typedesc, capacity: int): ptr Buf[T] =
  # Tasks have a destructor
  # static:
  #   doAssert supportsCopyMem(T), $T & " must be a (POD) plain-old-data type: no seq, string, ref."

  preCondition: capacity.isPowerOfTwo()

  result = tp_allocUnchecked(
    Buf[T],
    2*sizeof(int) + sizeof(T)*capacity,
    zero = true
  )

  # result.prev = nil
  result.capacity = capacity
  result.mask = capacity - 1
  # result.rawBuffer.addr.zeroMem(sizeof(T)*capacity)

proc `[]=`[T](buf: var Buf[T], index: int, item: T) {.inline.} =
  buf.rawBuffer[index and buf.mask].store(item, moRelaxed)

proc `[]`[T](buf: var Buf[T], index: int): T {.inline.} =
  result = buf.rawBuffer[index and buf.mask].load(moRelaxed)

proc grow[T](deque: var ChaseLevDeque[T], buf: var ptr Buf[T], top, bottom: int) {.inline.} =
  ## Double the buffer size
  ## bottom is the last item index
  ##
  ## To handle race-conditions the current "top", "bottom" and "buf"
  ## have to be saved before calling this procedure.
  ## It reads and writes the "deque.buf", "deque.garbage" and "deque.garbageUsed"

  # Read -> Copy -> Update
  var tmp = newBuf(T, buf.capacity*2)
  for i in top ..< bottom:
    tmp[][i] = buf[][i]

  buf.prev = deque.garbage
  deque.garbage = buf
  # publish globally
  deque.buf.store(tmp, moRelaxed)
  # publish locally
  swap(buf, tmp)

# Public API
# ---------------------------------------------------

proc init*[T](deque: var ChaseLevDeque[T], initialCapacity: int) =
  ## Initializes a new Chase-lev work-stealing deque.
  deque.reset()
  deque.buf.store(newBuf(T, initialCapacity), moRelaxed)

proc teardown*[T](deque: var ChaseLevDeque[T]) =
  ## Teardown a Chase-lev work-stealing deque.
  var node = deque.garbage
  while node != nil:
    let tmp = node.prev
    c_free(node)
    node = tmp
  c_free(deque.buf.load(moRelaxed))

proc push*[T](deque: var ChaseLevDeque[T], item: T) =
  ## Enqueue an item at the bottom
  ## The item should not be used afterwards.

  let # Handle race conditions
    b = deque.bottom.load(moRelaxed)
    t = deque.top.load(moAcquire)
  var a = deque.buf.load(moRelaxed)

  if b-t > a.capacity - 1:
    # Full queue
    deque.grow(a, t, b)

  a[][b] = item
  fence(moRelease)
  deque.bottom.store(b+1, moRelaxed)

proc pop*[T](deque: var ChaseLevDeque[T]): T =
  ## Deque an item at the bottom

  let # Handle race conditions
    b = deque.bottom.load(moRelaxed) - 1
    a = deque.buf.load(moRelaxed)

  deque.bottom.store(b, moRelaxed)
  fence(moSequentiallyConsistent)
  var t = deque.top.load(moRelaxed)

  if t <= b:
    # Non-empty queue.
    result = a[][b]
    if t == b:
      # Single last element in queue.
      if not compare_exchange(deque.top, t, t+1, moSequentiallyConsistent, moRelaxed):
        # Failed race.
        result = default(T)
      deque.bottom.store(b+1, moRelaxed)
  else:
    # Empty queue.
    result = default(T)
    deque.bottom.store(b+1, moRelaxed)

proc steal*[T](deque: var ChaseLevDeque[T]): T =
  ## Deque an item at the top
  var t = deque.top.load(moAcquire)
  fence(moSequentiallyConsistent)
  let b = deque.bottom.load(moAcquire)
  result = default(T)

  if t < b:
    # Non-empty queue.
    let a = deque.buf.load(moConsume)
    result = a[][t]
    if not compare_exchange(deque.top, t, t+1, moSequentiallyConsistent, moRelaxed):
      # Failed race.
      return default(T)
