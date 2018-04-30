## This module provides a Nim command line parser that is mostly API compatible
## with the Nim standard library parseopt (and the code derives from that).
## It supports one convenience iterator over all command line options and some
## lower-level features.
## Supported command syntax (here ``=`` | ``:`` may be any char in ``sepChars``):
##
## 1. short option bundles: ``-abx``  (where a, b, x *are in* `shortNoVal`)
##
## 1a. bundles with one final value: ``-abc:Bar``, ``-abc=Bar``, ``-c Bar``,
## ``-abcBar`` (where ``c`` is *not in* ``shortNoVal``)
##
## 2. long options with values: ``--foo:bar``, ``--foo=bar``, ``--foo bar``
## (where ``foo`` is *not in* ``longNoVal``)
##
## 2a. long options without vals: ``--baz`` (where ``baz`` *is in* ``longNoVal``)
##
## 3. command parameters: everything else | anything after "--" or a stop word.
##
## The above is a *superset* of usual POSIX command syntax - it should accept
## any POSIX-inspired input, but it also accepts more forms/styles. (Note that
## POSIX itself is not super strict about this part of the standard.  See:
## http://pubs.opengroup.org/onlinepubs/009604499/basedefs/xbd_chap12.html)
##
## When ``optionNormalize(key)`` is used, command authors provide command users
## additional flexibility to ``--spell_multi-word_options -aVarietyOfWays
## --as-Per_User-Preference``.  This is similar to Nim style-insensitive
## identifier syntax, but by default allows dash ('-') as well as underscore
## ('_') word separation.
##
## The "separator free" forms above require appropriate ``shortNoVal`` and
## ``longNoVal`` lists to designate option keys that take no argument (as well
## as ``requireSeparator == false``).  If such lists are empty, the user must
## use separators.
##
## A notable subtlety is when the first character of an option value is one of
## ``sepChars``.  Even if ``requireSeparator`` is ``false``, passing such option
## values requires either A) putting the value in the next command parameter,
## as in ``"-c :"`` or B) prefixing the value with an element of ``sepChars``,
## as in ``-c=:`` or ``-c::``.  Both choices fit into common quoting styles.
## It seems likely a POSIX-habituated end-user's second guess (after ``"-c:"``
## errored out with "argument expected") would just work as they expected.
## POSIX itself encourages authors & users to use the ``"-c :"`` form anyway.
## This small deviation lets this parser accept valid invocations with the
## original Nim option parser command syntax (with the same semantics), easing
## transition.
##
## To ease "nested" command-line parsing (such as with "git" where there may be
## early global options, a subcommand and later subcommand options), this parser
## also supports a set of "stop words" - special whole command parameters that
## prevent any subsequent parameters being interpreted as options.  This feature
## makes it easy to fully process a command line and then re-process its tail
## rather than mandating breaking out at a stop word with a manual test.  Stop
## words are basically just like a POSIX "--" (which this parser also supports -
## even if "--" is not in ``stopWords``).  Such stop words (or "--") can still
## be the **values** of option arguments.  Only usage as a non-option command
## parameter acts to stop possible option-treatment of later parameters.

import os, strutils

type
  CmdLineKind* = enum         ## the detected command line token
    cmdEnd,                   ## end of command line reached
    cmdArgument,              ## argument detected
    cmdLongOption,            ## a long option ``--option`` detected
    cmdShortOption            ## a short option ``-c`` detected
  OptParser* =
      object of RootObj       ## this object implements the command line parser
    cmd: seq[string]          # command line being parsed
    pos: int                  # current command parameter to inspect
    moreShort: string         # carry over short flags to process
    optsDone: bool            # "--" has been seen
    shortNoVal: set[char]     # 1-letter options not requiring optarg
    longNoVal: seq[string]    # long options not requiring optarg
    stopWords: seq[string]    # special literal parameters that act like "--"
    requireSep: bool          # require separator between option key & val
    sepChars: set[char]       # all the chars that can be valid separators
    sep*: string              ## actual string separating key & value
    kind*: CmdLineKind        ## the detected command line token
    key*, val*: TaintedString ## key and value pair; ``key`` is the option
                              ## or the argument, ``value`` is not "" if
                              ## the option was given a value

proc initOptParser*(cmdline: seq[string] = commandLineParams(),
                    shortNoVal: set[char] = {},
                    longNoVal: seq[string] = nil,
                    requireSeparator=false,  # true imitates old parseopt2
                    sepChars: string= "=:",
                    stopWords: seq[string] = @[]): OptParser =
  ## Initializes a command line parse. `cmdline` should not contain parameter 0,
  ## typically the program name.  If `cmdline` is not given, default to current
  ## program parameters.
  ##
  ## `shortNoVal` and `longNoVal` specify respectively one-letter and long
  ## option keys that do _not_ take arguments.
  ##
  ## If `requireSeparator` is true, then option keys & values must be separated
  ## by an element of sepChars ('='|':' by default) in either short or long
  ## option contexts.  If requireSeparator==false, the parser understands that
  ## only non-bool options will expect args and users may say ``-aboVal`` or
  ## ``-o Val`` or ``--opt Val`` [ as well as the ``-o:Val``|``--opt=Val`` style
  ## which always works ].
  ##
  ## Parameters following either "--" or any literal parameter in stopWords are
  ## never interpreted as options.
  if cmdline == nil:
    result.cmd = commandLineParams()
    return
  result.cmd = cmdline
  result.shortNoVal = shortNoVal
  result.longNoVal = longNoVal
  result.requireSep = requireSeparator
  for c in sepChars:
    result.sepChars.incl(c)
  result.stopWords = stopWords
  result.moreShort = ""
  result.optsDone = false

proc initOptParser*(cmdline: string): OptParser =
  ## Initializes option parses with cmdline.  Splits cmdline in on spaces and
  ## calls initOptParser(openarray[string]).  Should use a proper tokenizer.
  if cmdline == "": # backward compatibility
    return initOptParser(seq[string](nil))
  else:
    return initOptParser(cmdline.split)

proc do_short(p: var OptParser) =
  p.kind = cmdShortOption
  p.val = nil
  p.key = p.moreShort[0..0]             # shift off first char as key
  p.moreShort = p.moreShort[1..^1]
  if p.moreShort.len == 0:              # param exhausted; advance param
    p.pos += 1
  if card(p.shortNoVal) > 0 and p.key[0] in p.shortNoVal:  # opt arg optional
    if p.moreShort[0] in p.sepChars:
      p.val = p.moreShort[1..^1]        # allow :t, =true, etc.
      p.moreShort = ""
      p.pos += 1
    return                                              # continue w/same param
  if p.requireSep and p.moreShort[0] notin p.sepChars:  # No optarg in reqSep mode
    return
  if p.moreShort.len != 0:              # only advance if need more data
    p.pos += 1
  if p.moreShort[0] in p.sepChars:      # shift off maybe-optional separator
    p.moreShort = p.moreShort[1..^1]
  if p.moreShort.len > 0:               # same param argument is trailing text
    p.val = p.moreShort
    p.moreShort = ""
    return
  if p.pos < p.cmd.len:                 # Empty moreShort; opt arg = next param
    p.val = p.cmd[p.pos]
    p.pos += 1
  elif card(p.shortNoVal) > 0:
#   if p.key[0] notin p.sepChars:
    echo "argument expected for option `", p.key, "` at end of params"

proc do_long(p: var OptParser) =
  p.kind = cmdLongOption
  p.val = nil
  let param = p.cmd[p.pos]
  p.pos += 1                            # always consume at least 1 param
  let sep = find(param, p.sepChars)     # only very first occurrence of delim
  if sep == 2:
    echo "Empty long option key at param", p.pos - 1, " (\"", param, "\")"
    p.key = nil
    return
  if sep > 2:
    var nonIdent = sep
    while nonIdent > 2 and param[nonIdent-1] notin IdentChars:
      dec(nonIdent)
    p.sep = param[nonIdent .. sep]
    p.key = param[2 .. nonIdent-1]
    p.val = param[sep+1..^1]
    return
  p.key = param[2..^1]                  # no sep; key is whole param past --
  if p.longNoVal != nil and p.key in p.longNoVal:
    return                              # No argument; done
  if p.requireSep:
    echo "Expecting option key-val separator :|= after `", p.key, "`"
    return
  if p.pos < p.cmd.len:                 # Take opt arg from next param
    p.val = p.cmd[p.pos]
    p.pos += 1
  elif p.longNoVal != nil:
    echo "argument expected for option `", p.key, "` at end of params"

proc next*(p: var OptParser) =
  if p.moreShort.len > 0:               #Step1: handle any remaining short opts
    do_short(p)
    return
  if p.pos >= p.cmd.len:                #Step2: end of params check
    p.kind = cmdEnd
    return
  if not p.cmd[p.pos].startsWith("-") or p.optsDone:  #Step3: non-option param
    p.kind = cmdArgument
    p.key = p.cmd[p.pos]
    p.val = nil
    if p.cmd[p.pos] in p.stopWords:     #Step4: check for stop word
      p.optsDone = true                 # should only hit Step3 henceforth
    p.pos += 1
    return
  if p.cmd[p.pos].startsWith("--"):     #Step5: "--*"
    if p.cmd[p.pos].len == 2:           # terminating "--" => pure param mode
      p.optsDone = true                 # should only hit Step3 henceforth
      p.pos += 1                        # skip the "--" itself, unlike stopWords
      next(p)                           # do next one so each parent next()..
      return                            #..yields exactly 1 opt+arg|cmdparam
    do_long(p)
  else:                                 #Step6: "-" but not "--" => short opt
    if p.cmd[p.pos].len == 1:           #Step6a: simply "-" => non-option param
      p.kind = cmdArgument              #  {"-" often used to indicate "stdin"}
      p.key = p.cmd[p.pos]
      p.val = nil
      p.pos += 1
    else:                               #Step6b: maybe a block of short options
      p.moreShort = p.cmd[p.pos][1..^1] # slice out the initial "-"
      do_short(p)

proc optionNormalize*(s: string, wordSeparators="_-"): string {.noSideEffect.} =
  ## Normalizes option key `s` to allow command syntax to be style-insensitive
  ## in a similar way to Nim identifier syntax.
  ##
  ## Specifically this means to convert *all but the first* char to lower case
  ## and remove chars in ``wordSeparators`` ('_' and '-') by default.  This way
  ## users can type "command --my-opt-key" or "command --myOptKey" and so on.
  ##
  ## Example:
  ##
  ## .. code-block:: nim
  ##   for kind, key, val in p.getopt():
  ##     case kind
  ##     of cmdLongOption, cmdShortOption:
  ##       case optionNormalize(key)
  ##       of "myoptkey", "m": doSomething()
  result = newString(s.len)
  var wordSeps: set[char]   # compile a set[char] from ``wordSeparators``
  for c in wordSeparators:
    wordSeps.incl(c)
  result[0] = s[0]
  var j = 1
  for i in 1..len(s) - 1:
    if s[i] in {'A'..'Z'}:
      result[j] = chr(ord(s[i]) + (ord('a') - ord('A')))
      inc j
    elif s[i] notin wordSeps:
      result[j] = s[i]
      inc j
  if j != s.len:
    setLen(result, j)

type
  GetoptResult* = tuple[kind: CmdLineKind, key, val: TaintedString]

iterator getopt*(p: var OptParser): GetoptResult =
  ## This is an convenience iterator for iterating over the given OptParser object.
  ## Example:
  ##
  ## .. code-block:: nim
  ##   var p = initOptParser("--left --debug:3 -l=4 -r:2")
  ##   for kind, key, val in p.getopt():
  ##     case kind
  ##     of cmdArgument:
  ##       filename = key
  ##     of cmdLongOption, cmdShortOption:
  ##       case key
  ##       of "help", "h": writeHelp()
  ##       of "version", "v": writeVersion()
  ##     of cmdEnd: assert(false) # cannot happen
  ##   if filename == "":
  ##     # no filename has been given, so we show the help:
  ##     writeHelp()
  p.pos = 0
  while true:
    next(p)
    if p.kind == cmdEnd: break
    yield (p.kind, p.key, p.val)

when declared(paramCount):
  iterator getopt*(cmdline=commandLineParams(), shortNoVal: set[char] = {},
                   longNoVal: seq[string] = nil, requireSeparator=false,
                   sepChars="=:", stopWords: seq[string] = @[]): GetoptResult =
    ## This is an convenience iterator for iterating over the command line.
    ## Parameters here are the same as for initOptParser.  Example:
    ## See above for a more detailed example
    ##
    ## .. code-block:: nim
    ##   for kind, key, val in getopt():
    ##     # this will iterate over all arguments passed to the cmdline.
    ##     continue
    ##
    var p = initOptParser(cmdline, shortNoVal, longNoVal, requireSeparator,
                          sepChars, stopWords)
    while true:
      next(p)
      if p.kind == cmdEnd: break
      yield (p.kind, p.key, p.val)
