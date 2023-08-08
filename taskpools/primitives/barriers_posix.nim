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
  export PthreadBarrierAttr, PthreadBarrier, Errno, PTHREAD_BARRIER_SERIAL_THREAD
else:
  type
    PthreadBarrierAttr* {.importc: "pthread_barrierattr_t", header: "<sys/types.h>", bycopy.} = object
      when (defined(linux) and not defined(android)) and defined(amd64):
        abi: array[4 div sizeof(cint), cint] # https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/x86/nptl/bits/pthreadtypes-arch.h;h=dd06d6753ebc80d94ede6c3c18227a3ad3104570;hb=HEAD#l45
    PthreadBarrier* {.importc: "pthread_barrier_t", header: "<sys/types.h>", bycopy.} = object
      when (defined(linux) and not defined(android)) and defined(amd64):
        abi: array[32 div sizeof(clong), clong] # https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/x86/nptl/bits/pthreadtypes-arch.h;h=dd06d6753ebc80d94ede6c3c18227a3ad3104570;hb=HEAD#l28

    Errno* = cint

  var PTHREAD_BARRIER_SERIAL_THREAD* {.importc, header:"<pthread.h>".}: Errno

# Pthread
# -------------------------------------------------------
when defined(osx):
  export pthread_barrier_init, pthread_barrier_wait, pthread_barrier_destroy
else:
  # TODO careful, this function mutates `barrier` without it being `var` which
  #      is allowed as a consequence of `byref` - it is also different from the
  #      one in barriers_macos
  #      see https://github.com/status-im/nim-taskpools/pull/20#discussion_r923843093
  proc pthread_barrier_init*(
        barrier: var PthreadBarrier,
        attr: ptr PthreadBarrierAttr,
        count: cuint
      ): Errno {.header: "<pthread.h>".}
    ## Initialize `barrier` with the attributes `attr`.
    ## The barrier is opened when `count` waiters arrived.

  # TODO the macos signature is var instead of sink
  proc pthread_barrier_destroy*(
        barrier: var PthreadBarrier): Errno {.header: "<pthread.h>".}
    ## Destroy a previously dynamically initialized `barrier`.

  proc pthread_barrier_wait*(
        barrier: var PthreadBarrier
      ): Errno {.header: "<pthread.h>".}
    ## Wait on `barrier`
    ## Returns PTHREAD_BARRIER_SERIAL_THREAD for a single arbitrary thread
    ## Returns 0 for the other
    ## Returns Errno if there is an error
