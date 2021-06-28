# Taskpools architecture

Taskpools architecture is a simple threadpool with work-stealing to handle unbalanced workloads.

## Architecture

### Processing steps

1. On a `spawn` expression, thread i packages the function call in a task.
2. It enqueues it in it's own dequeue.
3. It notify_one a condition variable that holds all sleeping threads.
4. The notified thread wakes up and
5. The notified thread randomly tries to steal a task in a worker.
6. If no tasks are found, it goes back to sleep.
7. Otherwise it runs the task.
8. On a `sync` statement, it runs task in its own task dequeue or steal a task from another worker.
9. Once the `sync` task is ready, it can run the following statements (continuation).
