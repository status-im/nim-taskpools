# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Test based on benchmarks/bouncing_producer_consumer
#
# Each producer task spawns the next producer plus `n` consumer tasks, so the
# producer role bounces from thread to thread as the chain is stolen.
# The total task count is (tasksPerDepth + 1) * depth
#
# Both roles bump a counter that lives on the caller's stack, so the count can
# only be read once `syncAll` has returned and no task can be running anymore.

{.used.}

import ./[
  test_bpc,
  test_calltypes,
  test_dfs,
  test_fib,
  test_heat,
  test_nqueens,
  test_spc
]
