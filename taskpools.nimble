mode = ScriptMode.Verbose

packageName   = "taskpools"
version       = "0.2.1"
author        = "Status Research & Development GmbH"
description   = "lightweight, energy-efficient, easily auditable threadpool"
license       = "MIT"
skipDirs      = @["tests"]

requires "nim >= 2.0.14",
         "unittest2 >= 0.2.0"

import strutils

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
  build args & " --mm:refc -r", path
  build args & " --mm:orc -r", path

  if (NimMajor, NimMinor) >= (2, 2) and defined(linux) and defined(amd64) and "danger" in args:
    build args & " --mm:arc -d:useMalloc --cc:clang --passc:-fsanitize=address --passl:-fsanitize=address --debugger:native -r", path
    build args & " --mm:orc -d:useMalloc --cc:clang --passc:-fsanitize=address --passl:-fsanitize=address --debugger:native -r", path
    build args & " --mm:orc -d:taskpoolsTsan -d:useMalloc --cc:clang --passc:-fsanitize=thread --passl:-fsanitize=thread --debugger:native -r", path
    build args & " --mm:refc -d:taskpoolsTsan --cc:clang --passc:-fsanitize=thread --passl:-fsanitize=thread --debugger:native -r", path

proc runTests(args: string) =
  # Internal data structures
  run args, "taskpools/sparsesets.nim"

  # Examples
  run args, "examples/e01_simple_tasks.nim"
  run args, "examples/e02_parallel_pi.nim"
  run args, "examples/e03_external_threads.nim"

  # Tests
  run args, "tests/test_all.nim"

task test, "Run tests":
  for mode in ["", "-d:release", "-d:danger"]:
    runTests(mode)

task test_generic_futex, "Run tests with generic futex":
  for mode in ["", "-d:release", "-d:danger"]:
    run mode & " -d:taskpoolsGenericFutex", "tests/test_all.nim"

proc runBenchs(args: string) =
  run args, "benchmarks/dfs/taskpool_dfs.nim"
  # run args, "benchmarks/fibonacci/taskpool_fib.nim"
  run args, "benchmarks/heat/taskpool_heat.nim"
  run args, "benchmarks/nqueens/taskpool_nqueens.nim"
  run args, "benchmarks/iqs_latency/taskpool_iqs_latency.nim"

  when not defined(windows):
    run args, "benchmarks/single_task_producer/taskpool_spc.nim"
    run args, "benchmarks/bouncing_producer_consumer/taskpool_bpc.nim"

  # TODO - generics in macro issue
  # run args, "benchmarks/matmul_cache_oblivious/taskpool_matmul_co.nim"

task test_bench, "Run benchs":
  for mode in ["", "-d:release", "-d:danger"]:
    runBenchs(mode)

  # Avoid TSan; it's too slow
  run "-d:release", "benchmarks/fibonacci/taskpool_fib.nim"
