## This module provides a facility like Python's multiprocessing module but is
## less automagic & little error handling is done.  `MSlice` is used as a reply
## type to avoid copy in case replies are large.  Auto-pack/unpack logic could
## mimic Python's `for x in p.imap_unordered` more closely.  This is only at the
## Proof Of Concept stage.  Another idea would be channels wrapping processes.

import std/[cpuinfo, posix], ./mslice, ./sysUt
type
  Filter* = object ## Abstract coprocess filter reading|writing its stdin|stdout
    pid: Pid
    fd0, fd1*: cint
    off*: int
    done*: bool
    buf*: string

  Frames* = proc(f: var Filter): iterator(): MSlice

  ProcPool* = object  ## A process pool to do work on multiple cores
    nProc: int
    bufSz: int
    kids: seq[Filter]
    fdset: TFdSet
    fdMax: cint
    frames: Frames

proc len*(pp: ProcPool): int {.inline.} = pp.nProc

proc request*(pp: ProcPool, kid: int, buf: pointer, len: int) =
  discard pp.kids[kid].fd0.write(buf, len)

proc close*(pp: ProcPool, kid: int) =
  discard pp.kids[kid].fd0.close

# The next 4 procs use Unix select not stdlib `selectors` for now since Windows
# CreatePipe/CreateProcess seem tricky for parent-kid coprocesses and I have no
# test platform.  If some one knows how to do that, submit a when(Windows) PR.
proc initFilter(work: proc(), bufSize: int): Filter {.inline.} =
  var fds0, fds1: array[2, cint]
  discard fds0.pipe         # pipe for data flowing from parent -> kid
  discard fds1.pipe         # pipe for data flowing from kid -> parent
  case (let pid = fork(); pid):
  of -1: result.pid = -1
  of 0:
    discard dup2(fds0[0], 0)
    discard dup2(fds1[1], 1)
    discard close(fds0[0])
    discard close(fds0[1])
    discard close(fds1[0])
    discard close(fds1[1])
    work()
    quit(0)
  else:
    result.buf = newString(bufSize) # allocate, setLen, but no-init
    result.pid = pid
    result.fd0 = fds0[1]    # Parent writes to fd0 & reads from fd1;  Those are
    result.fd1 = fds1[0]    #..like the fd nums in the kid, but with RW/swapped.
    discard close(fds0[0])
    discard close(fds1[1])

proc frames0*(f: var Filter): iterator(): MSlice =
  ## An output frames iterator for workers writing '\0'-terminated results.
  let f = f.addr # Seems to relate to nimWorkaround14447; Can `lent`|`sink` fix?
  result = iterator(): MSlice =
    let nRd = read(f.fd1, f.buf[f.off].addr, f.buf.len - f.off)
    if nRd > 0:
      let ms = MSlice(mem: f.buf[0].addr, len: f.off + nRd)
      let eoms = cast[uint](ms.mem) + cast[uint](ms.len)
      f.off = 0
      for s in ms.mSlices('\0'):
        let eos = cast[uint](s.mem) + cast[uint](s.len)
        if eos < eoms and cast[ptr char](eos)[] == '\0':
          yield s
        else:
          f.off = s.len
          moveMem f.buf[0].addr, s.mem, s.len
    else:
      f.done = true

proc initProcPool*(work: proc(); frames = frames0; jobs = 0;
                   bufSize = 16384): ProcPool =
  result.nProc = if jobs == 0: countProcessors() else: jobs
  result.kids.setLen result.nProc
  FD_ZERO result.fdset
  for i in 0 ..< result.nProc:                        # Create nProc Filter kids
    result.kids[i] = initFilter(work, bufSize)
    if result.kids[i].pid == -1:                      # -1 => fork failed
      for j in 0 ..< i:                               # for prior launched kids:
        discard result.kids[j].fd1.close              #   close fd to kid
        discard kill(result.kids[j].pid, SIGKILL)     #   and kill it.
        raise newException(OSError, "fork") # vague chance trying again may work
    FD_SET result.kids[i].fd1, result.fdset
    result.fdMax = max(result.fdMax, result.kids[i].fd1)
  result.fdMax.inc                                    # select takes fdMax + 1
  result.frames = frames

iterator readyReplies*(pp: var ProcPool): MSlice =
  var noTO: Timeval                                   # Zero timeout => no block
  var fdset = pp.fdset
  if select(pp.fdMax, fdset.addr, nil, nil, noTO.addr) > 0:
    for i in 0 ..< pp.nProc:
      if FD_ISSET(pp.kids[i].fd1, fdset) != 0:
        for rep in toItr(pp.frames(pp.kids[i])): yield rep

iterator finalReplies*(pp: var ProcPool): MSlice =
  var st: cint
  var n = pp.nProc                                    # Do final answers
  var fdset0 = pp.fdset
  while n > 0:
    var fdset = fdset0                                # nil timeout => block
    if select(pp.fdMax, fdset.addr, nil, nil, nil) > 0:
      for i in 0 ..< pp.nProc:
        if FD_ISSET(pp.kids[i].fd1, fdset) != 0:
          for rep in toItr(pp.frames(pp.kids[i])): yield rep
          if pp.kids[i].done:                         # got EOF from kid
            FD_CLR pp.kids[i].fd1, fdset0             # Rm from fdset
            discard pp.kids[i].fd1.close              # Reclaim fd
            discard waitpid(pp.kids[i].pid, st, 0)    # Accum CPU to par;No zomb
            n.dec

template eval*(pp, reqGen, onReply: untyped) =
  ## Use `pp=initProcPool(wrk)` & use this template to send strings generated by
  ## `reqGen` (any iterator expr) to `wrk` stdin and pass any stdout-emitted
  ## reply strings to `onReply`.  No reply at all is ok.  Ctrl flow options may
  ## be nice. `examples/only.nim` has a full usage demo.
  var i = 0
  for req in reqGen:
    pp.request(i, cstring(req), req.len + 1)    # keep NUL; Let full pipe block
    i = (i + 1) mod pp.len
    if i + 1 == pp.len:                         # At the end of each req cycle
      for rep in pp.readyReplies: onReply(rep)  #..handle ready replies.
  for i in 0 ..< pp.len: pp.close(i)            # Send EOFs
  for rep in pp.finalReplies: onReply(rep)      # Handle final replies
