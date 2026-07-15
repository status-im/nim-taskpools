# taskpools
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Test based on benchmarks/heat
#
# Heat diffusion (Jacobi-type iteration). The row range is split recursively,
# each half spawned as a task, so tasks write into disjoint rows of a shared
# matrix while reading the neighbouring rows of the previous iteration.
#
# Rows are computed independently, so the parallel result must be identical to
# the serial one bit for bit, whatever order the tasks run in.

{.push raises: [], gcsafe.}

import
  std/math,
  unittest2,
  ./utils,
  ../taskpools

type
  Matrix = object
    buffer: ptr UncheckedArray[float64]
    m, n: int

proc newMatrix(m, n: int): Matrix =
  Matrix(
    buffer: cast[ptr UncheckedArray[float64]](allocShared0(m * n * sizeof(float64))),
    m: m, n: n)

proc delete(mat: sink Matrix) =
  deallocShared(mat.buffer)

template `[]`(mat: Matrix, row, col: Natural): float64 =
  # row-major storage
  assert row < mat.m
  assert col < mat.n
  mat.buffer[row * mat.n + col]

template `[]=`(mat: Matrix, row, col: Natural, value: float64) =
  assert row < mat.m
  assert col < mat.n
  mat.buffer[row * mat.n + col] = value

# Problem definition; the analytical solution is exp(-2t) * sin(x) * sin(y)
template f(x, y: float64): float64 = sin(x) * sin(y)
template randa(x, t: float64): float64 = 0.0
proc randb(x, t: float64): float64 {.inline.} = exp(-2 * t) * sin(x)
template randc(y, t: float64): float64 = 0.0
proc randd(y, t: float64): float64 {.inline.} = exp(-2 * t) * sin(y)
template solu(x, y, t: float64): float64 = exp(-2 * t) * sin(x) * sin(y)

const
  xu = 0.0'f64
  xo = 1.570796326794896558'f64
  yu = 0.0'f64
  yo = 1.570796326794896558'f64
  tu = 0.0'f64
  to = 0.0000001'f64

var
  tp: Taskpool
  nx, ny, nt: int
  dx, dy, dt: float64
  dtdxsq, dtdysq: float64

proc setupProblem(gridX, gridY, steps: int) =
  nx = gridX
  ny = gridY
  nt = steps
  dx = (xo - xu) / float64(nx - 1)
  dy = (yo - yu) / float64(ny - 1)
  dt = (to - tu) / float64(nt)
  dtdxsq = dt / (dx * dx)
  dtdysq = dt / (dy * dy)

proc initRow(m: Matrix, i: int) =
  ## Fills row `i` with the initial condition at t = 0
  if i == 0:
    for j in 0 ..< ny:
      m[i, j] = randc(yu + float64(j)*dy, 0)
  elif i == nx - 1:
    for j in 0 ..< ny:
      m[i, j] = randd(yu + float64(j)*dy, 0)
  else:
    m[i, 0] = randa(xu + float64(i)*dx, 0)
    for j in 1 ..< ny - 1:
      m[i, j] = f(xu + float64(i)*dx, yu + float64(j)*dy)
    m[i, ny - 1] = randb(xu + float64(i)*dx, 0)

proc diffuseRow(output, input: Matrix, i: int, t: float64) =
  ## Computes row `i` at time `t` from `input` at the previous step
  if i == 0:
    for j in 0 ..< ny:
      output[i, j] = randc(yu + float64(j)*dy, t)
  elif i == nx - 1:
    for j in 0 ..< ny:
      output[i, j] = randd(yu + float64(j)*dy, t)
  else:
    output[i, 0] = randa(xu + float64(i)*dx, t)
    for j in 1 ..< ny - 1:
      output[i, j] = input[i, j] +
        dtdysq * (input[i, j+1] - 2 * input[i, j] + input[i, j-1]) +
        dtdxsq * (input[i+1, j] - 2 * input[i, j] + input[i-1, j])
    output[i, ny - 1] = randb(xu + float64(i)*dx, t)

# Parallel: split the row range in half until a single row is left.
# A dummy bool is returned so that the spawned half can be awaited.

proc heat(m: Matrix, il, iu: int): bool {.discardable.} =
  if iu - il > 1:
    let im = (il + iu) div 2
    let h = tp.spawn heat(m, il, im)
    heat(m, im, iu)
    discard sync(h)
    return true
  initRow(m, il)

proc diffuse(output, input: Matrix, il, iu: int, t: float64): bool {.discardable.} =
  if iu - il > 1:
    let im = (il + iu) div 2
    let d = tp.spawn diffuse(output, input, il, im, t)
    diffuse(output, input, im, iu, t)
    discard sync(d)
    return true
  diffuseRow(output, input, il, t)

proc run(parallel: bool): Matrix =
  ## Runs the full simulation, returning the matrix holding the last step
  var
    even = newMatrix(nx, ny)
    odd = newMatrix(nx, ny)
    t = tu

  if parallel:
    heat(even, 0, nx)
  else:
    for i in 0 ..< nx:
      initRow(even, i)

  for step in 1 .. nt:
    t += dt
    let (output, input) = if step mod 2 == 1: (odd, even) else: (even, odd)
    if parallel:
      diffuse(output, input, 0, nx, t)
    else:
      for i in 0 ..< nx:
        diffuseRow(output, input, i, t)

  result = if nt mod 2 != 0: odd else: even
  delete(if nt mod 2 != 0: even else: odd)

type Errors = object
  ## Deviation from the analytical solution, as measured by the benchmark
  mae: float64 ## Local maximal absolute error
  mre: float64 ## Local maximal relative error
  me: float64  ## Global mean absolute error

proc verify(mat: Matrix): Errors =
  for a in 0 ..< nx:
    for b in 0 ..< ny:
      var tmp = abs(mat[a, b] - solu(xu + float64(a)*dx, yu + float64(b)*dy, to))
      result.me += tmp
      if tmp > result.mae:
        result.mae = tmp
      if mat[a, b] != 0.0:
        tmp /= mat[a, b]
      if tmp > result.mre:
        result.mre = tmp
  result.me /= float64(nx * ny)

template checkAccurate(e: Errors): untyped =
  ## The thresholds the benchmark verifies against. The benchmark also fails any
  ## single cell that is off by more than 1e-3; that is subsumed here, since
  ## `mae` is the maximum over all cells and is held to 1e-12.
  check e.mae < 1e-12
  check e.mre < 1e-12
  check e.me < 1e-12

proc identical(a, b: Matrix): bool =
  for i in 0 ..< a.m:
    for j in 0 ..< a.n:
      if a[i, j] != b[i, j]:
        return false
  return true

suite "Heat diffusion":
  setup:
    tp = Taskpool.new(numThreads())

  teardown:
    tp.syncAll()
    tp.shutdown()

  test "parallel result is identical to serial; grid=64x64; steps=10":
    setupProblem(64, 64, 10)
    var
      par = run(parallel = true)
      ser = run(parallel = false)
    check identical(par, ser)
    delete(par)
    delete(ser)

  test "odd number of steps swaps the result matrix":
    setupProblem(32, 32, 7)
    var
      par = run(parallel = true)
      ser = run(parallel = false)
    check identical(par, ser)
    delete(par)
    delete(ser)

  test "matches the analytical solution; grid=384x384; steps=10":
    # The grid is coarser than the benchmark's 4096x1024 to keep the test quick,
    # but not by more than the 1e-12 thresholds tolerate: the discretization
    # error grows as 1/nx^2, reaching ~2.8e-13 here and ~2.5e-12 at 128x128.
    # The bounds are still tight enough to catch a wrong stencil: scaling the
    # diffusion term by 1.5 takes the error up to ~5e-8.
    setupProblem(384, 384, 10)
    var par = run(parallel = true)
    let e = verify(par)
    checkAccurate(e)
    delete(par)

  when defined(release) or defined(danger):
    test "matches the analytical solution; grid=4096x1024; steps=100":
      # The defaults of benchmarks/heat. Allocates 2 x 32MB of matrix
      setupProblem(4096, 1024, 100)
      var par = run(parallel = true)
      let e = verify(par)
      checkAccurate(e)
      delete(par)

  test "grid=2xN: recursion bottoms out on boundary rows only":
    # With nx == 2 every row is a boundary row, so no cell is diffused and the
    # rows are set to the analytical solution directly. This only exercises the
    # base case of the recursive split.
    setupProblem(2, 32, 2)
    var par = run(parallel = true)
    let e = verify(par)
    checkAccurate(e)
    delete(par)
