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

function! SearchFilter(list)
  return filter(a:list, "!s:ExcludeFile(v:val)")
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
  let s:job_id = jobstart(a:cmd, a:opts)
  return s:job_id
endfunction

function! s:CollectGrepData(pat, exclude, _0, data, _1)
  let items = []
  for match in a:data
    let sp = split(match, ":")
    if len(sp) < 3 || !filereadable(sp[0]) || sp[1] !~ '^[0-9]\+$'
      continue
    endif
    if a:exclude && s:ExcludeFile(sp[0])
      continue
    endif
    let item = {"filename": sp[0], "lnum": sp[1], 'text': join(sp[2:-1], ":")}
    call add(items, item)
  endfor
  
  call map(items, 's:AddBuffer(v:val)')
  call map(items, 's:AddColumn(v:val, a:pat)')
  call DropInQf(items, "Grep")
endfunction

function! s:Grep(regex, where, exclude)
  let cmd = ['grep']
  " Apply 'smartcase' to the regex
  if a:regex !~# "[A-Z]"
    let cmd = cmd + ['-i']
  endif
  let cmd = cmd + ['-I', '-H', '-n', a:regex]
  let opts = #{stdout_buffered: 1, on_stdout: function('s:CollectGrepData', [a:regex, a:exclude])}

  if type(a:where) == v:t_list
    let cmd = ['xargs'] + cmd
    let id = s:JobStartOne(cmd, opts)
    call chansend(id, a:where)
    call chanclose(id, 'stdin')
    return id
  elseif isdirectory(a:where)
    let cmd = cmd + ['-R', a:where]
    return s:JobStartOne(cmd, opts)
  else
    let fullpath = fnamemodify(a:where, ":p")
    let cmd = cmd + [fullpath]
    return s:JobStartOne(cmd, opts)
  endif
endfunction

function! QuickGrep(regex, where)
  call s:Grep(a:regex, a:where, v:true)
endfunction

function! QuickGrepNoExclude(regex, where)
  call s:Grep(a:regex, a:where, v:false)
endfunction

function! s:GrepFilesInQuickfix(regex)
  let files = map(getqflist(), 'expand("#" . v:val.bufnr . ":p")')
  let files = uniq(sort(files))
  call QuickGrep(a:regex, files)
endfunction

" Current buffer
command! -nargs=1 Grep call QuickGrep(<q-args>, expand("%:p"))
" All files in quickfix
command! -nargs=1 Grepfix call <SID>GrepFilesInQuickfix(<q-args>)
" Current path
command! -nargs=1 Rgrep call QuickGrep(<q-args>, getcwd())

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
  let items = []
  for file in a:data
    if !filereadable(file)
      continue
    endif
    if a:exclude && s:ExcludeFile(file)
      continue
    endif
    call add(items, #{filename: file})
  endfor
  call DropInQf(items, "Find")
endfunction

function! QuickFind(dir, ...)
  let cmd = s:CmdFind(a:dir, a:000)
  let opts = #{stdout_buffered: 1, on_stdout: function('s:CollectFindData', [v:true])}
  return s:JobStartOne(cmd, opts)
endfunction

function! QuickFindNoExclude(dir, ...)
  let cmd = s:CmdFind(a:dir, a:000)
  let opts = #{stdout_buffered: 1, on_stdout: function('s:CollectFindData', [v:false])}
  return s:JobStartOne(cmd, opts)
endfunction

function GetFiles(dir, ...)
  let cmd = s:CmdFind(a:dir, a:000)
  let ret = systemlist(cmd)
  return filter(ret, '!s:ExcludeFile(v:val)')
endfunction

function GetFilesNoExclude(dir, ...)
  let cmd = s:CmdFind(a:dir, a:000)
  return systemlist(cmd)
endfunction
