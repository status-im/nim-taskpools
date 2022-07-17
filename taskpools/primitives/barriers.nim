# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when defined(windows):
  import ./barriers_windows
  import os

  type SyncBarrier* = SynchronizationBarrier

  proc init*(syncBarrier: var SyncBarrier, threadCount: int) {.inline.} =
    ## Initialize a synchronization barrier that will block ``threadCount`` threads
    ## before release.
    if threadCount <= 0:
      raiseOSError(OSErrorCode(87)) # ERROR_INVALID_PARAMETER

    let err {.used.} = InitializeSynchronizationBarrier(syncBarrier, threadCount, -1)
    if err != 1:
      raiseOSError(osLastError())

  proc wait*(syncBarrier: var SyncBarrier): bool {.inline.} =
    ## Blocks thread at a synchronization barrier.
    ## Returns true for one of the threads (the last one on Windows, undefined on Posix)
    ## and false for the others.
    result = bool EnterSynchronizationBarrier(syncBarrier, SYNCHRONIZATION_BARRIER_FLAGS_NO_DELETE)

  proc delete*(syncBarrier: sink SyncBarrier) {.inline.} =
    ## Deletes a synchronization barrier.
    ## This assumes no race between waiting at a barrier and deleting it,
    ## and reuse of the barrier requires initialization.
    DeleteSynchronizationBarrier(syncBarrier.addr)

else:
  import ./barriers_posix
  import os

  from posix import EINVAL

  type SyncBarrier* = Pthread_barrier

  proc init*(syncBarrier: var SyncBarrier, threadCount: int) {.inline.} =
    ## Initialize a synchronization barrier that will block ``threadCount`` threads
    ## before release.
    if threadCount <= 0:
      raiseOSError(OSErrorCode(EINVAL))

    when sizeof(int) > sizeof(cuint):
      if threadCount > cuint.high.int:
        raiseOSError(OSErrorCode(EINVAL))

    let err = pthread_barrier_init(syncBarrier, nil, cuint threadCount)
    if err != 0:
      raiseOSError(OSErrorCode(err))

  proc wait*(syncBarrier: var SyncBarrier): bool {.inline.} =
    ## Blocks thread at a synchronization barrier.
    ## Returns true for one of the threads (the last one on Windows, undefined on Posix)
    ## and false for the others.
    let res = pthread_barrier_wait(syncBarrier)
    if res != PTHREAD_BARRIER_SERIAL_THREAD and res < 0:
      raiseOSError(OSErrorCode(res))

    res == PTHREAD_BARRIER_SERIAL_THREAD

  proc delete*(syncBarrier: sink SyncBarrier) {.inline.} =
    ## Deletes a synchronization barrier.
    ## This assumes no race between waiting at a barrier and deleting it,
    ## and reuse of the barrier requires initialization.
    let err {.used.} = pthread_barrier_destroy(syncBarrier)
    if err < 0:
      raiseOSError(OSErrorCode(err))
