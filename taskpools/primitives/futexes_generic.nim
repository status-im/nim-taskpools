# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[atomics, locks]
export MemoryOrder

type
  Futex* = object
    value: Atomic[uint32]
    lock: Lock
    cond: Cond

proc initialize*(futex: var Futex) {.inline.} =
  futex.value.store(0, moRelaxed)
  initLock(futex.lock)
  initCond(futex.cond)

proc teardown*(futex: var Futex) {.inline.} =
  futex.value.store(0, moRelaxed)
  deinitLock(futex.lock)
  deinitCond(futex.cond)

proc load*(futex: var Futex, order: MemoryOrder): uint32 {.inline.} =
  futex.value.load(order)

proc store*(futex: var Futex, value: uint32, order: MemoryOrder) {.inline.} =
  futex.value.store(value, order)

proc increment*(futex: var Futex, value: uint32, order: MemoryOrder): uint32 {.inline.} =
  futex.value.fetchAdd(value, order)

proc wait*(futex: var Futex, expected: uint32) {.inline.} =
  withLock(futex.lock):
    if futex.value.load(moAcquire) == expected:
      wait(futex.cond, futex.lock)

proc wake*(futex: var Futex) {.inline.} =
  withLock(futex.lock):
    signal(futex.cond)

proc wakeAll*(futex: var Futex) {.inline.} =
  withLock(futex.lock):
    broadcast(futex.cond)
