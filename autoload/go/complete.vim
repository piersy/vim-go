if !exists("g:go_gocode_bin")
    let g:go_gocode_bin = "gocode"
endif


fu! s:gocodeCurrentBuffer()
    let buf = getline(1, '$')
    if &encoding != 'utf-8'
        let buf = map(buf, 'iconv(v:val, &encoding, "utf-8")')
    endif
    if &l:fileformat == 'dos'
        " XXX: line2byte() depend on 'fileformat' option.
        " so if fileformat is 'dos', 'buf' must include '\r'.
        let buf = map(buf, 'v:val."\r"')
    endif
    let file = tempname()
    call writefile(buf, file)

    return file
endf


if go#vimproc#has_vimproc()
    let s:vim_system = get(g:, 'gocomplete#system_function', 'vimproc#system2')
else
    let s:vim_system = get(g:, 'gocomplete#system_function', 'system')
endif

fu! s:system(str, ...)
    return call(s:vim_system, [a:str] + a:000)
endf

fu! s:gocodeShellescape(arg)
    if go#vimproc#has_vimproc()
        return vimproc#shellescape(a:arg)
    endif
    try
        let ssl_save = &shellslash
        set noshellslash
        return shellescape(a:arg)
    finally
        let &shellslash = ssl_save
    endtry
endf
fu! s:goPackagesCompletion()
    "Check if we are in a string that maps to an import path"
    let currLine = getline('.')
    let slashIndex = -1
    let dblquoteIndex = -1
    let currCol = col('.')

    "Search backwards for the double quote and slash
    for i in range(currCol, 0, -1)
        if currLine[i] ==# '/' && slashIndex ==# -1
            let slashIndex = i
        endif
        if currLine[i] ==# '"'
            let dblquoteIndex = i
            break
        endif
    endfor
    "If we found no quote then def is not a package
    if dblquoteIndex ==# -1
        return [0, []]
    endif
    let packagePrefix = strpart(currLine, dblquoteIndex+1, slashIndex - dblquoteIndex -1)
    let packageNamePart = strpart(currLine, slashIndex+1, currCol - slashIndex - 1)
    let packageBaseDir = fnameescape($GOPATH.'/src/'.packagePrefix)
    "The directory does not exist so no completion to do
    if !isdirectory(packageBaseDir)
        return [0, []]
    endif
    let current_dir = getcwd()
    execute 'cd' .' '. packageBaseDir
    let s:cmd = 'go list ./... | grep -v "found packages"'
    let packageList  = split(system(s:cmd))
    let pattern = '^'.packagePrefix.'/'.packageNamePart
    call filter(packageList, 'match(v:val, pattern) ==# 0')
    execute 'cd' . fnameescape(current_dir)
    for i in range(len(packageList))
        let s:p = packageList[i]
        let name = substitute(s:p, '^.*/', "", "")
        let packageList[i] = {'word': strpart(s:p, len(packagePrefix), len(s:p) - len(packagePrefix)).'"', 'abbr' : name,  'menu' : s:p}
    endfor
    return [len(packageNamePart)-1, packageList]
endf

fu! s:gocodeCommand(cmd, preargs, args)
    for i in range(0, len(a:args) - 1)
        let a:args[i] = s:gocodeShellescape(a:args[i])
    endfor
    for i in range(0, len(a:preargs) - 1)
        let a:preargs[i] = s:gocodeShellescape(a:preargs[i])
    endfor

    let bin_path = go#path#CheckBinPath(g:go_gocode_bin)
    if empty(bin_path)
        return
    endif

    " we might hit cache problems, as gocode doesn't handle well different
    " GOPATHS: https://github.com/nsf/gocode/issues/239
    let old_gopath = $GOPATH
    let $GOPATH = go#path#Detect()
    let result = s:system(printf('%s %s %s %s', s:gocodeShellescape(bin_path), join(a:preargs), s:gocodeShellescape(a:cmd), join(a:args)))
    let $GOPATH = old_gopath

    if v:shell_error != 0
        return "[\"0\", []]"
    else
        if &encoding != 'utf-8'
            let result = iconv(result, 'utf-8', &encoding)
        endif
        return result
    endif
endf

fu! s:gocodeCurrentBufferOpt(filename)
    return '-in=' . a:filename
endf

fu! s:gocodeCursor()
    if &encoding != 'utf-8'
        let sep = &l:fileformat == 'dos' ? "\r\n" : "\n"
        let c = col('.')
        let buf = line('.') == 1 ? "" : (join(getline(1, line('.')-1), sep) . sep)
        let buf .= c == 1 ? "" : getline('.')[:c-2]
        return printf('%d', len(iconv(buf, &encoding, "utf-8")))
    endif
    return printf('%d', line2byte(line('.')) + (col('.')-2))
endf

fu! s:gocodeAutocomplete()
    let filename = s:gocodeCurrentBuffer()
    let result = s:gocodeCommand('autocomplete',
                \ [s:gocodeCurrentBufferOpt(filename), '-f=vim'],
                \ [expand('%:p'), s:gocodeCursor()])
    call delete(filename)
    return result
endf

function! go#complete#GetInfo()
    let filename = s:gocodeCurrentBuffer()
    let result = s:gocodeCommand('autocomplete',
                \ [s:gocodeCurrentBufferOpt(filename), '-f=godit'],
                \ [expand('%:p'), s:gocodeCursor()])
    call delete(filename)

    " first line is: Charcount,,NumberOfCandidates, i.e: 8,,1
    " following lines are candiates, i.e:  func foo(name string),,foo(
    let out = split(result, '\n')

    " no candidates are found
    if len(out) == 1
        return ""
    endif

    " only one candiate is found
    if len(out) == 2
        return split(out[1], ',,')[0]
    endif

    " to many candidates are available, pick one that maches the word under the
    " cursor
    let infos = []
    for info in out[1:]
        call add(infos, split(info, ',,')[0])
    endfor

    let wordMatch = '\<' . expand("<cword>") . '\>'
    " escape single quotes in wordMatch before passing it to filter
    let wordMatch = substitute(wordMatch, "'", "''", "g")
    let filtered =  filter(infos, "v:val =~ '".wordMatch."'")

    if len(filtered) == 1
        return filtered[0]
    endif

    return ""
endfunction

function! go#complete#Info()
    let result = go#complete#GetInfo()
    if !empty(result)
        echo "vim-go: " | echohl Function | echon result | echohl None
    endif
endfunction

function! s:trim_bracket(val)
    let a:val.word = substitute(a:val.word, '[(){}\[\]]\+$', '', '')
    return a:val
endfunction

fu! go#complete#Complete(findstart, base)
    "findstart = 1 when we need to get the text length
    if a:findstart == 1
        "echom type(g:go_list_package_completions)
        if exists("g:go_list_package_completions")
            let s:temp = s:goPackagesCompletion()
            echom type(s:temp)
        endif
        let g:go_list_package_completions = s:goPackagesCompletion()
        echom type(g:go_list_package_completions) ."completionstype"
        if len(g:go_list_package_completions[1]) ==# 0 
            execute "silent let g:gocomplete_completions = " . s:gocodeAutocomplete()
            "current cursor position minus the first element of completions minus 1
            "echom string(g:gocomplete_completions)
            return col('.') - g:gocomplete_completions[0] - 1
        else
   " "move cursor to end of lien to get rid of trailing rubbish
   " let s:pos = getpos('.')
   " let s:pos[2] = len(currLine)-1
   " call setpos('.', s:pos)
            "echom string(g:go_list_package_completions)
            execute 'normal D'
            return col('.') - g:go_list_package_completions[0] -1
        endif
    else
        echom "calling"
        "findstart = 0 when we need to return the list of completions
        if len(g:go_list_package_completions[1]) ==# 0 
            let s = getline(".")[col('.') - 1]
            if s =~ '[(){}\{\}]'
                return map(copy(g:gocomplete_completions[1]), 's:trim_bracket(v:val)')
            endif
            return g:gocomplete_completions[1]
        else
            return g:go_list_package_completions[1]
        endif
    endif
endf

" vim:ts=4:sw=4:et
