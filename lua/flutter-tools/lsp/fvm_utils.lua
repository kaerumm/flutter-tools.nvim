local M = {}

local lazy = require("flutter-tools.lazy")

local Job = require("plenary.job")
local utils = lazy.require("flutter-tools.utils") ---@module "flutter-tools.utils"
local json_utils = lazy.require("flutter-tools.utils.json_utils") ---@module "flutter-tools.utils.json_utils"
local lsp_utils = lazy.require("flutter-tools.lsp.utils") ---@module "flutter-tools.lsp.utils"
local path = lazy.require("flutter-tools.utils.path") ---@module "flutter-tools.utils.path"
local config_utils = lazy.require("flutter-tools.utils.config_utils") ---@module "flutter-tools.utils.config_utils"
local config = lazy.require("flutter-tools.config") ---@module "flutter-tools.config"

local fn = vim.fn
local luv = vim.loop

--- Gets the FVM root directory by traversing upwards
--- @returns string?
function M.find_fvm_root()
  local current_path = path.current_buffer_path()
  local search_path = lsp_utils.is_valid_path(current_path) and current_path
    or config_utils.get_cwd()
  return search_path and path.find_root(config.fvm.fvm_root_patterns, search_path)
end

--- Gets the flutter binary from fvm root folder
--- @param fvm_root string fvm root folder
--- @return string?
function M.flutter_bin_from_fvm(fvm_root)
  local binary_name = path.is_windows and "flutter.bat" or "flutter"
  local flutter_bin_symlink = path.join(fvm_root, ".fvm", "flutter_sdk", "bin", binary_name)
  flutter_bin_symlink = fn.exepath(flutter_bin_symlink)
  local flutter_bin = luv.fs_realpath(flutter_bin_symlink)
  if path.exists(flutter_bin_symlink) and path.exists(flutter_bin) then return flutter_bin end
end

---@param callback fun(fvm_version_directory: string?)
function M.find_fvm_versions_directory(callback)
  local fvm_bin = M.find_fvm_executable()
  if fvm_bin == nil then return nil end
  local job = Job:new({
    command = fvm_bin,
    args = { "api", "context" },
  })
  job:after_failure(vim.schedule_wrap(function() callback(nil) end))
  job:after_success(vim.schedule_wrap(function(j, _)
    local result = json_utils.job_output_parse_json(j)
    if not result or not result.context then return callback(nil) end
    local fvm_versions_directory = result.context["versionsCachePath"]
    return callback(fvm_versions_directory)
  end))
  job:start()
end

function M.find_fvm_executable()
  local fvm_executable = vim.fn.exepath("fvm")
  if fvm_executable == "" then return nil end
  return fvm_executable
end

return M
