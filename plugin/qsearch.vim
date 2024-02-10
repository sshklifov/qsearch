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

function! s:OpenQfResults()
  let len = getqflist({"size": 1})['size']
  if len <= 0
    echo "No entries"
  elseif len == 1
    cc
  else
    copen
  endif
endfunction

function! Grep(regex, where)
  call setqflist([], ' ', {'title' : 'Grep', 'items' : []})

  function! OnEvent(id, data, event)
    function! GetGrepItem(index, match)
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
    let items = filter(map(a:data, function("GetGrepItem")), "!empty(v:val)")
    call setqflist([], 'a', {'items' : items})
  endfunction

  let cmd = ['grep']
  " Apply 'smartcase' to the regex
  if a:regex !~# "[A-Z]"
    let cmd = cmd + ['-i']
  endif
  let cmd = cmd + ['-I', '-H', '-n', a:regex]

  if type(a:where) == v:t_list
    let cmd = ['xargs'] + cmd
    let id = jobstart(cmd, {'on_stdout': function('OnEvent') } )
    call chansend(id, a:where)
  else
    let cmd = cmd + ['-R', a:where]
    let id = jobstart(cmd, {'on_stdout': function('OnEvent') } )
  endif

  call chanclose(id, 'stdin')
  call jobwait([id])
  call s:OpenQfResults()
endfunction

function! s:GrepQuickfixFiles(regex)
  let files = map(getqflist(), 'expand("#" . v:val["bufnr"] . ":p")')
  let files = uniq(sort(files))
  call s:Grep(a:regex, files)
endfunction

" Current buffer
command! -nargs=1 Grep call <SID>Grep(<q-args>, [expand("%:p")])
" All files in quickfix
command! -nargs=1 Cgrep call <SID>GrepQuickfixFiles(<q-args>)
" Current path
command! -nargs=1 Rgrep call <SID>Grep(<q-args>, getcwd())

function! Find(dir, arglist, Cb)
  if empty(a:dir)
    return
  endif

  " Add exclude paths flags
  let flags = []
  for dir in g:qsearch_exclude_dirs
    let flags = flags + ["-path", "**/" . dir, "-prune", "-false", "-o"]
  endfor
  for file in g:qsearch_exclude_files
    let flags = flags + ["-not", "-name", file]
  endfor

  " Exclude directorties from results
  let flags = flags + ["-type", "f"]
  " Add user flags
  let flags = flags + a:arglist
  " Add actions (ignore binary files)
  let flags = flags + [
        \ "-exec", "grep", "-Iq", ".", "{}", ";",
        \ "-print"
        \ ]

  let cmd = ["find",  fnamemodify(a:dir, ':p')] + flags
  let id = jobstart(cmd, {'on_stdout': a:Cb})
  call chanclose(id, 'stdin')
  return id
endfunction

function! FindInQuickfix(dir, pat, ...)
  function! PopulateQuickfix(id, data, event)
    let files = filter(a:data, "filereadable(v:val)")
    let items = map(files, {_, f -> {'filename': f, 'lnum': 1, 'col': 1, 'text': fnamemodify(f, ':t')} })
    call setqflist([], 'a', {'items' : items})
  endfunction

  let flags = []
  if !empty(a:pat)
    let regex = ".*" . a:pat . ".*"
    " Apply 'smartcase' to the regex
    if regex =~# "[A-Z]"
      let flags = ["-regex", regex]
    else
      let flags = ["-iregex", regex]
    endif
  endif
  " Add user args (optional)
  let flags += get(a:, 1, [])

  " Perform find operation
  call setqflist([], ' ', {'title' : 'Find', 'items' : []})
  let id = s:Find(a:dir, flags, function("PopulateQuickfix"))
  call jobwait([id])
  call s:OpenQfResults()
endfunction

function! s:FindInWorkspace(pat)
  if exists("*FugitiveWorkTree")
    let dir = FugitiveWorkTree()
    if empty(dir)
      echo "Not in workspace"
    else
      call s:FindInQuickfix(dir, a:pat)
    endif
  endif
endfunction

command! -nargs=0 List call <SID>FindInQuickfix(getcwd(), "", ['-maxdepth', 1])
command! -nargs=1 -complete=dir Find call <SID>FindInQuickfix(<q-args>, "")
command! -nargs=? Workspace call <SID>FindInWorkspace(<q-args>)
