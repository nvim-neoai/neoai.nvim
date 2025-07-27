local M = {}

M.meta = {
  name = "TODOPlanner",
  description = [[
    Breaks down a high-level user request into an actionable markdown-formatted checklist (todo list)
    and provides recommendations or suggestions for the user to choose from.
    Only generates the initial plan (no update support).
    Output is always markdown.
  ]],
  parameters = {
    type = "object",
    properties = {
      user_request = {
        type = "string",
        description = "The high-level user request to be analyzed and broken down into actionable steps.",
      },
    },
    required = { "user_request" },
    additionalProperties = false,
  },
}

-- Simple step breakdown logic for demonstration; in production, this could use LLMs or more advanced logic
local function plan_steps(request)
  -- This is a placeholder. In a real agent, this would be more sophisticated.
  if request:lower():find("auth") then
    return {
      "- [ ] Research authentication methods for Neovim plugins (`grep`)",
      "- [ ] Choose a suitable authentication library (`read`)",
      "- [ ] Integrate authentication library into the project (`write`)",
      "- [ ] Implement login and logout commands (`multi_edit`)",
      "- [ ] Test authentication flow (`multi_edit`)",
    }, {
      "- Consider using OAuth for third-party integrations",
      "- Add unit tests for authentication logic (`write`)",
      "- Update documentation to include authentication setup (`write`)",
    }
  end
  -- Default fallback
  return {
    "- [ ] Analyze requirements for: " .. request .. " (`grep`)",
    "- [ ] Design solution for: " .. request .. " (`read`)",
    "- [ ] Implement solution for: " .. request .. " (`write` or `multi_edit`)",
    "- [ ] Test and validate: " .. request .. " (`multi_edit`)",
    "- [ ] Document changes for: " .. request .. " (`write`)",
  }, {
    "- Break down large tasks into smaller subtasks",
    "- Consult project documentation for best practices (`read`)",
    "- Review code for maintainability and style (`grep`/`read`)",
  }
end

M.run = function(args)
  local user_request = args.user_request or ""
  if user_request == "" then
    return "Error: user_request is required."
  end

  local steps, recommendations = plan_steps(user_request)

  local checklist = "## TODO List\n\n" .. table.concat(steps, "\n") .. "\n"
  local recs = "## Recommendations\n\n" .. table.concat(recommendations, "\n") .. "\n"

  return checklist .. "\n" .. recs
end

return M