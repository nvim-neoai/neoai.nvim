" Syntax highlighting for NeoAI Scratch Pad
if exists("b:current_syntax")
  finish
endif

" Define syntax regions
syntax match NeoAIThinkingHeader "^=== AI Thinking Process ===$"
syntax match NeoAIThinkingStep "^Thinking At: .*"

syntax match NeoAIToolCallHeader "^=== AI Tool Call ===$"
syntax match NeoAIToolCallStep "^Tool Call At: .*"

syntax match NeoAIThinkingContent "^  .*$"

" Define colors
highlight default link NeoAIThinkingHeader Title
highlight default link NeoAIThinkingStep Special
highlight default link NeoAIToolCallHeader Title
highlight default link NeoAIToolCallStep Special
highlight default link NeoAIThinkingContent Comment

let b:current_syntax = "neoai-scratchpad"
