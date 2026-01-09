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

function s:LimitMatches(data)
  if len(a:data) > g:qsearch_max_matches
    call init#Warn("Got total %d matches, truncating...", len(a:data))
    return a:data[:g:qsearch_max_matches-1]
  endif
  return a:data
endfunction

function! s:ExcludeFile(file)
  for dir in g:qsearch_exclude_dirs
    if stridx(a:file, dir .. "/") >= 0
      return v:true
    endif
  endfor
  for file in g:qsearch_exclude_files
    if a:file[-len(file):-1] == file
      return v:true
    endif
  endfor
  return v:false
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

function! s:CollectGrepData(pat, exclude, b, _, data, _1)
  let data = s:LimitMatches(a:data)
  let items = []
  let stdin_mode = v:false
  for match in data
    let sp = split(match, ":")
    if len(sp) < 3 || sp[1] !~ '^[0-9]\+$'
      continue
    endif
    if sp[0] == "(standard input)"
      let stdin_mode = v:true
      let item = {"bufnr": a:b, "lnum": sp[1], 'text': join(sp[2:-1], ":")}
      call add(items, item)
    elseif filereadable(sp[0]) && !(a:exclude && s:ExcludeFile(sp[0]))
      let item = {"filename": sp[0], "lnum": sp[1], 'text': join(sp[2:-1], ":")}
      call add(items, item)
    endif
  endfor
  
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
  let cmd = cmd + ['-I', '-H', '-n', a:regex]
  let Cb = function('s:CollectGrepData', [a:regex, a:exclude, bufnr()])
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

function! qsearch#SearchFilter(list)
  return filter(a:list, "!s:ExcludeFile(v:val)")
endfunction

function! qsearch#IsExcluded()
  return s:ExcludeFile(expand("%:p"))
endfunction

function! qsearch#Grep(regex, where)
  call s:Grep(a:regex, a:where, v:true)
endfunction

function! qsearch#GrepNoExclude(regex, where)
  call s:Grep(a:regex, a:where, v:false)
endfunction

function! s:GrepFilesInQuickfix(regex)
  let files = map(getqflist(), 'expand("#" . v:val.bufnr . ":p")')
  let files = uniq(sort(files))
  call qsearch#Grep(a:regex, files)
endfunction

" Current buffer
command! -nargs=1 Grep call qsearch#Grep(<q-args>, bufnr())
" All files in quickfix
command! -nargs=1 Grepfix call <SID>GrepFilesInQuickfix(<q-args>)
" Current path
command! -nargs=1 Rgrep call qsearch#Grep(<q-args>, getcwd())

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

function! s:CollectFindData(exclude, _0, data, _1)
  let data = a:data
  if a:exclude
    let data = filter(data, '!s:ExcludeFile(v:val)')
  endif
  let data = filter(data, 'filereadable(v:val)')
  let items = map(data, '#{filename: v:val}')
  let data = s:LimitMatches(data)
  call qutil#DropInQuickfix(items, "Find")
endfunction

function! s:WrapFindData(cb, _0, data, _1)
  let data = filter(a:data, '!s:ExcludeFile(v:val) && filereadable(v:val)')
  let data = s:LimitMatches(data)
  let Cb = function(a:cb)
  return Cb(data)
endfunction

function! qsearch#Find(dir, ...)
  let cmd = s:CmdFind(a:dir, a:000)
  let opts = #{stdout_buffered: 1, on_stdout: function('s:CollectFindData', [v:true])}
  return s:JobStartOne(cmd, opts)
endfunction

function qsearch#OnFiles(dir, flags, cb)
  let cmd = s:CmdFind(a:dir, a:flags)
  let opts = #{stdout_buffered: 1, on_stdout: function('s:WrapFindData', [a:cb])}
  return s:JobStartOne(cmd, opts)
endfunction

function qsearch#GetFiles(dir, ...)
  let cmd = s:CmdFind(a:dir, a:000)
  let ret = systemlist(cmd)
  let ret = filter(ret, '!s:ExcludeFile(v:val)')
  return s:LimitMatches(ret)
endfunction
