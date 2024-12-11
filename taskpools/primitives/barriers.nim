# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe, inline.}

import os

when defined(windows):
  import ./barriers_windows

  type SyncBarrier* = SynchronizationBarrier

  proc init*(syncBarrier: var SyncBarrier, threadCount: range[0'i32..high(int32)]) {.raises: [OSError].} =
    ## Initialize a synchronization barrier that will block ``threadCount`` threads
    ## before release.
    if InitializeSynchronizationBarrier(syncBarrier, threadCount, -1) != 1:
      raiseOSError(osLastError())

  proc wait*(syncBarrier: var SyncBarrier): bool =
    ## Blocks thread at a synchronization barrier.
    ## Returns true for one of the threads (the last one on Windows, undefined on Posix)
    ## and false for the others.
    bool EnterSynchronizationBarrier(syncBarrier, SYNCHRONIZATION_BARRIER_FLAGS_NO_DELETE)

  proc delete*(syncBarrier: sink SyncBarrier) =
    ## Deletes a synchronization barrier.
    ## This assumes no race between waiting at a barrier and deleting it,
    ## and reuse of the barrier requires initialization.
    DeleteSynchronizationBarrier(syncBarrier.addr)

else:
  import ./barriers_posix

  type SyncBarrier* = PthreadBarrier

  proc init*(syncBarrier: var SyncBarrier, threadCount: range[0'i32..high(int32)]) {.raises: [OSError].} =
    ## Initialize a synchronization barrier that will block ``threadCount`` threads
    ## before release.
    let err = pthread_barrier_init(syncBarrier, nil, cuint threadCount)
    if err != 0:
      raiseOSError(OSErrorCode(err))

  proc wait*(syncBarrier: var SyncBarrier): bool =
    ## Blocks thread at a synchronization barrier.
    ## Returns true for one of the threads (the last one on Windows, undefined on Posix)
    ## and false for the others.
    ##
    # https://pubs.opengroup.org/onlinepubs/009696899/functions/pthread_barrier_wait.html
    let res = pthread_barrier_wait(syncBarrier)
    assert res == 0 or res == PTHREAD_BARRIER_SERIAL_THREAD, osErrorMsg(OSErrorCode(res))
    res == PTHREAD_BARRIER_SERIAL_THREAD

  proc delete*(syncBarrier: sink SyncBarrier) =
    ## Deletes a synchronization barrier.
    ## This assumes no race between waiting at a barrier and deleting it,
    ## and reuse of the barrier requires initialization.
    let err {.used.} = pthread_barrier_destroy(syncBarrier)
    assert err == 0, osErrorMsg(OSErrorCode(err))
