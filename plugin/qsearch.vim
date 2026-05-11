" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

if exists(':Rgrep')
  finish
endif

if !exists('g:qsearch_exclude_dirs')
  let g:qsearch_exclude_dirs = []
endif

if !exists('g:qsearch_exclude_files')
  let g:qsearch_exclude_files = []
endif

if !exists('g:qsearch_max_matches')
  let g:qsearch_max_matches = 1000
endif

function s:LimitData(data)
  if len(a:data) > g:qsearch_max_matches
    call init#Warn("Got total %d matches, truncating...", len(a:data))
    return a:data[:g:qsearch_max_matches-1]
  endif
  return a:data
endfunction

function s:AddBuffer(item)
  let ret = a:item
  let ret['bufnr'] = bufadd(a:item.filename)
  return ret
endfunction

function s:AddColumn(item, regex)
  let ret = a:item
  if has_key(ret, 'lnum')
    call bufload(ret.bufnr)
    let str = getbufoneline(ret.bufnr, ret.lnum)
    let [_, col, end] = matchstrpos(str, a:regex)
    if col < 0
      let col = 0
    endif
    let ret['col'] = col + 1
  endif
  return ret
endfunction

let s:job_id = -1
function! s:JobStartOne(cmd, opts)
  if jobstop(s:job_id)
    call jobwait([s:job_id])
  endif
  let s:job_id = init#Jobstart(a:cmd, a:opts)
  return s:job_id
endfunction

function! s:CollectGrepData(pat, b, _, data, _1)
  let items = []
  let stdin_mode = v:false
  for match in a:data
    let sp = split(match, ":")
    if len(sp) < 3 || sp[1] !~ '^[0-9]\+$'
      continue
    endif
    if sp[0] == "(standard input)"
      let stdin_mode = v:true
      let item = {"bufnr": a:b, "lnum": sp[1], 'text': join(sp[2:-1], ":")}
      call add(items, item)
    elseif filereadable(sp[0])
      let item = {"filename": sp[0], "lnum": sp[1], 'text': join(sp[2:-1], ":")}
      call add(items, item)
    endif
  endfor
  let items = s:LimitData(items)
  
  if !stdin_mode
    call map(items, 's:AddBuffer(v:val)')
  endif
  call map(items, 's:AddColumn(v:val, a:pat)')
  call qutil#DropInQuickfix(items, "Grep")
endfunction

function! s:Grep(regex, where, exclude)
  let cmd = ['grep']
  " Apply 'smartcase' to the regex
  if a:regex !~# "[A-Z]"
    let cmd = cmd + ['-i']
  endif
  let cmd = cmd + ['-I', '-H', '-n']
  if a:exclude
    for dir in g:qsearch_exclude_dirs
      call add(cmd, '--exclude-dir=' .. dir)
    endfor
    for file in g:qsearch_exclude_files
      call add(cmd, '--exclude=' .. file)
    endfor
  endif
  call add(cmd, a:regex)
  let Cb = function('s:CollectGrepData', [a:regex, bufnr()])
  let opts = #{stdout_buffered: 1, on_stdout: Cb}

  if type(a:where) == v:t_list
    let cmd = ['xargs'] + cmd
    let id = s:JobStartOne(cmd, opts)
    call chansend(id, a:where)
    call chanclose(id, 'stdin')
    return id
  elseif isdirectory(a:where)
    let cmd = cmd + ['-R', a:where]
    return s:JobStartOne(cmd, opts)
  elseif str2nr(a:where) == a:where
    let id = s:JobStartOne(cmd, opts)
    let lines = getbufline(a:where, 1, '$')
    call chansend(id, lines)
    call chanclose(id, 'stdin')
    return id
  else
    let fullpath = fnamemodify(a:where, ":p")
    let cmd = cmd + [fullpath]
    return s:JobStartOne(cmd, opts)
  endif
endfunction

function! qsearch#Grep(regex, where)
  call s:Grep(a:regex, a:where, v:true)
endfunction

function! s:GrepFilesInQuickfix(bang, regex)
  let files = map(getqflist(), 'expand("#" . v:val.bufnr . ":p")')
  let files = uniq(sort(files))
  call s:Grep(a:regex, files, !empty(a:bang))
endfunction

" Current buffer
command! -nargs=1 -bang Grep call s:Grep(<q-args>, bufnr(), <bang>1)
" All files in quickfix
command! -nargs=1 -bang Grepfix call <SID>GrepFilesInQuickfix("<bang>", <q-args>)
" Current path
command! -nargs=1 -bang Rgrep call s:Grep(<q-args>, getcwd(), <bang>1)

function! s:CmdFind(dir, ...)
  " Add exclude paths flags
  let flags = []
  for dir in g:qsearch_exclude_dirs
    let flags = flags + ["-path", "**/" . dir, "-prune", "-false", "-o"]
  endfor
  for ff in g:qsearch_exclude_files
    let flags = flags + ["-not", "-name", ff]
  endfor

  " Exclude directorties from results
  let flags = flags + ["-type", "f"]
  " Add user flags
  if a:0 == 1 && type(a:1) == v:t_list
    let flags += a:1
  else
    let flags += a:000
  endif
  " Ignore executable files
  let flags = flags + ["-not", "-perm", "/111"]

  let fullpath = fnamemodify(a:dir, ':p')
  let cmd = ["find", fullpath] + flags
  return cmd
endfunction

function! s:CollectFindData(_0, data, _1)
  let data = filter(data, 'filereadable(v:val)')
  let data = LimitData(data)
  let items = map(data, '#{filename: v:val}')
  call qutil#DropInQuickfix(items, "Find")
endfunction

function! qsearch#Find(dir, ...)
  let cmd = s:CmdFind(a:dir, a:000)
  let opts = #{stdout_buffered: 1, on_stdout: function('s:CollectFindData')}
  return s:JobStartOne(cmd, opts)
endfunction

function! s:WrapOnFiles(cb, _0, data, _1)
  let data = filter(a:data, 'filereadable(v:val)')
  let data = s:LimitData(data)
  let Cb = function(a:cb)
  return Cb(data)
endfunction

function qsearch#OnFiles(dir, flags, cb)
  let cmd = s:CmdFind(a:dir, a:flags)
  let opts = #{stdout_buffered: 1, on_stdout: function('s:WrapOnFiles', [a:cb])}
  return s:JobStartOne(cmd, opts)
endfunction

function qsearch#GetFiles(dir, ...)
  let cmd = s:CmdFind(a:dir, a:000)
  let ret = systemlist(cmd)
  return s:LimitData(ret)
endfunction
