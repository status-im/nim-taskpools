# taskpools
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when defined(emscripten) or defined(taskpoolsGenericFutex):
  import ./futexes_generic
  export futexes_generic
elif defined(linux):
  import ./futexes_linux
  export futexes_linux
elif defined(windows):
  import ./futexes_windows
  export futexes_windows
elif defined(osx):
  import ./futexes_macos
  export futexes_macos
else:
  import ./futexes_generic
  export futexes_generic
