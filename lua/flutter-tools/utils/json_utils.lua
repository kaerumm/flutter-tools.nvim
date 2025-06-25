---@module 'plenary.job'

local M = {}

---@param job Job
---@return table?
function M.job_output_parse_json(job)
  local out = job:result()
  local json_string = table.concat(out, "\n")
  local ok, parsed = pcall(vim.json.decode, json_string)
  if not ok then return nil end
  return parsed
end

return M
