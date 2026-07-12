# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  unittest2,
  ../../taskpools

proc nothing() =
  discard

proc retint(): int =
  42

# Just test this won't hang; note this is a pathological case
# threadpools are usually created once per program life-time;
# it's also very slow, maybe just run it in linux.

# TODO: leaks thread handlers in windows and raises ResourceExhaustedError
#       https://github.com/nim-lang/Nim/issues/23350

when not defined(windows):
  suite "Shutdown stress test":
    test "no arguments, no result":
      for _ in 0 .. 1_000_000:
        var tp = Taskpool.new()
        tp.spawn(nothing())
        tp.syncAll()
        tp.shutdown()

    test "result, no arguments":
      for _ in 0 .. 1_000_000:
        var tp = Taskpool.new()
        check sync(tp.spawn(retint())) == 42
        tp.syncAll()
        tp.shutdown()
