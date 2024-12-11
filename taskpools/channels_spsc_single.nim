# taskpools
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Copyright (c) 2021- Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[atomics, typetraits]

type
  ChannelSPSCSingle*[T] = object
    ## A single-value SPSC channel
    ##
    ## Wait-free bounded single-producer single-consumer channel
    ## that can only buffer a single item
    ## Properties:
    ##   - wait-free
    ##   - supports weak memory models
    ##   - buffers a single item
    ##   - Padded to avoid false sharing in collections
    ##   - No extra indirection to access the item, the buffer is inline the channel
    ##   - Linearizable
    ##
    ## The channel should be the last field of an object if used in an intrusive manner
    full{.align: 64.}: Atomic[bool]
    value*: T

proc `=copy`[T](
    dest: var ChannelSPSCSingle[T],
    source: ChannelSPSCSingle[T]
  ) {.error: "A channel cannot be copied".}

func isEmpty*(chan: var ChannelSPSCSingle): bool {.inline.} =
  not chan.full.load(moAcquire)

func tryRecv*[T](chan: var ChannelSPSCSingle, dst: var T): bool {.inline.} =
  ## Try receiving the item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ##
  ## ⚠ Use only in the consumer thread that reads from the channel.
  static: doAssert supportsCopyMem(T), "Channel is not garbage-collection-safe"

  case chan.full.load(moAcquire)
  of true:
    dst = move(chan.value)
    chan.full.store(false, moRelease)
    true
  of false:
    false

func trySend*[T](chan: var ChannelSPSCSingle, src: sink T): bool {.inline.} =
  ## Try sending an item into the channel
  ## Reurns true if successful (channel was empty)
  ##
  ## ⚠ Use only in the producer thread that writes from the channel.
  static: doAssert supportsCopyMem(T), "Channel is not garbage-collection-safe"

  case chan.full.load(moAcquire)
  of true:
    false
  of false:
    chan.value = move(src)
    chan.full.store(true, moRelease)
    true

{.pop.} # raises: []

# Sanity checks
# ------------------------------------------------------------------------------
when isMainModule:
  when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

  template sendLoop[T](chan: var ChannelSPSCSingle[T],
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T](chan: var ChannelSPSCSingle[T],
                       data: var T,
                       body: untyped): untyped =
    while not chan.tryRecv(data):
      body

  type
    ThreadArgs = object
      ID: WorkerKind
      chan: ptr ChannelSPSCSingle[int]

    WorkerKind = enum
      Sender
      Receiver

  template Worker(id: WorkerKind, body: untyped): untyped {.dirty.} =
    if args.ID == id:
      body

  proc thread_func(args: ThreadArgs) =

    # Worker RECEIVER:
    # ---------
    # <- chan
    # <- chan
    # <- chan
    #
    # Worker SENDER:
    # ---------
    # chan <- 42
    # chan <- 53
    # chan <- 64
    Worker(Receiver):
      var val: int
      for j in 0 ..< 10:
        args.chan[].recvLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "                  Receiver got: ", val
        doAssert val == 42 + j*11

    Worker(Sender):
      doAssert args.chan.full.load(moRelaxed) == false
      for j in 0 ..< 10:
        let val = 42 + j*11
        args.chan[].sendLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "Sender sent: ", val

  import primitives/allocs
  proc main() =
    echo "Testing if 2 threads can send data"
    echo "-----------------------------------"

    var threads: array[2, Thread[ThreadArgs]]
    var chan = tp_allocAligned(
      ChannelSPSCSingle[int], sizeof(ChannelSPSCSingle[int]), 64)
    zeroMem(chan, sizeof(ChannelSPSCSingle[int]))

    createThread(threads[0], thread_func, ThreadArgs(ID: Receiver, chan: chan))
    createThread(threads[1], thread_func, ThreadArgs(ID: Sender, chan: chan))

    joinThread(threads[0])
    joinThread(threads[1])

    tp_freeAligned(chan)

    echo "-----------------------------------"
    echo "Success"

  main()
