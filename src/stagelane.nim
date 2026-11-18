## stagelane — continuation-passing style for Nim.
##
## Import `stagelane` for the transform, tasks, timers, channels and sync
## primitives; `stagelane/net` for TCP and (with -d:flowThreads) `stagelane/exec`
## for the multi-threaded executor.
import stagelane/core, stagelane/transform, stagelane/sched, stagelane/sync, stagelane/flowfn
export core, transform, sched, sync, flowfn
