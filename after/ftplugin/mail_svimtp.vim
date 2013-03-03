setlocal completefunc=CompleteEmailAddrs
if exists("g:loaded_after_mail")
	finish
endif
let g:loaded_after_mail = 1
" configuration settings. "{{{
" SMTP configuration"{{{
" Format is as follows: lines consisting of key = value where"
" key is one of {host,username,password,replyto}. Whitespace *is needed*
" around the equals sign.  Sorry.  Here is an example file: "
" ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ "
" host = smtp.gmail.com
" username = my.usual.address@gmail.com
" password = worst_password_evahhhh
" replyto = my.usual.address@gmail.com
" ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ "
" If you need to specify a different port, just put it at the "
" end of the host, prefixed with a colon, e.g., example.com:466 "
let s:SMTPconfigfile = '~/.svimtp'

" If you want to auto complete email addresses, place them in the
" following file.
let s:address_complfile = '~/.svimtp_addrs'
" The format is simply a list of the email addresses, one per line,
" formatted similar to the RFC 822 specifications, for example:
" Indiana Jones <indy.jones@jones.net>

" If you download your gmail contacts, say in the 'google csv' format,
" the following line will get you something close to what you want, but
" you'll probably want to look through and do a few edits:
" cat google.csv | awk -F, 'NR!=1 {print $1" <"$29">"}' > .svimtp_addrs

" we'll try to read the file up front:
if filereadable(expand(s:address_complfile))
	let s:addrlist = readfile(expand(s:address_complfile))
else
	let s:addrlist = []
endif
"}}}
" Auto-completion settings"{{{
" This value controls how matching of email addresses is done.
let g:SviMTPMatchStrictness = 1
" Here's how to interpret the values:
" 0 --- looks for matches *anywhere in the string* (probably not
" 		all that useful)
" 1 --- (the default setting) looks for matches at the beginning of
" 		any word, but not after '@' or '.' symbols. (This is kinder to
" 		all those poor people whose name starts with 'com' or 'gmail'.)
" 2 --- matches at the start of the friendly name, or the start of
" 		the email address (the part after the "<")
" 3 --- matches *only* the start of the friendly name (might be useful
" 		if you have a very long list of contacts.)
"}}}
"}}}
" mappings"{{{
nnoremap <buffer> <silent> <localleader>s :call <SID>SendMail_SSL()<CR>
nnoremap <buffer> <silent> <localleader><localleader>s :call <SID>SendMail_SSL(1)<CR>
nnoremap <buffer> <localleader>a :AttachFile 
nnoremap <buffer> <silent> <localleader>A :call <SID>showAttachmentStack()<CR>
nnoremap <buffer> <silent> <localleader>r :call <SID>popAttachment(0)<CR>
nnoremap <buffer> <silent> <localleader>R :call <SID>popAttachment(1)<CR>
command! -nargs=0 SendMailSSL call s:SendMail_SSL()
command! -nargs=+ -complete=file AttachFile  call s:pushAttachment(<f-args>)
command! -nargs=0 PopAttachment  call s:popAttachment(1)
command! -nargs=0 ShowAttachments  call s:showAttachmentStack()
"}}}
" completion of addresses"{{{
" basic completion function"{{{
function! CompleteEmailAddrs(findstart, base)
	if a:findstart
		let line = getline('.')
		let start = col('.') - 1
		while start > 0 && line[start - 1] =~ '\a'
			let start -= 1
		endwhile
		return start
	endif
	" find matching addresses:
	let s:res = []
	let s:count = 0
	let filter = 
		\ ['','\(@\|\.\)\@<!\<\zs','\(^\|<\)\zs','^'][g:SviMTPMatchStrictness] . a:base
	for m in s:addrlist
		if m =~ filter
			call add(s:res, {"word": m, "icase": 1})
			let s:count = s:count+1
		endif
	endfor
	return s:res
endfunction
"}}}
" Supertab configuration"{{{
" Documentation: see
" *supertab-contextdiscover*
" *supertab-contextexample*
" *supertab-completioncontexts*
function MyMailContext()
	let lmatch = search('^\S\+\|^$','bnW', line('.') > 64 ? line('.') - 64 : 0)
	if lmatch && getline(lmatch) =~? '^\(to\|cc\|bcc\|from\):'
		return "\<c-x>\<c-u>"
	endif
	" otherwise, let it fall through to the next completion context.
	return
endfunction
let g:SuperTabCompletionContexts =
\ ['MyMailContext', 's:ContextText', 's:ContextDiscover']
"}}}
"}}}
" Send mail using SMTP over an SSL connection"{{{
function s:SendMail_SSL(...)
	if !has('python')
		echo "Vim must be compiled with +python to use this feature."
		return 1
	endif
	" Do a quick (and extremely crude) sanity check to make
	" sure there is something that looks like a message header
	" and body in the first 128 lines:
	let cline = line('.')
	let ccol = col('.')
	call cursor(1,1)
	try
		let hbDelimiter = search('^$','W',128)
		if hbDelimiter < 2 || search('\S','nW') == 0
			let sendAnyway = 
				\ input("Message body appears to be empty, send anyway? (y/n) ")
			if sendAnyway !~? 'y'
				" clear the prompt before printing another message:
				normal! :<Esc>
				echo "Message not sent."
				return 1
			endif
		endif
	finally
		call cursor(cline,ccol)
	endtry

	" read the config files here and use an eval (vim.eval)"
	" statement in python, or just read them from python."
	" read/write files might be easiest in vim; use writefile(list,.)"
	let smtprc = s:freadDictionary(s:SMTPconfigfile)
	if smtprc == {}
		echo "No SMTP configuration found. (See after/mail_svimtp.vim)"
		return 1
	endif
	" now load the list of attachments, if any:
	let attachList = []
	if exists("s:att_list_tmpfile")
		let attachList = readfile(s:att_list_tmpfile)
	endif
	" we'll let the python code set this variable to tell us
	" whether or not the email was sent
	let fail = 1  " very optimistic.

python << EOF
import vim
import os
import glob as G
import smtplib
import email
import mimetypes
from email.mime.text import MIMEText
from email.mime.image import MIMEImage
from email.mime.audio import MIMEAudio
from email.mime.multipart import MIMEMultipart
from email.mime.base import MIMEBase

# first, get the contents of the current buffer:
buftext = "\n".join(vim.current.buffer)
aList = vim.eval("attachList")
msg = email.message_from_string(buftext)
vsmtprc = vim.eval("smtprc")
if msg['from'] is None:
    msg['from'] = vsmtprc['replyto']

if len(aList) > 0:
    # need to make a multi=part message.
    msgmp = MIMEMultipart()
    for k in msg.keys(): # steal the headers
        msgmp[k] = msg[k]
    # now make a text only message with the body
    body = MIMEText(msg.get_payload(),"plain")
    msgmp.attach(body)
    # First expand the list of attachments, in case it contains
    # shell globs.  We also need to expand the home directory
    expanded = []
    for att in aList:
        att = os.path.expanduser(att)
        expanded.extend(G.glob(att))
    # at this point, expanded has the final list of attachments.
    for att in expanded:
        if not os.path.isfile(att):
            # NOTE: this case should have been taken care of
            # by the glob(...) above.
            print "Warning: " + att + " not found."
            continue
        ctype,encoding = mimetypes.guess_type(att)
        if ctype is None or encoding is not None:
            ctype = "application/octet-stream"
        maintype,subtype = ctype.split("/",1)
        f = open(att,'rb')
        if maintype == "text":
            aMsg = MIMEText(f.read(), _subtype=subtype)
        elif maintype == "image":
            aMsg = MIMEImage(f.read(), _subtype=subtype)
        elif maintype == "audio":
            aMsg = MIMEAudio(f.read(), _subtype=subtype)
        else:
            aMsg = MIMEBase(maintype, subtype)
            aMsg.set_payload(f.read())
            email.encoders.encode_base64(aMsg)

        f.close()
        aMsg.add_header('Content-Disposition', 'attachment',
            filename=os.path.basename(att))
        msgmp.attach(aMsg)

    # we no longer need the original msg, so just overwrite:
    msg = msgmp

# by now, we should have a propery formatted message. Send it.
try:
    s = smtplib.SMTP_SSL()
	# s.set_debuglevel(1) # if you need to debug the connection.
    print "Connecting to " + vsmtprc['host'] + " ..."
    s.connect(vsmtprc['host'])
    print "Connected."
    # according to the docs, an explicit ehlo isn't necessary, but my server
    # won't accept a subsequent auth (login) without it:
    s.ehlo("localhost")
    print "Authenticating..."
    s.login(vsmtprc['username'],vsmtprc['password'])
    print "Authentication succeeded; sending mail."
    s.sendmail(msg['from'],msg['to'].split(","),msg.as_string())
    print "Message sent."
    vim.command("let fail = 0") # wow. we didn't fail after all.
    if len(aList) > 0:
        vim.command("unlet s:att_list_tmpfile") # clear attachment list
except smtplib.SMTPConnectError:
    print "Unable to connect to server."
except smtplib.SMTPServerDisconnected:
    print "Connection unexpectedly closed by server."
except smtplib.SMTPSenderRefused as sme:
    print "Sender address " + sme.sender + " refused:"
    print sme.smtp_error
except smtplib.SMTPRecipientsRefused as sme:
    print "One or more recipients refused:"
    print sme.recipients
except smtplib.SMTPDataError as sme:
    print "Data error: " + str(sme.smtp_code) + ": " + sme.smtp_error
except smtplib.SMTPHeloError as sme:
    print "Cranky-pants server refused HELO for some reason."
    print str(sme.smtp_code) + ": " + sme.smtp_error
except smtplib.SMTPAuthenticationError as sme:
    print "Authentication error:"
    print str(sme.smtp_code) + ": " + sme.smtp_error
finally:
    s.quit() # close the connection

# Notes on debugging your SMTP connection:
# the exceptions raised might tell you enough, but if not, use
# s.set_debuglevel(1) to get more details.  You can review the
# output with the :messages command.
EOF

	if !fail && a:0 && a:1
		q!
	endif
	return fail

endfunction
"}}}
" reading / writing dictionaries to disk"{{{
function s:fwriteDictionary(fname,dnary)
	let tmpitems = items(a:dnary)
	call map(tmpitems,'v:val[0] . "=" . v:val[1]')
	call writefile(tmpitems,expand(a:fname))
endfunction
function s:freadDictionary(fname)
	let dnary = {}
	let fnamefull = expand(a:fname)
	if !filereadable(fnamefull)
		return dnary
	endif
	let rlist = readfile(fnamefull)
	call map(rlist,'split(v:val,"\\s\\+=\\s\\+")')
	" if the file was properly formatted, we'll now have a list of lists
	" with each list of the form [key,value]
	for [key,val] in rlist
		let dnary[key] = val
	endfor
	return dnary
endfunction
"}}}
" functions for building an attachment list {{{
function s:pushAttachment(...) "{{{
	if a:0 == 0 || a:1 == ""
		return
	endif
	if !exists("s:att_list_tmpfile")
		let s:att_list_tmpfile = tempname()
	endif
	" this is a little annoying: vim script doesn't have a clean way
	" to append to a file.
	let tmpList = []
	if filereadable(s:att_list_tmpfile)
		let tmpList = readfile(s:att_list_tmpfile)
	endif
	for fname in a:000
		call add(tmpList, fname)
	endfor
	call writefile(tmpList,s:att_list_tmpfile)
endfunction
"}}}
function s:popAttachment(mode) "{{{
	let tlist = []
	if exists("s:att_list_tmpfile")
		let tlist = readfile(s:att_list_tmpfile)
	endif
	if tlist == []
		echohl WarningMsg
		echon "Attachment list is empty"
		echohl None
		return
	endif
	if a:mode == 0
		let indxToRemove = len(tlist) - 1
	else
		" now dump the contents of the stack into a numbered list and
		" let the user select an item to remove.
		let tlPrompt = deepcopy(tlist)
		call map(tlPrompt,'v:key . ". " . v:val')
		let prompt = "Select item to pop:\n" . join(tlPrompt,"\n") . "\n"
		let indxToRemove = input(prompt)
		if indxToRemove == ""
			return
		endif
	endif
	" echo and remove element:
	echo "Popped: " . remove(tlist,indxToRemove)
	" now write back to the file.
	call writefile(tlist,s:att_list_tmpfile)
	" One would hope that popping a stack would run in O(1) time.
	" I guess this isn't so bad, since we are drawing it all the time anyway.
	return
endfunction
"}}}
function s:showAttachmentStack() "{{{
	" load the attachment stack into the location list.
	let tlist = []
	if exists("s:att_list_tmpfile")
		let tlist = readfile(s:att_list_tmpfile)
	endif
	if tlist == []
		echohl WarningMsg
		echon "Attachment list is empty"
		echohl None
		return
	endif
	call setloclist(0,[]) " first clear it out.
	for ditem in tlist
		laddexpr ditem
	endfor
	lopen
	" call s:ToggleList("Location List", 'l')
endfunction
"}}}
"}}}
