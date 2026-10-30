## A library module: exported flow procs are used like any other proc.
import ../src/stagelane

type Price* = object
  cents*: int

proc taxed*(p: Price): Price {.flow.} =               # never suspends: compiled to native code
  Price(cents: p.cents * 120 div 100)

proc lookup*(sku: string): Price {.flow.} =           # suspends (pretend network call)
  delay(10)
  Price(cents: 100 * sku.len)

proc total*(skus: seq[string]): Price {.flow.} =      # flow procs call flow procs freely
  for s in skus:
    result.cents += taxed(lookup(s)).cents
