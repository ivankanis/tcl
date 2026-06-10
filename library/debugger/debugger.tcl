# debugger.tcl --
#
# A small gdb-flavored command-line debugger built on the TIP #86
# debugger-support commands ([trace execution], [trace breakpoint],
# [info line], [info return]).
#
# The debuggee runs in the same interpreter: [run] sources the target
# script with an interpreter-wide execution trace installed, and when the
# trace callback decides to stop it parks the debuggee on the C stack and
# reads debugger commands from a prompt.  Commands evaluated at the prompt
# are never themselves traced because the core suppresses the execution
# trace for the duration of the callback.
#
# Copyright (c) 2026 Ivan Kanis
#
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.

package provide debugger 0.1

namespace eval ::tcl::debugger {
    namespace export start attach

    variable scriptFile {}	;# Normalized path of the script under debug.
    variable selfFile [file normalize [info script]]
    variable running 0		;# 1 while [run] is sourcing the script.
    variable mode continue	;# continue | step | next | finish
    variable stopLevel 0	;# Stack-level threshold for next/finish.
    variable resume 0		;# Set by resume commands to leave the REPL.
    variable quitRequested 0
    variable exitOnQuit 1	;# Tests set this to 0 so quit returns.
    variable stopFrame 0	;# [info level] depth at the current stop.
    variable curLine 0		;# Location of the current stop.
    variable curFile {}
    variable listLine 0		;# Next line for a continued [list].
    variable lastCmd {}		;# For empty-line repeat.
    variable breakpoints {}	;# dict: id -> {line file state}
    variable nextBpId 1
    variable inChan stdin
    variable outChan stdout
    variable sourceCache	;# array: file -> list of source lines
    array set sourceCache {}

    # Debugger commands, full names only; single-letter aliases and
    # unique-prefix matching are handled by Dispatch.
    variable cmdTable {
	break CmdBreak continue CmdContinue delete CmdDelete
	disable CmdDisable enable CmdEnable finish CmdFinish help CmdHelp
	list CmdList next CmdNext print CmdPrint quit CmdQuit run CmdRun
	step CmdStep where CmdWhere bt CmdWhere
    }
    variable aliases {
	b break c continue s step n next p print l list q quit
    }
}

# ::tcl::debugger::start --
#
#	Entry point used by the tcldbg launcher: remember the script and
#	enter the top-level prompt without running it, so breakpoints can
#	be set first.

proc ::tcl::debugger::start {script} {
    variable scriptFile [file normalize $script]
    variable quitRequested 0
    variable exitOnQuit
    Out "tcldbg: debugging $scriptFile"
    Out "Type \"help\" for a list of commands, \"run\" to start."
    Repl
    if {$exitOnQuit} {
	exit 0
    }
}

# ::tcl::debugger::attach --
#
#	Redirect the debugger prompt to other channels (used by the test
#	suite, and the hook for driving the debugger remotely).

proc ::tcl::debugger::attach {{in {}} {out {}}} {
    variable inChan
    variable outChan
    if {$in ne {}} {
	set inChan $in
    }
    if {$out ne {}} {
	set outChan $out
    }
}

# ::tcl::debugger::Reset --
#
#	Clear all debugger state, including the core breakpoint table.
#	Used between test cases.

proc ::tcl::debugger::Reset {} {
    variable breakpoints
    foreach {id bp} $breakpoints {
	catch {trace breakpoint [lindex $bp 0] [lindex $bp 1] {}}
    }
    trace execution {}
    variable scriptFile {}
    variable running 0
    variable mode continue
    variable stopLevel 0
    variable resume 0
    variable quitRequested 0
    variable stopFrame 0
    variable curLine 0
    variable curFile {}
    variable listLine 0
    variable lastCmd {}
    variable breakpoints {}
    variable nextBpId 1
    variable inChan stdin
    variable outChan stdout
    variable sourceCache
    array unset sourceCache
    array set sourceCache {}
}

proc ::tcl::debugger::Out {msg} {
    variable outChan
    puts $outChan $msg
}

# ::tcl::debugger::ShouldStop --
#
#	Pure stop-decision helper (separate from Callback so the test
#	suite can drive it with synthetic trace tuples).  Returns the
#	reason to stop, or an empty string to keep running.  Breakpoints
#	stop in every mode, matching the core behavior of the breakpoint
#	flag overriding the trace level filter.

proc ::tcl::debugger::ShouldStop {mode stopLevel stacklevel flags} {
    if {$flags & 1} {
	return breakpoint
    }
    switch -- $mode {
	step {
	    return step
	}
	next {
	    if {$stacklevel <= $stopLevel} {
		return next
	    }
	}
	finish {
	    if {$stacklevel <= $stopLevel} {
		return finish
	    }
	}
    }
    return {}
}

# ::tcl::debugger::Callback --
#
#	The [trace execution] target: invoked before every debuggee
#	command with the TIP #86 record.  Commands with no source file
#	(dynamically evaluated code) and the debugger's own internals are
#	never stopped in.  Running at trace level 0 and filtering here in
#	Tcl keeps next/finish correct in both compiled and interpreted
#	code; a future optimization could re-arm with level 1 during
#	continue so the core suppresses nested callbacks (breakpoints
#	still fire).

proc ::tcl::debugger::Callback {line file nest stack ns cmd command flags} {
    variable selfFile
    if {$file eq {} || $file eq $selfFile} {
	return
    }
    variable mode
    variable stopLevel
    set why [ShouldStop $mode $stopLevel $stack $flags]
    if {$why eq {}} {
	return
    }
    variable curLine $line
    variable curFile $file
    variable stopFrame $stack
    variable listLine 0
    set mode continue
    ReportStop $why $line $file $command
    Repl
    variable quitRequested
    if {$quitRequested} {
	trace execution {}
	variable exitOnQuit
	if {$exitOnQuit} {
	    exit 0
	}
	return -code error -errorcode {TCLDBG QUIT} "debugger quit"
    }
    return
}

proc ::tcl::debugger::ReportStop {why line file command} {
    switch -- $why {
	breakpoint {
	    set id [FindBpId $line $file]
	    Out "Breakpoint $id, at $file:$line"
	}
	finish {
	    Out "Finished, at $file:$line"
	}
	default {
	    Out "Stopped at $file:$line"
	}
    }
    set src [SourceLine $file $line]
    if {$src ne {}} {
	Out [format "%d\t%s" $line $src]
    } else {
	Out [format "%d\t%s" $line $command]
    }
}

proc ::tcl::debugger::FindBpId {line file} {
    variable breakpoints
    foreach {id bp} $breakpoints {
	if {[lindex $bp 0] == $line && [lindex $bp 1] eq $file} {
	    return $id
	}
    }
    return ?
}

# ::tcl::debugger::Repl --
#
#	The prompt loop.  Runs both at top level (from [start]) and while
#	stopped (from Callback, with the debuggee parked on the C stack).
#	Exits when a resume command sets the resume flag or quit/EOF sets
#	quitRequested.

proc ::tcl::debugger::Repl {} {
    variable inChan
    variable outChan
    variable resume 0
    variable quitRequested
    variable lastCmd
    while {!$resume && !$quitRequested} {
	puts -nonewline $outChan "(tcldbg) "
	flush $outChan
	if {[gets $inChan line] < 0} {
	    if {[eof $inChan]} {
		puts $outChan {}
		set quitRequested 1
		break
	    }
	    continue
	}
	set line [string trim $line]
	if {$line eq {}} {
	    set line $lastCmd
	    if {$line eq {}} {
		continue
	    }
	}
	set lastCmd $line
	if {[catch {Dispatch $line} msg]} {
	    Out "Error: $msg"
	}
    }
}

# ::tcl::debugger::Dispatch --
#
#	Map the first word onto a debugger command (aliases, then unique
#	prefix).  "info breakpoints" is intercepted; any other
#	unrecognized input is evaluated in the stopped frame, so plain
#	Tcl like "set x 5" or "info locals" works at the prompt.

proc ::tcl::debugger::Dispatch {line} {
    variable cmdTable
    variable aliases
    variable stopFrame
    set first [lindex [split $line] 0]
    set rest [string trim \
	    [string range $line [string length $first] end]]
    if {[dict exists $aliases $first]} {
	set first [dict get $aliases $first]
    }
    if {$first eq "info"} {
	set sub [lindex [split $rest] 0]
	if {$sub ne {} && [string match ${sub}* breakpoints]} {
	    CmdInfoBreakpoints
	    return
	}
    }
    set match [::tcl::prefix match -error {} [dict keys $cmdTable] $first]
    if {$match ne {}} {
	[dict get $cmdTable $match] $rest
	return
    }
    set r [uplevel "#$stopFrame" $line]
    if {$r ne {}} {
	Out $r
    }
}

# ----------------------------------------------------------------------
# Debugger commands.  Each takes the rest of the input line as a string.
# ----------------------------------------------------------------------

proc ::tcl::debugger::CmdRun {args} {
    variable running
    variable scriptFile
    variable mode
    variable resume
    if {$running} {
	Out "The script is already running."
	return
    }
    if {$scriptFile eq {}} {
	Out "No script to run."
	return
    }
    set running 1
    trace execution [namespace current]::Callback
    set code [catch {uplevel #0 [list source $scriptFile]} msg opts]
    trace execution {}
    set running 0
    set mode continue
    variable stopFrame 0
    # A nested Repl may have left resume set; this Repl level must keep
    # prompting after the script returns.
    set resume 0
    if {$code == 1} {
	if {[lrange [dict get $opts -errorcode] 0 1] eq {TCLDBG QUIT}} {
	    return
	}
	Out "Script error: $msg"
	Out [dict get $opts -errorinfo]
    } else {
	Out "Script completed."
    }
}

proc ::tcl::debugger::CmdBreak {spec} {
    variable scriptFile
    variable breakpoints
    variable nextBpId
    if {$spec eq {}} {
	Out "usage: break ?file:?line"
	return
    }
    set idx [string last : $spec]
    if {$idx < 0} {
	set file $scriptFile
	set lineNo $spec
    } else {
	set file [string range $spec 0 [expr {$idx - 1}]]
	set lineNo [string range $spec [expr {$idx + 1}] end]
	if {$file eq [file tail $scriptFile]} {
	    set file $scriptFile
	} else {
	    set file [file normalize $file]
	}
    }
    if {![string is integer -strict $lineNo] || $lineNo < 1} {
	Out "usage: break ?file:?line"
	return
    }
    trace breakpoint $lineNo $file 1
    set id $nextBpId
    incr nextBpId
    dict set breakpoints $id [list $lineNo $file 1]
    Out "Breakpoint $id at $file:$lineNo"
}

proc ::tcl::debugger::CmdDelete {idList} {
    variable breakpoints
    if {$idList eq {}} {
	set idList [dict keys $breakpoints]
    }
    foreach id $idList {
	if {![dict exists $breakpoints $id]} {
	    Out "No breakpoint number $id."
	    continue
	}
	lassign [dict get $breakpoints $id] lineNo file
	catch {trace breakpoint $lineNo $file {}}
	dict unset breakpoints $id
    }
}

proc ::tcl::debugger::SetBpState {id state} {
    variable breakpoints
    if {![dict exists $breakpoints $id]} {
	Out "No breakpoint number $id."
	return
    }
    lassign [dict get $breakpoints $id] lineNo file
    trace breakpoint $lineNo $file $state
    dict set breakpoints $id [list $lineNo $file $state]
}

proc ::tcl::debugger::CmdDisable {idList} {
    foreach id $idList {
	SetBpState $id 0
    }
}

proc ::tcl::debugger::CmdEnable {idList} {
    foreach id $idList {
	SetBpState $id 1
    }
}

proc ::tcl::debugger::CmdInfoBreakpoints {} {
    variable breakpoints
    if {[dict size $breakpoints] == 0} {
	Out "No breakpoints."
	return
    }
    Out "Num\tEnb\tWhere"
    foreach {id bp} $breakpoints {
	lassign $bp lineNo file state
	set enb [expr {$state > 0 ? "y" : "n"}]
	Out "$id\t$enb\t$file:$lineNo"
    }
}

proc ::tcl::debugger::CmdContinue {args} {
    variable running
    variable mode
    variable resume
    if {!$running} {
	Out "The script is not being run."
	return
    }
    set mode continue
    set resume 1
}

proc ::tcl::debugger::CmdStep {args} {
    variable running
    variable mode
    variable resume
    set mode step
    if {!$running} {
	CmdRun {}
    } else {
	set resume 1
    }
}

proc ::tcl::debugger::CmdNext {args} {
    variable running
    variable mode
    variable stopLevel
    variable stopFrame
    variable resume
    if {!$running} {
	Out "The script is not being run."
	return
    }
    set mode next
    set stopLevel $stopFrame
    set resume 1
}

proc ::tcl::debugger::CmdFinish {args} {
    variable running
    variable mode
    variable stopLevel
    variable stopFrame
    variable resume
    if {!$running} {
	Out "The script is not being run."
	return
    }
    if {$stopFrame == 0} {
	Out "Not in a procedure."
	return
    }
    set mode finish
    set stopLevel [expr {$stopFrame - 1}]
    set resume 1
}

proc ::tcl::debugger::CmdWhere {args} {
    variable stopFrame
    variable curLine
    variable curFile
    if {$stopFrame >= 1} {
	set what [lindex [info level $stopFrame] 0]
    } else {
	set what (toplevel)
    }
    Out "#0\t$what at $curFile:$curLine"
    set k 1
    for {set i [expr {$stopFrame - 1}]} {$i >= 0} {incr i -1} {
	if {$i >= 1} {
	    set what [info level $i]
	} else {
	    set what (toplevel)
	}
	set loc {}
	if {![catch {info line level $i} lf] && [lindex $lf 1] ne {}} {
	    set loc " at [lindex $lf 1]:[lindex $lf 0]"
	}
	Out "#$k\t$what$loc"
	incr k
    }
}

proc ::tcl::debugger::CmdPrint {expression} {
    variable stopFrame
    Out [uplevel "#$stopFrame" [list expr $expression]]
}

proc ::tcl::debugger::SourceLines {file} {
    variable sourceCache
    if {![info exists sourceCache($file)]} {
	if {[catch {open $file r} chan]} {
	    set sourceCache($file) {}
	} else {
	    set sourceCache($file) [split [read $chan] \n]
	    close $chan
	}
    }
    return $sourceCache($file)
}

proc ::tcl::debugger::SourceLine {file lineNo} {
    set lines [SourceLines $file]
    if {$lineNo < 1 || $lineNo > [llength $lines]} {
	return {}
    }
    return [lindex $lines [expr {$lineNo - 1}]]
}

proc ::tcl::debugger::CmdList {arg} {
    variable curFile
    variable curLine
    variable listLine
    if {$curFile eq {}} {
	Out "No source file."
	return
    }
    set lines [SourceLines $curFile]
    if {[llength $lines] == 0} {
	Out "No source for $curFile."
	return
    }
    if {$arg ne {}} {
	if {![string is integer -strict $arg]} {
	    Out "usage: list ?line?"
	    return
	}
	set first [expr {$arg - 5}]
    } elseif {$listLine > 0} {
	set first $listLine
    } else {
	set first [expr {$curLine - 5}]
    }
    if {$first < 1} {
	set first 1
    }
    set last [expr {$first + 9}]
    for {set i $first} {$i <= $last && $i <= [llength $lines]} {incr i} {
	set marker [expr {$i == $curLine ? "*" : " "}]
	Out [format "%5d%s\t%s" $i $marker \
		[lindex $lines [expr {$i - 1}]]]
    }
    set listLine $i
}

proc ::tcl::debugger::CmdQuit {args} {
    variable quitRequested 1
}

proc ::tcl::debugger::CmdHelp {args} {
    Out "Debugger commands (unique prefixes accepted):"
    Out "  run                 run the script"
    Out "  break ?file:?line   set a breakpoint (alias: b)"
    Out "  delete ?id ...?     delete breakpoints (all if no id)"
    Out "  disable id ...      disable breakpoints"
    Out "  enable id ...       enable breakpoints"
    Out "  info breakpoints    list breakpoints"
    Out "  continue            resume execution (alias: c)"
    Out "  step                stop at the next command (alias: s)"
    Out "  next                step over calls (alias: n)"
    Out "  finish              run until the current procedure returns"
    Out "  where, bt           show the call stack"
    Out "  print expr          evaluate an expression (alias: p)"
    Out "  list ?line?         show source (alias: l)"
    Out "  quit                exit the debugger (alias: q)"
    Out "Anything else is evaluated as a Tcl command in the current frame."
}
