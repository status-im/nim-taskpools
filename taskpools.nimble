mode = ScriptMode.Verbose

packageName   = "taskpools"
version       = "0.0.1"
author        = "Status Research & Development GmbH"
description   = "lightweight, energy-efficient, easily auditable threadpool"
license       = "MIT"

### Dependencies
requires "nim >= 1.2.12"

proc test(flags, path: string) =
  if not dirExists "build":
    mkDir "build"
  # Note: we compile in release mode. This still have stacktraces
  #       but is much faster than -d:debug

  # Compilation language is controlled by TEST_LANG
  var lang = "c"
  if existsEnv"TEST_LANG":
    lang = getEnv"TEST_LANG"

  echo "\n========================================================================================"
  echo "Running [ ", lang, " ", flags, " ] ", path
  echo "========================================================================================"
  exec "nim " & lang & " " & flags & " --verbosity:0 --hints:off --warnings:off --threads:on -d:release --stacktrace:on --linetrace:on --outdir:build -r " & path

task test, "Run Taskpools tests":
  # Internal data structures
  test "", "taskpools/channels_spsc_single.nim"
  test "", "taskpools/sparsesets.nim"

  # Examples
  test "", "examples/e01_simple_tasks.nim"

  # Benchmarks
  test "", "benchmarks/dfs/taskpool_dfs.nim"
  test "", "benchmarks/heat/taskpool_heat.nim"
  test "", "benchmarks/nqueens/taskpool_nqueens.nim"

  when not defined(windows):
    test "", "benchmarks/single_task_producer/taskpool_spc.nim"
    test "", "benchmarks/bouncing_producer_consumer/taskpool_bpc.nim"

  # TODO - generics in macro issue
  # test "", "benchmarks/matmul_cache_oblivious/taskpool_matmul_co.nim"
