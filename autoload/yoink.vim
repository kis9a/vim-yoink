
scriptencoding utf-8

let s:saveHistoryToShada = get(g:, 'yoinkSaveToShada', 0)
let s:autoFormat = get(g:, 'yoinkAutoFormatPaste', 0)
let s:lastSwapStartChangedtick = -1
let s:lastSwapChangedtick = -1
let s:isSwapping = 0
let s:offsetSum = 0

if s:saveHistoryToShada
    if !exists("g:YOINK_HISTORY")
        let g:YOINK_HISTORY = []
    endif
else
    let s:history = []
    " If the setting is off then clear it to not keep taking up space
    let g:YOINK_HISTORY = []
endif

function! yoink#getYankHistory()
    if s:saveHistoryToShada
        return g:YOINK_HISTORY
    endif

    return s:history
endfunction

function! yoink#getDefaultReg()
    let clipboardFlags = split(&clipboard, ',')
    if index(clipboardFlags, 'unnamedplus') >= 0
        return "+"
    elseif index(clipboardFlags, 'unnamed') >= 0
        return "*"
    else
        return "\""
    endif
endfunction

function! yoink#paste(pasteType, reg)
    let cnt = v:count > 0 ? v:count : 1
    exec "normal! \"" . a:reg . cnt . a:pasteType

    if s:autoFormat
        " For some reason, the format operation does not update the ] mark properly so we
        " have to do this manually
        let endPos = getpos("']")
        let oldIndentAmount = indent(endPos[1])
        silent exec "keepjumps normal! `[=`]"
        let newIndentAmount = indent(endPos[1])
        let endPos[2] += newIndentAmount - oldIndentAmount
        call setpos("']", endPos)
    endif

    if g:yoinkMoveCursorToEndOfPaste
        call setpos(".", getpos("']"))
    else
        if s:autoFormat
            " Default vim behaviour is to place cursor at the beginning of the new text
            " Auto format can change this sometimes so ensure this is fixed
            call setpos(".", getpos("'["))
        else
            " Do nothing
            " Make sure paste with yoinkAutoFormatPaste and yoinkMoveCursorToEndOfPaste off is
            " always identical to normal vim
        endif
    endif

    call yoink#startUndoRepeatSwap()
    silent! call repeat#setreg(fullPlugName, a:reg)
    silent! call repeat#set("\<plug>(YoinkPaste_" . a:pasteType . ")", cnt)
endfunction

function! s:postSwapCursorMove2()
    if !s:isSwapping
        " Should never happen
        throw 'Unknown Error detected during yoink paste'
    endif

    let s:isSwapping = 0
    let s:autoFormat = g:yoinkAutoFormatPaste

    augroup YoinkSwapPasteMoveDetect
        autocmd!
    augroup END

    " Return yank positions to their original state before we started swapping
    call yoink#rotate(-s:offsetSum)
endfunction

function! s:postSwapCursorMove1()
    " Wait for the next cursor move because this gets called immediately after yoink#postPasteSwap
    augroup YoinkSwapPasteMoveDetect
        autocmd!
        autocmd CursorMoved <buffer> call <sid>postSwapCursorMove2()
    augroup END
endfunction

function! yoink#postPasteToggleFormat()
    if yoink#tryStartSwap()
        let s:autoFormat = !s:autoFormat
        call yoink#performSwap()
    endif
endfunction

function! yoink#tryStartSwap()
    " If a change occurred that was not a paste or a swap, we do not want to do the undo-redo
    " Also, if the swap has ended by executing a cursor move, then we don't want to
    " restart the swap again from the beginning because they would expect to still be at the
    " previous offset
    if b:changedtick != s:lastSwapStartChangedtick || (!s:isSwapping && b:changedtick == s:lastSwapChangedtick)
        echo 'Last action was not paste - swap ignored'
        return 0
    endif

    if !s:isSwapping
        let s:isSwapping = 1
        let s:offsetSum = 0
    endif

    return 1
endfunction

function! yoink#performSwap()
    " Stop checking to end the swap session
    augroup YoinkSwapPasteMoveDetect
        autocmd!
    augroup END

    exec "normal \<Plug>(RepeatUndo)\<Plug>(RepeatDot)"

    let s:lastSwapChangedtick = b:changedtick

    " Wait until the cursor moves and then end the swap
    " We do this so that if they move somewhere else and then paste they would expect the most
    " recent yank and not the yank at the offset where they finished the previous swap
    augroup YoinkSwapPasteMoveDetect
        autocmd!
        autocmd CursorMoved <buffer> call <sid>postSwapCursorMove1()
    augroup END
endfunction

function! yoink#postPasteSwap(offset)

    if !yoink#tryStartSwap()
        return
    endif

    let cnt = v:count > 0 ? v:count : 1
    let offset = a:offset * cnt

    if s:offsetSum + offset < 0
        echo 'Reached most recent item'
        return
    endif

    let history = yoink#getYankHistory()

    if s:offsetSum + offset >= len(history)
        echo 'Reached oldest item'
        return
    endif

    call yoink#rotate(offset)
    let s:offsetSum += offset

    call yoink#performSwap()
endfunction

" Note that this gets executed for every swap in addition to the initial paste
function! yoink#startUndoRepeatSwap()
    let s:lastSwapStartChangedtick = b:changedtick
endfunction

function! yoink#onHistoryChanged()
    let history = yoink#getYankHistory()

    " sync numbered registers
    for i in range(1, min([len(history), 9]))
        let entry = history[i-1]
        call setreg(i, entry.text, entry.type)
    endfor
endfunction

function! yoink#tryAddToHistory(entry)
    let history = yoink#getYankHistory()

    if !empty(a:entry.text) && (empty(history) || (a:entry != history[0]))
        " If it's already in history then just move it to the front to avoid duplicates
        for i in range(len(history))
            if history[i] ==# a:entry
                call remove(history, i)
                break
            endif
        endfor

        call insert(history, a:entry)
        if len(history) > g:yoinkMaxItems
            call remove(history, g:yoinkMaxItems, -1)
        endif
        call yoink#onHistoryChanged()
        return 1
    endif

    return 0
endfunction

function! yoink#rotate(offset)
    let history = yoink#getYankHistory()

    if empty(history) || a:offset == 0
        return
    endif

    " If the default register has contents different than the first entry in our history,
    " then it must have changed through a delete operation or directly via setreg etc.
    " In this case, don't rotate and instead just update the default register
    if history[0] != yoink#getDefaultYankInfo()
        call yoink#setDefaultYankInfo(history[0])
        call yoink#onHistoryChanged()
        return
    endif

    let offsetLeft = a:offset

    while offsetLeft != 0
        if offsetLeft > 0
            let l:entry = remove(history, 0)
            call add(history, l:entry)
            let offsetLeft -= 1
        elseif offsetLeft < 0
            let l:entry = remove(history, -1)
            call insert(history, l:entry)
            let offsetLeft += 1
        endif
    endwhile

    call yoink#setDefaultYankInfo(history[0])
    call yoink#onHistoryChanged()
endfunction

function! yoink#addCurrentToHistory()
    call yoink#tryAddToHistory(yoink#getDefaultYankInfo())
endfunction

function! yoink#clearYanks()
    let history = yoink#getYankHistory()
    let previousSize = len(history)
    call remove(history, 0, -1)
    call yoink#addCurrentToHistory()
    echo "Cleared yank history of " . previousSize . " entries"
endfunction

function! yoink#getDefaultYankText()
    return yoink#getDefaultYankInfo().text
endfunction

function! yoink#getDefaultYankInfo()
    return yoink#getYankInfoForReg(yoink#getDefaultReg())
endfunction

function! yoink#setDefaultYankText(text)
    call setreg(yoink#getDefaultReg(), a:text, 'v')
endfunction

function! yoink#setDefaultYankInfo(entry)
    call setreg(yoink#getDefaultReg(), a:entry.text, a:entry.type)
endfunction

function! yoink#getYankInfoForReg(reg)
    return { 'text': getreg(a:reg), 'type': getregtype(a:reg) }
endfunction

function! yoink#showYanks()
    echohl WarningMsg | echo "--- Yanks ---" | echohl None
    let i = 0
    for yank in yoink#getYankHistory()
        call yoink#showYank(yank, i)
        let i += 1
    endfor
endfunction

function! yoink#showYank(yank, index)
    let index = printf("%-4d", a:index)
    let line = substitute(a:yank.text, '\V\n', '^M', 'g')

    if len(line) > g:yoinkShowYanksWidth
        let line = line[: g:yoinkShowYanksWidth] . '…'
    endif

    echohl Directory | echo  index
    echohl None      | echon line
    echohl None
endfunction

function! yoink#rotateThenPrint(offset)
    let cnt = v:count > 0 ? v:count : 1
    let offset = a:offset * cnt
    call yoink#rotate(offset)

    let lines = split(yoink#getDefaultYankText(), '\n')

    if empty(lines)
        " This happens when it only contains newlines
        echo "Current Yank: "
    else
        echo "Current Yank: " . lines[0]
    endif
endfunction

function! yoink#onFocusGained()
    if !g:yoinkSyncSystemClipboardOnFocus
        return
    endif

    let history = yoink#getYankHistory()

    " If we are using the system register as the default register
    " and the user leaves vim, copies something, then returns,
    " we want to add this data to the yank history
    let defaultReg = yoink#getDefaultReg()
    if defaultReg ==# '*' || defaultReg == '+'
        let currentInfo = yoink#getDefaultYankInfo()

        if len(history) == 0 || history[0] != currentInfo
            " User copied something externally
            call yoink#tryAddToHistory(currentInfo)
        endif
    endif
endfunction

" Call this to simulate a yank from the user
function! yoink#manualYank(text, ...) abort
    let regType = a:0 ? a:1 : 'v'
    let entry = { 'text': a:text, 'type': regType }
    call yoink#tryAddToHistory(entry)
    call yoink#setDefaultYankInfo(entry)
endfunction

function! yoink#onYank(ev) abort
    let isValidRegister = a:ev.regname == '' || a:ev.regname == yoink#getDefaultReg()

    if isValidRegister && (a:ev.operator == 'y' || g:yoinkIncludeDeleteOperations)
        " Don't use a:ev.regcontents because it's a list of lines and not just the raw text 
        " and the raw text is needed when comparing getDefaultYankInfo in a few places
        " above
        call yoink#tryAddToHistory({ 'text': getreg(a:ev.regname), 'type': a:ev.regtype })
    end
endfunction

" For when re-sourcing this file after a paste
augroup YoinkSwapPasteMoveDetect
    autocmd!
augroup END

