# Taskpools

## API

The API spec follows https://github.com/nim-lang/RFCs/issues/347#task-parallelism-api

## Overview

This implements a lightweight, energy-efficient, easily auditable multithreaded taskpools.

This taskpools will be used in a highly security-sensitive blockchain application
targeted at resource-restricted devices hence desirable properties are:

- Ease of auditing and maintenance.
  - Formally verified synchronization primitives are highly-sought after.
  - Otherwise primitives are implemented from papers or ported from proven codebases
    that can serve as reference for auditors.
- Resource-efficient. Threads spindown to save power, low memory use.
- Decent performance and scalability. The workload to parallelize are cryptography-related
  and require at least 1ms runtime per thread.
  This means that only a simple scheduler is required.

Non-goals:
- Supporting task priorities
- Being distributed
- Supporting GC-ed memory on Nim default GC (sequences and strings)
- Have async-awaitable tasks

In particular compared to [Weave](https://github.com/mratsim/weave), here are the tradeoffs:
- Taskpools only provide spawn/sync (task parallelism).\
  There is no parallel for (data parallelism)\
  or precise in/out dependencies (dataflow parallelism).
- Weave can handle trillions of small tasks that require only 10µs per task. (Load Balancing overhead)
- Weave maintains an adaptive memory pool to reduce memory allocation overhead,
  Taskpools allocations are as-needed. (Scheduler overhead)

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. This file may not be copied, modified, or distributed except according to those terms.
