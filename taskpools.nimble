mode = ScriptMode.Verbose

packageName   = "taskpools"
version       = "0.2.2"
author        = "Status Research & Development GmbH"
description   = "lightweight, energy-efficient, easily auditable threadpool"
license       = "MIT"
skipDirs      = @["tests"]

requires "nim >= 2.0.14",
         "unittest2 >= 0.2.0"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]
let platform = getEnv("PLATFORM", "")
let testArguments = [
  "",
  "-d:release",
  "-d:danger",
]

from std/os import quoteShell

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0") &
  " --skipParentCfg --skipUserCfg --outdir:build -f " &
  quoteShell("--nimcache:build/nimcache/$projectName") &
  " --stacktrace:on --linetrace:on" &
  " --threads:on"

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path

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
  for args in testArguments:
    runTests args & " --mm:refc"
    runTests args & " --mm:orc"

task test_generic_futex, "Run tests with generic futex":
  for args in testArguments:
    run args & " --mm:refc -d:taskpoolsGenericFutex", "tests/test_all.nim"
    run args & " --mm:orc -d:taskpoolsGenericFutex", "tests/test_all.nim"

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
  for args in testArguments:
    runBenchs args & " --mm:refc"
    runBenchs args & " --mm:orc"

  # fib is slow, run it in release mode only
  run "-d:release --mm:refc", "benchmarks/fibonacci/taskpool_fib.nim"
  run "-d:release --mm:orc", "benchmarks/fibonacci/taskpool_fib.nim"

task test_asan, "Run all tests with ASAN / TSAN":
  if platform != "x86":
    try:
      exec "echo '#if __clang_major__ < 20\n#error\n#endif' | clang -E - >/dev/null"
    except OSError:
      return

    for mm in ["--mm:refc", "--mm:arc -d:useMalloc", "--mm:orc -d:useMalloc"]:
      # https://clang.llvm.org/docs/AddressSanitizer.html
      if mm == "--mm:refc":
        putEnv("ASAN_OPTIONS", "detect_leaks=0:detect_stack_use_after_return=0")
      else:
        putEnv("ASAN_OPTIONS", "detect_leaks=0:detect_stack_use_after_return=1")
      # https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
      putEnv("UBSAN_OPTIONS", "print_stacktrace=1")
      # https://clang.llvm.org/docs/ThreadSanitizer.html
      for sanitizer in ["address", "thread"]:
        if sanitizer == "thread" and defined(windows):
          continue
        var sanArgs =
          " " & mm & " --cc:clang --debugger:native" &
          " --passC:-fsanitize=" & sanitizer & ",undefined" &
          " --passL:-fsanitize=" & sanitizer & ",undefined" &
          " --passC:-fno-sanitize-recover=undefined" &
          " --passC:-fno-sanitize-merge" &
          " --passC:-fno-omit-frame-pointer"
        if sanitizer == "thread":
          sanArgs.add " -d:taskpoolsTsan"
        for args in testArguments:
          runTests args & sanArgs
          run args & sanArgs & " -d:taskpoolsGenericFutex", "tests/test_all.nim"
        runBenchs "-d:danger" & sanArgs
