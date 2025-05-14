local M = {}

local lsp = vim.lsp

M.SERVER_NAME = "dartls"

-- TODO: Remove after compatibility with Neovim=0.9 is dropped
local get_clients = vim.fn.has("nvim-0.10") == 1 and lsp.get_clients or lsp.get_active_clients
local lazy = require("flutter-tools.lazy")
local utils = lazy.require("flutter-tools.utils") ---@module "flutter-tools.utils"

---@param bufnr number?
---@return vim.lsp.Client?
function M.get_dartls_client(bufnr)
  local clients = get_clients({ name = M.SERVER_NAME, bufnr = bufnr })
  return utils.find(clients, function(c) return not c:is_stopped() end)
end

return M
