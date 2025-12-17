# taskpools
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/[macros, sequtils]

proc isStatic*(n: NimNode): bool =
  case n.kind
  of nnkLiterals:
    true
  of nnkTupleConstr, nnkObjConstr:
    n.allIt(it.isStatic)
  else:
    false
