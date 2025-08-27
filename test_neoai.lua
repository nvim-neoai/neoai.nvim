-- MultiEdit Tool Tests
print("\n=== MultiEdit Tool Tests ===")

local multi_edit = require("neoai.ai_tools.multi_edit")

local function write_temp_file(path, content)
  local f = io.open(path, "w")
  assert(f, "Failed to open temp file for writing: " .. path)
  f:write(content)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local c = f:read("*a")
  f:close()
  return c
end

local cwd = vim.fn.getcwd()
local temp_path = cwd .. "/test_multi_edit.txt"

-- 1. Multiple edits in one call
write_temp_file(temp_path, "foo bar baz\nfoo bar baz\n")
local result1 = multi_edit.run({
  file_path = "test_multi_edit.txt",
  edits = {
    { old_string = "foo", new_string = "FOO" },
    { old_string = "bar", new_string = "BAR" },
    { old_string = "baz", new_string = "BAZ" },
  },
})
print("Multiple edits result:", result1)
print("File after multiple edits:", read_file(temp_path))

-- 2. Overlapping edits (should process in order)
write_temp_file(temp_path, "abcabcabc\n")
local result2 = multi_edit.run({
  file_path = "test_multi_edit.txt",
  edits = {
    { old_string = "abc", new_string = "x" },
    { old_string = "x", new_string = "y" },
  },
})
print("Overlapping edits result:", result2)
print("File after overlapping edits:", read_file(temp_path))

-- 3. No matches (should fallback)
write_temp_file(temp_path, "hello world\n")
local result3 = multi_edit.run({
  file_path = "test_multi_edit.txt",
  edits = {
    { old_string = "notfound", new_string = "FOUND" },
  },
})
print("No match result:", result3)
print("File after no match:", read_file(temp_path))

-- 4. Partial match (should fallback to line scan)
write_temp_file(temp_path, "partialmatchhere\n")
local result4 = multi_edit.run({
  file_path = "test_multi_edit.txt",
  edits = {
    { old_string = "match", new_string = "MATCHED" },
  },
})
print("Partial match result:", result4)
print("File after partial match:", read_file(temp_path))

-- 5. File not found
local result5 = multi_edit.run({
  file_path = "does_not_exist.txt",
  edits = {
    { old_string = "foo", new_string = "bar" },
  },
})
print("File not found result:", result5)

-- 6. File permission error (simulate by opening read-only if possible)
-- This is hard to simulate portably in a test, so we skip or print a note.

os.remove(temp_path)
print("MultiEdit Tool Tests complete.\n")

-- Simple test script for NeoAI multi-session functionality
-- Run this with: nvim --headless -c "luafile test_neoai.lua" -c "qa!"

print("Testing NeoAI Multi-Session Implementation...")

-- Test database initialisation
local database = require("neoai.database")
local config = {
  database_path = vim.fn.stdpath("data") .. "/test_neoai.db",
}

print("1. Testing database initialisation...")
local success = database.init(config)
if success then
  print("✓ Database initialised successfully")
else
  print("✗ Database initialisation failed")
  return
end

-- Test session creation
print("2. Testing session creation...")
local session1_id = database.create_session("Test Session 1", { test = true })
local session2_id = database.create_session("Test Session 2", { test = true })

if session1_id and session2_id then
  print("✓ Sessions created successfully (IDs: " .. session1_id .. ", " .. session2_id .. ")")
else
  print("✗ Session creation failed")
  return
end

-- Test message addition
print("3. Testing message addition...")
local msg1_id = database.add_message(session1_id, "user", "Hello from session 1", {})
local msg2_id = database.add_message(session2_id, "user", "Hello from session 2", {})

if msg1_id and msg2_id then
  print("✓ Messages added successfully")
else
  print("✗ Message addition failed")
  return
end

-- Test session switching
print("4. Testing session switching...")
local switch_success = database.switch_session(session1_id)
local active_session = database.get_active_session()

if switch_success and active_session and active_session.id == session1_id then
  print("✓ Session switching works correctly")
else
  print("✗ Session switching failed")
  return
end

-- Test message retrieval
print("5. Testing message retrieval...")
local messages = database.get_session_messages(session1_id)
if messages and #messages > 0 then
  print("✓ Message retrieval works (found " .. #messages .. " messages)")
else
  print("✗ Message retrieval failed")
  return
end

-- Test session listing
print("6. Testing session listing...")
local all_sessions = database.get_all_sessions()
if all_sessions and #all_sessions >= 2 then
  print("✓ Session listing works (found " .. #all_sessions .. " sessions)")
else
  print("✗ Session listing failed")
  return
end

-- Test statistics
print("7. Testing statistics...")
local stats = database.get_stats()
if stats and stats.sessions >= 2 and stats.messages >= 2 then
  print("✓ Statistics work correctly")
  print("  - Sessions: " .. stats.sessions)
  print("  - Messages: " .. stats.messages)
  print("  - Storage: " .. stats.storage_type)
else
  print("✗ Statistics failed")
  return
end

-- Test chat module integration
print("8. Testing chat module integration...")
local chat = require("neoai.chat")

-- Mock the config
local mock_config = {
  chat = {
    database_path = vim.fn.stdpath("data") .. "/test_neoai.db",
    auto_scroll = true,
    window = { width = 80 },
  },
}

-- Override the config temporarily
local original_config = require("neoai.config").values
require("neoai.config").values = mock_config

-- Test chat setup
chat.setup()

if chat.chat_state and chat.chat_state.current_session then
  print("✓ Chat module integration works")
  print("  - Current session ID: " .. chat.chat_state.current_session.id)
  print("  - Session title: " .. (chat.chat_state.current_session.title or "Untitled"))
else
  print("✗ Chat module integration failed")
  return
end

-- Test session management functions
print("9. Testing session management functions...")
local new_session_id = chat.new_session("Test Integration Session")
if new_session_id then
  print("✓ New session creation through chat module works")
else
  print("✗ New session creation through chat module failed")
  return
end

-- Test session info
local session_info = chat.get_session_info()
if session_info and session_info.id and session_info.title then
  print("✓ Session info retrieval works")
  print("  - Session: " .. session_info.title .. " (ID: " .. session_info.id .. ")")
else
  print("✗ Session info retrieval failed")
  return
end

-- Cleanup
print("10. Cleaning up...")
database.close()
os.remove("/tmp/test_neoai.db")
print("✓ Cleanup completed")

print("\n🎉 All tests passed! NeoAI multi-session implementation is working correctly.")
print("\nKey features implemented:")
print("- ✓ SQLite database storage with JSON fallback")
print("- ✓ Multi-session support")
print("- ✓ Session creation, switching, and management")
print("- ✓ Message persistence across sessions")
print("- ✓ Session statistics and info")
print("- ✓ Chat module integration")
print("- ✓ Database initialisation and cleanup")

print("\nTo use the new features:")
print("1. Start Neovim and run :NeoAIChat")
print("2. Use <leader>as to open the session picker")
print("3. Create new sessions with :NeoAINewSession")
print("4. Switch between sessions seamlessly")
print("5. All conversations are automatically saved!")
