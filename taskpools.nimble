mode = ScriptMode.Verbose

packageName   = "taskpools"
version       = "0.0.5"
author        = "Status Research & Development GmbH"
description   = "lightweight, energy-efficient, easily auditable threadpool"
license       = "MIT"
skipDirs      = @["tests"]

requires "nim >= 1.6.0"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") &
  " --skipParentCfg --skipUserCfg --outdir:build --nimcache:build/nimcache -f" &
  " --stacktrace:on --linetrace:on" &
  " --threads:on"

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path
  if (NimMajor, NimMinor) > (1, 6):
    build args & " --mm:refc -r", path

task test, "Run Taskpools tests":
  # Internal data structures
  run "", "taskpools/channels_spsc_single.nim"
  run "", "taskpools/sparsesets.nim"

  # Examples
  run "", "examples/e01_simple_tasks.nim"
  run "", "examples/e02_parallel_pi.nim"

  # Benchmarks
  run "", "benchmarks/dfs/taskpool_dfs.nim"
  run "", "benchmarks/heat/taskpool_heat.nim"
  run "", "benchmarks/nqueens/taskpool_nqueens.nim"

  when not defined(windows):
    run "", "benchmarks/single_task_producer/taskpool_spc.nim"
    run "", "benchmarks/bouncing_producer_consumer/taskpool_bpc.nim"

  # TODO - generics in macro issue
  # run "", "benchmarks/matmul_cache_oblivious/taskpool_matmul_co.nim"
