# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import system/ansi_c

{.used.}

template log*(args: varargs[untyped]): untyped =
  c_printf(args)
  flushFile(stdout)

template debugTermination*(body: untyped): untyped =
  when defined(TP_DebugTermination) or defined(TP_Debug):
    {.noSideEffect, gcsafe.}: body

template debug*(body: untyped): untyped =
  when defined(TP_Debug):
    {.noSideEffect, gcsafe.}: body
