# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Abstractions over POSIX barriers (non-)implementations

when not compileOption("threads"):
  {.error: "This requires --threads:on compilation flag".}

# Types
# -------------------------------------------------------

when defined(osx):
  import ./barriers_macos
  export pthread_barrier_init, pthread_barrier_wait, pthread_barrier_destroy

else:
  import posix
  # in `posix`, these take a `ptr` as first argument and wrongly use cint for a3
  proc pthread_barrier_destroy*(a1: var Pthread_barrier): cint {.
    importc, header: "<pthread.h>".}
  proc pthread_barrier_init*(a1: var Pthread_barrier,
          a2: ptr Pthread_barrierattr, a3: cuint): cint {.
          importc, header: "<pthread.h>".}
  proc pthread_barrier_wait*(a1: var Pthread_barrier): cint {.
    importc, header: "<pthread.h>".}

export Pthread_attr, Pthread_barrier, PTHREAD_BARRIER_SERIAL_THREAD
