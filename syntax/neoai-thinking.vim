" Syntax highlighting for NeoAI Thinking
if exists("b:current_syntax")
  finish
endif

" Define syntax regions
syntax match NeoAIThinkingHeader "^=== AI Thinking Process ===$"
syntax match NeoAIThinkingContent "^  .*$"

" Define colors
highlight default link NeoAIThinkingHeader Title
highlight default link NeoAIThinkingStep Special
highlight default link NeoAIThinkingContent Comment

let b:current_syntax = "neoai-thinking"
