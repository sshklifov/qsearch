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
    if stridx(a:file, dir) >= 0
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

function! s:ShowItems(title)
  if empty(s:items)
    echo "No entries"
  elseif len(s:items) == 1
    if has_key(s:items[0], 'bufnr')
      exe "b " . s:items[0].bufnr
    elseif has_key(s:items[0], 'filename')
      exe "edit " . s:items[0].filename
    endif
    if has_key(s:items[0], 'lnum')
      exe s:items[0].lnum
    endif
  else
    call setqflist([], ' ', #{title: a:title, items: s:items})
    copen
  endif
  unlet s:items
endfunction

function! QuickGrep(regex, where)
  function! Itemize(index, match)
    let sp = split(a:match, ":")
    if len(sp) < 3
      return {}
    endif
    if !filereadable(sp[0]) || s:ExcludeFile(sp[0])
      return {}
    endif
    if sp[1] !~ '^[0-9]\+$'
      return {}
    endif
    return {"filename": sp[0], "lnum": sp[1], 'text': join(sp[2:-1], ":")}
  endfunction

  let s:items = []
  function! CollectItems(id, data, event)
    let s:items += filter(map(a:data, funcref("Itemize")), "!empty(v:val)")
  endfunction

  let cmd = ['grep']
  " Apply 'smartcase' to the regex
  if a:regex !~# "[A-Z]"
    let cmd = cmd + ['-i']
  endif
  let cmd = cmd + ['-I', '-H', '-n', a:regex]
  let opts = #{on_stdout: funcref('CollectItems'), on_exit: {-> s:ShowItems("Grep")}}

  if type(a:where) == v:t_list
    let cmd = ['xargs'] + cmd
    let id = jobstart(cmd, opts)
    call chansend(id, a:where)
    call chanclose(id, 'stdin')
    return id
  elseif isdirectory(a:where)
    let cmd = cmd + ['-R', a:where]
    return jobstart(cmd, opts)
  else
    let fullpath = fnamemodify(a:where, ":p")
    let cmd = cmd + [fullpath]
    return jobstart(cmd, opts)
  endif
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

function! QuickFind(dir, ...)
  let s:items = []
  function! CollectItems(id, data, event)
    let files = filter(a:data, "filereadable(v:val)")
    let s:items += map(files, "#{filename: v:val}")
  endfunction

  let cmd = s:CmdFind(a:dir, a:000)
  let opts = #{on_stdout: funcref('CollectItems'), on_exit: {-> s:ShowItems('Find')}}
  return jobstart(cmd, opts)
endfunction

function Find(dir, ...)
  let cmd = s:CmdFind(a:dir, a:000)
  return systemlist(cmd)
endfunction

function! s:ListCmd(args)
  let dir = a:args
  if empty(dir)
    let dir = getcwd()
  endif
  call Quickfind(dir, '-maxdepth', 1)
endfunction

command! -nargs=? -complete=dir List call <SID>ListCmd(<q-args>)
