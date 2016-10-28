REBOL [
	Title:   "Compilation directives processing"
	Author:  "Nenad Rakocevic"
	File: 	 %preprocessor.r
	Tabs:	 4
	Rights:  "Copyright (C) 2016 Nenad Rakocevic. All rights reserved."
	License: "BSD-3 - https://github.com/red/red/blob/master/BSD-3-License.txt"
]
Red []													;-- make it usable by Red too.

preprocessor: context [
	exec:	none										;-- object that captures directive words
	protos: make block! 10
	macros: make block! 10
	stack:	make block!	10
	syms:	make block! 20
	depth: 	0											;-- track depth of recursive macro calls
	active?: yes
	s: none
	
	do-quit: does [
		either all [rebol system/options/args][quit/return 1][halt]
	]
	
	throw-error: func [error [error!] cmd [issue!] code [block!] /local w][
		prin ["*** Preprocessor Error in" mold cmd lf]
		
		#either none? config [							;-- config is none when preprocessor is applied to itself
			error: disarm error
			error/where: new-line/all reduce [cmd] no
			
			foreach w [arg1 arg2 arg3][
				set w either unset? get/any in error w [none][
					get/any in error w
				]
			]
			print [
				"***" system/error/(error/type)/type #":"
				reduce system/error/(error/type)/(error/id) newline
				"*** Where:" mold/flat error/where newline
				"*** Near: " mold/flat error/near newline
			]
			do-quit
		][
			error/where: new-line/all reduce [cmd] no
			print form :error
			halt
		]
	]
	
	syntax-error: func [s [block! paren!] e [block! paren!]][
		print [
			"*** Preprocessor Error: Syntax error^/"
			"*** Where:" trim/head mold/only copy/part s next e
		]
		do-quit
	]
	
	do-safe: func [code [block!] /with cmd [issue!] /local res][
		#process off
		if error? set/any 'res try code [throw-error res any [cmd #macro] code]
		#process on
		either unset? get/any 'res [[]][res]
	]
	
	do-code: func [code [block!] cmd [issue!] /local p][
		clear syms
		parse code [any [
			p: set-word! (unless in exec p/1 [append syms p/1])
			| skip
		]]
		unless empty? syms [exec: make exec append syms none]
		do-safe bind code exec
	]
	
	count-args: func [spec [block!] /local total][
		total: 0
		parse spec [
			any [
				[word! | lit-word! | get-word!] (total: total + 1)
				| refinement! (return total)
			]
		]
		total
	]
	
	func-arity?: func [spec [block!] /with path [path!] /local arity pos][
		arity: count-args spec
		if path [
			foreach word next path	[
				unless pos: find/tail spec to refinement! word [
					print [
						"*** Macro Error: unknown refinement^/"
						"*** Where:" mold path
					]
					do-quit
				]
				arity: arity + count-args pos
			]
		]
		arity
	]
	
	fetch-next: func [code [block!] /local base arity value path][
		base: code
		arity: 1
		
		while [arity > 0][
			arity: arity + either all [
				not tail? next code
				word? value: code/2
				op? get/any value
			][
				code: next code
				1
			][
				either all [
					find [word! path!] type?/word value: code/1
					value: either word? value [value][first path: value]
					any-function? get/any value
				][
					either path [
						func-arity?/with spec-of get value path
					][
						func-arity? spec-of get value
					]
				][0]
			]
			code: next code
			arity: arity - 1
		]
		code
	]
	
	eval: func [code [block!] cmd [issue!] /local after expr][
		after: fetch-next code
		expr: copy/part code after
		expr: do-code expr cmd
		reduce [expr after]
	]
	
	do-macro: func [name pos [block! paren!] arity [integer!] /local cmd saved res][
		depth: depth + 1
		saved: s
		parse next pos [arity [s: macros | skip]]		;-- resolve nested macros first
		s: saved
		
		cmd: make block! 1
		append cmd name
		insert/part tail cmd next pos arity
		if unset? set/any 'res do bind cmd exec [
			print ["*** Macro Error: no value returned by" name "macro^/"]
			do-quit
		]
		s/1: :res
		
		if positive? depth: depth - 1 [
			saved: s
			parse s macros								;-- apply macros to result
			s: saved
		]
		s/1
	]
	
	register-macro: func [spec [block!] /local cnt rule p name macro pos][
		cnt: 0
		rule: make block! 10
		unless parse spec/3 [
			any [
				opt string! 
				word! (cnt: cnt + 1)
				opt [
					p: block! :p into [some word!]
						;(append/only rule make block! 1)
						;some [p: word! (append last rule p/1)]
						;(append rule '|)
					;]
				]
				opt [/local some word!]
			]
		][
			print [
				"*** Macro Error: invalid specification^/"
				"*** Where:" mold copy/part spec 3
			]
			do-quit
		]
		either set-word? spec/1 [						;-- named macro
			repend rule [
				name: to lit-word! spec/1
				to-paren compose [change/part s do-macro (:name) s (cnt) (cnt + 1)]
				to get-word! 's
			]
			append protos copy/part spec 4
		][												;-- pattern-matching macro
			macro: do bind copy/part next spec 3 exec
			append/only protos spec/4
			
			repend rule [
				to set-word! 's
				bind spec/1 'self						;-- allow rule to reference exec's words
				to set-word! 'e
				to-paren compose/deep [s: do-safe [(:macro) s e]]
				to get-word! 's
			]
		]
		
		pos: tail macros
		either tag? macros/1 [remove macros][append macros '|]
		append macros rule
		new-line pos yes
		
		exec: make exec protos
	]

	reset: func [job [object! none!]][
		exec: do [context [config: job]]
		clear protos
		insert clear macros <none>						;-- required to avoid empty rule (causes infinite loop)
	]

	expand: func [
		code [block!] job [object! none!]
		/keep
		/local rule e pos cond value then else cases body keep? expr
	][	
		unless keep [reset job]

		#process off
		parse code rule: [
			any [
				s: macros
				| 'routine 2 skip						;-- avoid overlapping with R/S preprocessor
				| #system skip
				| #system-global skip
				
				| s: #include (
					if all [active? not Rebol system/state/interpreted?][s/1: 'do]
				)
				| s: #if (set [cond e] eval next s s/1) :e [set then block! | (syntax-error s e)] e: (
					if active? [either cond [change/part s then e][remove/part s e]]
				) :s
				| s: #either (set [cond e] eval next s s/1) :e 
					[set then block! set else block! | (syntax-error s e)] e: (
						if active? [either cond [change/part s then e][change/part s else e]]
				) :s
				| s: #switch (set [cond e] eval next s s/1) :e [set cases block! | (syntax-error s e)] e: (
					if active? [
						body: any [select cases cond select cases #default]
						unless block? body [syntax-error body next body]
						either body [change/part s body e][remove/part s e]
					]
				) :s
				| s: #case [set cases block! | e: (syntax-error s e)] e: (
					if active? [
						until [
							set [cond cases] eval cases s/1
							unless block? cases [syntax-error cases next cases]
							any [cond tail? cases: next cases]
						]
						either cond [change/part s cases/1 e][remove/part s e]
					]
				) :s
				| s: #do (keep?: no) opt ['keep (keep?: yes)] [block! | (syntax-error s next s)] e: (
					if active? [
						pos: pick [3 2] keep?
						expr: do-code s/:pos s/1
						either keep? [s: change/part s expr e][remove/part s e]
					]
				) :s
				| s: #local [block! | (syntax-error s next s)] e: (
					repend stack [tail macros tail protos]
					change/part s expand/keep s/2 job e
					loop 2 [clear take/last stack]
				)
				| s: #reset (reset job remove s) :s
				
				| s: #process [[
					  'on  (active?: yes remove/part s 2) :s
					| 'off (active?: no  remove/part s 2) :s [to #process | to end]
				] | (syntax-error s next s)]
				
				| s: #macro [
					[set-word! | word! | block!]['func | 'function] block! block! 
					| (syntax-error s skip s 4)
				] e: (
					register-macro next s
					remove/part s e
				) :s
				| pos: [block! | paren!] :pos into rule
				| skip
			]
		]
		#process on
		code
	]
	
	set 'expand-directives func [						;-- to be called from Red only
		code [block!]
	][
		expand code system/build/config
	]
]