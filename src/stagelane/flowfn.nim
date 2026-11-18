## stagelane/flowfn — flow procs as values.
##
## A `{.flow.}` proc cannot be stored in a `proc` variable (calling one needs to know,
## at compile time, that it may pause).  `FlowFn[P]` is the storable form: it holds the
## *constructor* of the proc's continuation, so it can be put in a table, passed around,
## and started later, by `go` / `spawn` / `scope.go`, or called (it may pause) with `call`.
##
## ```nim
## proc greet(name: string): string {.flow.} =
##   delay(1); "hi " & name
## let f = flowFn(greet)                  # FlowFn[proc (name: string): string]
## echo f.call("you")                     # inside a flow proc; elsewhere it blocks
## let t = go f.call("me")
## let g = flowFn(greet, "bound")         # arguments can be bound: FlowFn[proc (): string]
## ```
import std/macros
import ./core, ./transform

type
  FlowFn*[P] = object
    ## `P` is the signature as a plain proc type, e.g. `proc (c: TcpStream)`.
    fn*: pointer         # (internal) nimcall thunk: proc (args..., env: pointer): Frame
    env*: RootRef        # (internal) what the thunk needs besides the arguments (bound arguments)

proc identCtor*(c: Frame): Frame = c
  ## the "constructor" of `runFrame`: the continuation was already built by the caller

proc runFrame*[R](c: Frame): R {.flowCtor: identCtor.} =
  ## run an already built continuation and return its result (it may pause)
  when R is void: blockOn(c)
  else: blockOn(c, R)

proc isNil*[P](f: FlowFn[P]): bool = f.fn == nil

proc procSig(f: NimNode): NimNode =
  ## the formal parameters of the stub `f` as (ret, [name, type]...)
  var ty = f.getTypeInst
  if ty.kind == nnkBracketExpr and ty.len > 0 and ty[0].eqIdent("typeDesc"): ty = ty[1]
  if ty.kind != nnkProcTy: error("flowFn expects the name of a {.flow.} proc", f)
  ty[0]

proc plainProcType(ret: NimNode, params: seq[(NimNode, NimNode)]): NimNode =
  var fp = newTree(nnkFormalParams, if ret.kind == nnkEmpty: newEmptyNode() else: copyNimTree(ret))
  for (n, t) in params: fp.add newIdentDefs(n, copyNimTree(t))
  newTree(nnkProcTy, fp, newEmptyNode())

# --- invokers: one pair per arity, so that `call` evaluates its FlowFn argument once ------
proc flowInvokeR0*[R](h: FlowFn[proc (): R]): Frame =
  cast[proc (env: pointer): Frame {.nimcall.}](h.fn)(cast[pointer](h.env))
proc flowInvokeV0*[](h: FlowFn[proc ()]): Frame =
  cast[proc (env: pointer): Frame {.nimcall.}](h.fn)(cast[pointer](h.env))
proc flowInvokeR1*[A0, R](h: FlowFn[proc (a0: A0): R], a0: A0): Frame =
  cast[proc (a0: A0; env: pointer): Frame {.nimcall.}](h.fn)(a0, cast[pointer](h.env))
proc flowInvokeV1*[A0](h: FlowFn[proc (a0: A0)], a0: A0): Frame =
  cast[proc (a0: A0; env: pointer): Frame {.nimcall.}](h.fn)(a0, cast[pointer](h.env))
proc flowInvokeR2*[A0, A1, R](h: FlowFn[proc (a0: A0; a1: A1): R], a0: A0, a1: A1): Frame =
  cast[proc (a0: A0; a1: A1; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, cast[pointer](h.env))
proc flowInvokeV2*[A0, A1](h: FlowFn[proc (a0: A0; a1: A1)], a0: A0, a1: A1): Frame =
  cast[proc (a0: A0; a1: A1; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, cast[pointer](h.env))
proc flowInvokeR3*[A0, A1, A2, R](h: FlowFn[proc (a0: A0; a1: A1; a2: A2): R], a0: A0, a1: A1, a2: A2): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, cast[pointer](h.env))
proc flowInvokeV3*[A0, A1, A2](h: FlowFn[proc (a0: A0; a1: A1; a2: A2)], a0: A0, a1: A1, a2: A2): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, cast[pointer](h.env))
proc flowInvokeR4*[A0, A1, A2, A3, R](h: FlowFn[proc (a0: A0; a1: A1; a2: A2; a3: A3): R], a0: A0, a1: A1, a2: A2, a3: A3): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; a3: A3; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, a3, cast[pointer](h.env))
proc flowInvokeV4*[A0, A1, A2, A3](h: FlowFn[proc (a0: A0; a1: A1; a2: A2; a3: A3)], a0: A0, a1: A1, a2: A2, a3: A3): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; a3: A3; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, a3, cast[pointer](h.env))
proc flowInvokeR5*[A0, A1, A2, A3, A4, R](h: FlowFn[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4): R], a0: A0, a1: A1, a2: A2, a3: A3, a4: A4): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, a3, a4, cast[pointer](h.env))
proc flowInvokeV5*[A0, A1, A2, A3, A4](h: FlowFn[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4)], a0: A0, a1: A1, a2: A2, a3: A3, a4: A4): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, a3, a4, cast[pointer](h.env))
proc flowInvokeR6*[A0, A1, A2, A3, A4, A5, R](h: FlowFn[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5): R], a0: A0, a1: A1, a2: A2, a3: A3, a4: A4, a5: A5): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, a3, a4, a5, cast[pointer](h.env))
proc flowInvokeV6*[A0, A1, A2, A3, A4, A5](h: FlowFn[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5)], a0: A0, a1: A1, a2: A2, a3: A3, a4: A4, a5: A5): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, a3, a4, a5, cast[pointer](h.env))
proc flowInvokeR7*[A0, A1, A2, A3, A4, A5, A6, R](h: FlowFn[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5; a6: A6): R], a0: A0, a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5; a6: A6; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, a3, a4, a5, a6, cast[pointer](h.env))
proc flowInvokeV7*[A0, A1, A2, A3, A4, A5, A6](h: FlowFn[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5; a6: A6)], a0: A0, a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5; a6: A6; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, a3, a4, a5, a6, cast[pointer](h.env))
proc flowInvokeR8*[A0, A1, A2, A3, A4, A5, A6, A7, R](h: FlowFn[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5; a6: A6; a7: A7): R], a0: A0, a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5; a6: A6; a7: A7; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, a3, a4, a5, a6, a7, cast[pointer](h.env))
proc flowInvokeV8*[A0, A1, A2, A3, A4, A5, A6, A7](h: FlowFn[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5; a6: A6; a7: A7)], a0: A0, a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7): Frame =
  cast[proc (a0: A0; a1: A1; a2: A2; a3: A3; a4: A4; a5: A5; a6: A6; a7: A7; env: pointer): Frame {.nimcall.}](h.fn)(a0, a1, a2, a3, a4, a5, a6, a7, cast[pointer](h.env))

macro flowFn*(f: typed, bound: varargs[typed]): untyped =
  ## the value form of the flow proc `f`, with its leading arguments bound to `bound`
  let w = stubCtor(f)
  if w == nil: error("flowFn needs the name of a non-generic {.flow.} proc", f)
  let sig = procSig(f)
  var ps: seq[(NimNode, NimNode)]
  for i in 1..<sig.len:
    for j in 0..<sig[i].len - 2:
      if sig[i][^2].kind == nnkVarTy: error("a flow proc with `var` parameters cannot be a value", f)
      ps.add (sig[i][j], sig[i][^2])
  if bound.len > ps.len: error("flowFn: more bound arguments than parameters", f)
  let nb = bound.len
  let thunk = genSym(nskProc, "flowThunk")
  let box = genSym(nskType, "FlowBox")
  let envP = ident"flowEnv"
  let bx = ident"flowBox"
  # the thunk: proc (rest..., env: pointer): Frame
  var tparams = newTree(nnkFormalParams, ident"Frame")
  var rest: seq[(NimNode, NimNode)]
  var callArgs: seq[NimNode]
  for i in 0..<ps.len:
    if i < nb: callArgs.add newDotExpr(bx, ident("b" & $i))
    else:
      let pn = ident("flowP" & $i)
      tparams.add newIdentDefs(pn, copyNimTree(ps[i][1]))
      callArgs.add pn
      rest.add (ident("a" & $i), ps[i][1])
  tparams.add newIdentDefs(envP, ident"pointer")
  var body = newStmtList()
  if nb > 0:
    body.add newTree(nnkLetSection, newIdentDefs(
      newTree(nnkPragmaExpr, bx, newTree(nnkPragma, ident"cursor")), newEmptyNode(),
      newTree(nnkCast, box, envP)))
  let ctorCall = newCall(w)
  for a in callArgs: ctorCall.add a
  body.add newAssignment(ident"result", newCall(ident"Frame", ctorCall))
  let thunkDef = newTree(nnkProcDef, thunk, newEmptyNode(), newEmptyNode(), tparams,
    newTree(nnkPragma, ident"nimcall"), newEmptyNode(), body)
  var res = newStmtList()
  var envExpr: NimNode = newNilLit()
  if nb > 0:
    var fields = newTree(nnkRecList)
    for i in 0..<nb: fields.add newIdentDefs(ident("b" & $i), copyNimTree(ps[i][1]))
    res.add newTree(nnkTypeSection, newTree(nnkTypeDef, box, newEmptyNode(),
      newTree(nnkRefTy, newTree(nnkObjectTy, newEmptyNode(),
        newTree(nnkOfInherit, ident"RootObj"), fields))))
    var oc = newTree(nnkObjConstr, box)
    for i in 0..<nb: oc.add newTree(nnkExprColonExpr, ident("b" & $i), bound[i])
    envExpr = oc
  res.add thunkDef
  let ret = if sig[0].kind == nnkEmpty: newEmptyNode() else: sig[0]
  let pt = plainProcType(ret, rest)
  res.add newTree(nnkObjConstr, newTree(nnkBracketExpr, bindSym"FlowFn", pt),
    newTree(nnkExprColonExpr, ident"fn", newTree(nnkCast, ident"pointer", thunk)),
    newTree(nnkExprColonExpr, ident"env", envExpr))
  result = newTree(nnkBlockStmt, newEmptyNode(), res)

proc fnSig(h: NimNode): NimNode =
  ## the `proc (...)` type argument of `FlowFn[P]`
  var ty = h.getTypeInst
  if ty.kind == nnkSym: ty = ty.getImpl[2]          # an alias: look through it
  if ty.kind == nnkTypeDef: ty = ty[2]
  if ty.kind != nnkBracketExpr or ty.len != 2: error("expected a FlowFn value", h)
  ty[1]

macro call*(h: typed, args: varargs[untyped]): untyped =
  ## start the flow proc held by `h` and wait for its result (like calling the proc; it
  ## may pause).  `go h.call(x)`, `scope.go h.call(x)` and `pool.spawn h.call(x)` run it as a task.
  let sig = fnSig(h)[0]
  let ret = sig[0]
  var n = 0
  for i in 1..<sig.len: n += sig[i].len - 2
  if args.len != n: error("expected " & $n & " argument(s), got " & $args.len, h)
  if n > 8: error("flow values take at most 8 arguments (bind some with flowFn(f, a, b))", h)
  let inv = newCall(ident("flowInvoke" & (if ret.kind == nnkEmpty: "V" else: "R") & $n), h)
  for a in args: inv.add a
  let rt = if ret.kind == nnkEmpty: ident"void" else: copyNimTree(ret)
  result = newCall(newTree(nnkBracketExpr, bindSym"runFrame", rt), inv)
