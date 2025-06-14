local M = {}

local lazy = require("flutter-tools.lazy")

local lsp = vim.lsp

-- TODO: Remove after compatibility with Neovim=0.9 is dropped
local get_clients = vim.fn.has("nvim-0.10") == 1 and lsp.get_clients or lsp.get_active_clients
local utils = lazy.require("flutter-tools.utils") ---@module "flutter-tools.utils"

M.SERVER_NAME = "dartls"

---@param bufnr number?
---@return vim.lsp.Client?
function M.get_dartls_client(bufnr)
  local clients = get_clients({ name = M.SERVER_NAME, bufnr = bufnr })
  return utils.find(clients, function(c) return not c:is_stopped() end)
end

function M.get_dartls_server()
  local clients = get_clients({ name = M.SERVER_NAME })
  return utils.find(clients, function(c) return not c:is_stopped() end)
end

---@param cmd string
---@return vim.lsp.Client?
function M.get_dartls_client_for_version(cmd)
  local clients = get_clients({ name = M.SERVER_NAME })
  return utils.find(clients, function(c)
    local isStopping = c:is_stopped()
    if isStopping then return false end
    local client_cmd = (c.config.cmd or {})[1]
    return cmd == client_cmd
  end)
end

--- Checks if buffer path is valid for attaching LSP
--- @param buffer_path string
--- @return boolean
function M.is_valid_path(buffer_path)
  if buffer_path == "" then return false end

  local start_index, _, uri_prefix = buffer_path:find("^(%w+://).*")
  -- Do not attach LSP if file URI prefix is not file.
  -- For example LSP will not be attached for diffview:// or fugitive:// buffers.
  return not start_index or uri_prefix == "file://"
end

return M
