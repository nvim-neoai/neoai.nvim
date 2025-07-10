" Syntax highlighting for NeoAI Chat
if exists("b:current_syntax")
  finish
endif

" Define syntax regions
syntax match NeoAIChatHeader "^=== NeoAI Chat Session ===$"
syntax match NeoAIChatSessionInfo "^Session ID: .*$"
syntax match NeoAIChatSessionInfo "^Created: .*$"
syntax match NeoAIChatSessionInfo "^Messages: .*$"

syntax match NeoAIChatUserPrefix "^User: .*$"
syntax match NeoAIChatAssistantPrefix "^Assistant: .*$"
syntax match NeoAIChatSystemPrefix "^System: .*$"
syntax match NeoAIChatErrorPrefix "^Error: .*$"

syntax match NeoAIChatContent "^  .*$"

" Define colors
highlight default link NeoAIChatHeader Title
highlight default link NeoAIChatSessionInfo Comment
highlight default link NeoAIChatUserPrefix Identifier
highlight default link NeoAIChatAssistantPrefix Function
highlight default link NeoAIChatSystemPrefix Special
highlight default link NeoAIChatErrorPrefix Error
highlight default link NeoAIChatContent Normal

let b:current_syntax = "neoai-chat"
