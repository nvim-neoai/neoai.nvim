local function make_code_block(text, lang)
  lang = lang or "txt"
  return string.format("```%s\n%s\n```", lang, text)
end

return make_code_block
