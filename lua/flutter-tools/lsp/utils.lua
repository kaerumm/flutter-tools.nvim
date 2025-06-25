local M = {
  SERVER_NAME = "dartls",
}

local lazy = require("flutter-tools.lazy")
local path = lazy.require("flutter-tools.utils.path") ---@module "flutter-tools.utils.path"
local utils = lazy.require("flutter-tools.utils") ---@module "flutter-tools.utils"

local lsp = vim.lsp
local api = vim.api

-- TODO: Remove after compatibility with Neovim=0.9 is dropped
local get_clients = vim.fn.has("nvim-0.10") == 1 and lsp.get_clients or lsp.get_active_clients

function M.get_dartls_client(bufnr)
  local clients = get_clients({ name = M.SERVER_NAME, bufnr = bufnr })
  return utils.find(clients, function(c) return not c:is_stopped() end)
end

function M.get_dartls_server()
  local clients = get_clients({ name = M.SERVER_NAME })
  return utils.find(clients, function(c) return not c:is_stopped() end)
end

---@param id integer
---@return vim.lsp.Client?
function M.get_dartls_client_with_id(id)
  local clients = get_clients({ name = M.SERVER_NAME, id = id })
  return clients[1]
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

---@param fvm_versions_path string
---@param flutter_sdk_path string
---@param buffer_path string
function M.is_excluded_path(fvm_versions_path, flutter_sdk_path, buffer_path)
  local excluded_paths = M._get_excluded_paths(fvm_versions_path, flutter_sdk_path)

  for _, excluded_path in ipairs(excluded_paths) do
    if path.is_descendant(excluded_path, buffer_path) then return true end
  end
  return false
end

---@param bufnr integer
function M.is_buf_valid(bufnr)
  return api.nvim_buf_is_valid(bufnr)
    and not vim.wo.previewwindow
    and vim.bo.buftype == ""
    and vim.bo.buflisted == true
end

---@param fvm_versions_path string?
---@return string[]
function M._get_excluded_paths(fvm_versions_path, flutter_sdk_path)
  local excluded_paths = {}
  if fvm_versions_path ~= nil then table.insert(excluded_paths, fvm_versions_path) end
  return excluded_paths
end

return M
