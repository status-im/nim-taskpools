# taskpools
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# event_notifier.nim
# ------------------
# This file implements an event notifier.
# It allows putting idle threads to sleep or waking them up.

# Design
# Currently it is a shared lock + condition variable (a.k.a. a semaphore)
#
# In the future an eventcount might be considered, an event count significantly
# reduces scheduler overhead by removing lock acquisition from critical path.
# See overview and implementations at
# https://gist.github.com/mratsim/04a29bdd98d6295acda4d0677c4d0041
#
# Weave "one event-notifier per thread" further reduces overhead
# but requires the threadpool to be message-passing based.
# https://github.com/mratsim/weave/blob/a230cce98a8524b2680011e496ec17de3c1039f2/weave/cross_thread_com/event_notifiers.nim

import
  std/locks,
  ./instrumentation/contracts

type
  EventNotifier* = object
    ## This data structure allows threads to be parked when no events are pending
    ## and woken up when a new event is.
    # Lock must be aligned to a cache-line to avoid false-sharing.
    lock{.align: 64.}: Lock
    cond: Cond
    parked: int
    signals: int

{.push raises: [AssertionDefect].} # Ensure no exceptions can happen
{.push overflowChecks: off.}       # We don't want exceptions (for Defect) in a multithreaded context
                                   # but we don't to deal with underflow of unsigned int either
                                   # say "if a < b - c" with c > b

func initialize*(en: var EventNotifier) {.inline.} =
  ## Initialize the event notifier
  en.lock.initLock()
  en.cond.initCond()
  en.parked = 0
  en.signals = 0

func `=destroy`*(en: var EventNotifier) {.inline.} =
  en.cond.deinitCond()
  en.lock.deinitLock()

func `=`*(dst: var EventNotifier, src: EventNotifier) {.error: "An event notifier cannot be copied".}
func `=sink`*(dst: var EventNotifier, src: EventNotifier) {.error: "An event notifier cannot be moved".}

proc park*(en: var EventNotifier) {.inline.} =
  ## Wait until we are signaled of an event
  ## Thread is parked and does not consume CPU resources
  en.lock.acquire()

  if en.signals > 0:
    en.signals -= 1
    en.lock.release()
    return

  en.parked += 1
  while en.signals == 0: # handle spurious wakeups
    en.cond.wait(en.lock)
  en.parked -= 1
  en.signals -= 1

  postCondition: en.signals >= 0
  en.lock.release()

proc notify*(en: var EventNotifier) {.inline.} =
  ## Unpark a thread if any is available
  en.lock.acquire()

  if en.parked > 0:
    en.signals += 1
    en.cond.signal()

  en.lock.release()

proc getParked*(en: var EventNotifier): int {.inline.} =
  ## Get the number of parked thread
  en.lock.acquire()
  result = en.parked
  en.lock.release()

{.pop.} # overflowChecks
{.pop.} # raises: [AssertionDefect]
