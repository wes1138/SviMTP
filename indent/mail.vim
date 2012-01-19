" improved (but very simplistic) indentation for the mail filetype.
" See RFC 2822 sections 2.2.3 and 3.2.3 regarding "folding whitespace".
" http://www.ietf.org/rfc/rfc2822.txt
if exists("b:did_indent")
	finish
endif
let b:did_indent = 1

setlocal autoindent nosmartindent nocindent indentexpr=GetMailIndent(v:lnum)
setlocal indentkeys+=<:>

if exists("*GetMailIndent")
  finish
endif

function GetMailIndent(lnum)
	" Note: the subject line is intentionally excluded from the list,
	" since it would usually be annoying, even if legal in RFC2822.
	let headerExprBase = '\(from\|reply-to\|to\|cc\|bcc\|subject\|date\):'
	let headerExprFront = '^' . headerExprBase
	let headerExprInd = '^\s*' . headerExprBase
	" don't indent first line.
	if a:lnum == 1
		return -1
	endif
	" might need to re-indent a line in-progress:
	if getline(a:lnum) =~? headerExprInd || getline(a:lnum - 1) =~ '^\s*$'
		return 0
	endif
	" nothing special about the current line; check the line above.
	" if already indented and non-blank, let autoindent take over:
	if indent(a:lnum - 1)
		return -1
	endif
	" line above is not indented. If it is a to or from, or
	" subject line, indent it. According to RFC 2822, these have to be
	" indented by at least one whitespace character.
	if getline(a:lnum - 1) =~? headerExprFront
		return &sw
	endif
	return -1
endfunction
