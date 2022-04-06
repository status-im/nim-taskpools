# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/random,
  system/ansi_c,
  ./instrumentation/contracts,
  ./primitives/allocs

const TP_MaxWorkers = 255
type Setuint = uint8 # We support at most 255 threads (0xFF is kept as special value to signify absence in the set)

const Empty = high(Setuint)

type
  SparseSet* = object
    ## Stores efficiently a set of integers in the range [0 .. Capacity)
    ## Supports:
    ## - O(1)      inclusion, exclusion and contains
    ## - O(1)      random pick
    ## - O(1)      length
    ## - O(length) iteration
    ##
    ## Space: Capacity * sizeof(words)
    ##
    ## This is contrary to bitsets which requires:
    ## - random picking: multiple random "contains" + a fallback to uncompressing the set
    ## - O(Capacity/sizeof(words)) length (via popcounts)
    ## - O(capacity) iteration
    indices: ptr UncheckedArray[Setuint]
    values: ptr UncheckedArray[Setuint]
    rawBuffer: ptr UncheckedArray[Setuint]
    len*: Setuint
    capacity*: Setuint

func allocate*(s: var SparseSet, capacity: SomeInteger) {.inline.} =
  preCondition: capacity <= TP_MaxWorkers

  s.capacity = Setuint capacity
  s.rawBuffer = tp_alloc(Setuint, 2*capacity)
  s.indices = s.rawBuffer
  s.values = cast[ptr UncheckedArray[Setuint]](s.rawBuffer[capacity].addr)

func delete*(s: var SparseSet) {.inline.} =
  s.indices = nil
  s.values = nil
  c_free(s.rawBuffer)

func refill*(s: var SparseSet) {.inline.} =
  ## Reset the sparseset by including all integers
  ## in the range [0 .. Capacity)
  preCondition: not s.indices.isNil
  preCondition: not s.values.isNil
  preCondition: not s.rawBuffer.isNil
  preCondition: s.capacity != 0

  s.len = s.capacity

  for i in Setuint(0) ..< s.len:
    s.indices[i] = i
    s.values[i] = i

func isEmpty*(s: SparseSet): bool {.inline.} =
  s.len == 0

func contains*(s: SparseSet, n: SomeInteger): bool {.inline.} =
  assert n.int != Empty.int
  s.indices[n] != Empty

func incl*(s: var SparseSet, n: SomeInteger) {.inline.} =
  preCondition: n < Empty

  if n in s: return

  preCondition: s.len < s.capacity

  s.indices[n] = s.len
  s.values[s.len] = n
  s.len += 1

func peek*(s: SparseSet): int32 {.inline.} =
  ## Returns the last point in the set
  ## Note: if an item is deleted this is not the last inserted point
  preCondition: s.len.int > 0
  int32 s.values[s.len - 1]

func excl*(s: var SparseSet, n: SomeInteger) {.inline.} =
  if n notin s: return

  # We do constant time deletion by replacing the deleted
  # integer by the last value in the array of values

  let delIdx = s.indices[n]

  s.len -= 1
  let lastVal = s.values[s.len]

  s.indices[lastVal] = delIdx         # Last value now points to deleted index
  s.values[delIdx] = s.values[lastVal] # Deleted item is now last value

  # Erase the item
  s.indices[n] = Empty

func randomPick*(s: SparseSet, rng: var Rand): int {.inline.} =
  ## Randomly pick from the set.
  # The value is NOT removed from it.
  let pickIdx = rng.rand(s.len-1)
  result = s.values[pickIdx].int

func `$`*(s: SparseSet): string =
  $toOpenArray(s.values, 0, s.len.int - 1)

# Sanity checks
# ------------------------------------------------------------------------------

when isMainModule:

  const Size = 10
  const Picked = 5

  var S: SparseSet
  S.allocate(Size)
  S.refill()
  echo S

  var rngState = initRand(123)
  var picked: seq[int]

  for _ in 0 ..< Picked:
    let p = S.randomPick(rngState)
    picked.add p
    S.excl p
    echo "---"
    echo "picked: ", p
    echo "S indices: ", toOpenArray(S.indices, 0, S.capacity.int - 1)

  echo "---"
  echo "picked: ", picked
  echo "S: ", S
  echo "S indices: ", toOpenArray(S.indices, 0, S.capacity.int - 1)

  for x in 0 ..< Size:
    if x notin picked:
      echo x, " notin picked -> in S"
      doAssert x in S
    else:
      echo x, " in picked -> notin S"
      doAssert x notin S
