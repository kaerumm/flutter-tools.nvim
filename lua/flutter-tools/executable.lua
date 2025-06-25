local lazy = require("flutter-tools.lazy")
local utils = lazy.require("flutter-tools.utils") ---@module "flutter-tools.utils"
local path = lazy.require("flutter-tools.utils.path") ---@module "flutter-tools.utils.path"
local ui = lazy.require("flutter-tools.ui") ---@module "flutter-tools.ui"
local config = lazy.require("flutter-tools.config") ---@module "flutter-tools.config"
local fvm_utils = lazy.require("flutter-tools.lsp.fvm_utils") ---@module "flutter-tools.lsp.fvm_utils"
local Job = require("plenary.job")

local fn = vim.fn

local M = {}

local Private = {
  ---@type Paths?
  cached_paths = nil,
  ---@type string?
  fvm_versions_path = nil,
}

---@class Paths
---@field fvm_dir? string
---@field flutter_bin? string
---@field flutter_sdk? string
---@field dart_sdk? string
---@field dart_bin? string

---Fetch the path to the users flutter installation.
---@param callback fun(flutter_bin?: string)
---@return nil
function M.flutter(callback)
  M.get(function(paths) callback(paths.flutter_bin) end)
end

---Fetch the path to the users dart installation.
---@param callback fun(dart_bin?: string)
---@return nil
function M.dart(callback)
  M.get(function(paths) callback(paths.dart_bin) end)
end

---Fetch the paths to the users binaries.
---@param callback fun(paths?: table<string, string>)
---@return nil
function M.get(callback)
  if Private.fvm_versions_path then
    return Private.get_paths(callback, Private.fvm_versions_path)
  else
    return fvm_utils.find_fvm_versions_directory(function(fvm_versions_directory)
      Private.fvm_versions_path = fvm_versions_directory
      return Private.get_paths(callback, fvm_versions_directory)
    end)
  end
end

---@param callback fun(paths?: Paths)
---@param fvm_versions_path? string
function Private.get_paths(callback, fvm_versions_path)
  local with_fvm_versions = { fvm_versions_path }
  local paths_fvm = Private.get_paths_fvm()
  if paths_fvm ~= nil then return callback(utils.merge(paths_fvm, with_fvm_versions)) end

  if Private.cached_paths ~= nil then
    return callback(utils.merge(Private.cached_paths, with_fvm_versions))
  end

  local user_provided_paths = Private.get_paths_user_provided_flutter_path()
  if user_provided_paths ~= nil then
    Private.cached_paths = user_provided_paths
    return callback(utils.merge(user_provided_paths, with_fvm_versions))
  end

  local ok = Private.get_paths_lookup_cmd(callback, fvm_versions_path)
  if ok then return end

  local default_paths = Private.get_paths_default()
  if default_paths ~= nil then
    Private.cached_paths = default_paths
    return callback(utils.merge(default_paths, with_fvm_versions))
  end

  return callback(nil)
end

---@return Paths?
function Private.get_paths_fvm()
  if not config.fvm.enabled then return nil end
  local fvm_root = fvm_utils.find_fvm_root()
  local flutter_bin = fvm_utils.flutter_bin_from_fvm(fvm_root)
  if fvm_root and flutter_bin then return Private.partial_paths_from_flutter_bin(flutter_bin) end
end

---@return Paths?
function Private.get_paths_user_provided_flutter_path()
  if config.flutter_path then
    local flutter_bin = fn.resolve(config.flutter_path)
    return Private.partial_paths_from_flutter_bin(flutter_bin)
  end
end

---@param callback fun(paths?: Paths)
---@param fvm_versions_path? string
---@return boolean
function Private.get_paths_lookup_cmd(callback, fvm_versions_path)
  local with_fvm_versions = { fvm_versions_path }
  if not config.flutter_lookup_cmd then return false end
  Private.path_from_lookup_cmd(config.flutter_lookup_cmd, function(flutter_bin)
    if not flutter_bin then
      ui.notify("Could not find the flutter binary by using the provided flutter_lookup_cmd")
      return callback(nil)
    end
    local paths = Private.partial_paths_from_flutter_bin(flutter_bin)
    Private.cached_paths = paths
    return callback(utils.merge(Private.cached_paths, with_fvm_versions))
  end)
  return true
end

---Execute user's lookup command and pass it to the job callback
---@param lookup_cmd string
---@param callback fun(string?)
function Private.path_from_lookup_cmd(lookup_cmd, callback)
  local parts = vim.split(lookup_cmd, " ")
  local cmd = parts[1]
  local args = vim.list_slice(parts, 2, #parts)

  local job = Job:new({ command = cmd, args = args })
  job:after_failure(
    vim.schedule_wrap(
      function()
        ui.notify(string.format("Error running %s", lookup_cmd), ui.ERROR, { timeout = 5000 })
      end
    )
  )
  job:after_success(vim.schedule_wrap(function(j, _)
    local result = j:result()
    local flutter_sdk_path = result[1]
    if flutter_sdk_path then
      local flutter_bin = path.join(flutter_sdk_path, "bin", "flutter")
      return callback(flutter_bin)
    else
      return callback(nil)
    end
  end))
  job:start()
end

---@return Paths?
function Private.get_paths_default()
  local flutter_bin = Private.get_default_flutter_binary()
  if flutter_bin == nil then return nil end
  local paths = Private.partial_paths_from_flutter_bin(flutter_bin)
  return paths
end

---@param flutter_bin string
---@return Paths
function Private.partial_paths_from_flutter_bin(flutter_bin)
  local flutter_sdk = Private.get_flutter_sdk_root(flutter_bin)
  local path_dart_sdk = Private.get_dart_sdk_root(flutter_sdk)
  local dart_bin = Private.get_flutter_sdk_dart_bin(flutter_sdk)
  return {
    flutter_bin = flutter_bin,
    flutter_sdk = flutter_sdk,
    dart_sdk = path_dart_sdk,
    dart_bin = dart_bin,
  }
end

function Private.get_flutter_sdk_root(bin_path)
  -- convert path/to/flutter/bin/flutter into path/to/flutter
  return fn.fnamemodify(bin_path, ":h:h")
end

---@param flutter_sdk string
function Private.get_dart_sdk_root(flutter_sdk)
  local dart_sdk = path.join("cache", "dart-sdk")
  if flutter_sdk then
    -- On Linux installations with snap the dart SDK can be further nested inside a bin directory
    -- so it's /bin/cache/dart-sdk whereas else where it is /cache/dart-sdk
    local segments = { flutter_sdk, "cache" }
    if not path.is_dir(path.join(unpack(segments))) then table.insert(segments, 2, "bin") end
    if path.is_dir(path.join(unpack(segments))) then
      -- remove the /cache/ directory as it's already part of the SDK path above
      segments[#segments] = nil
      return path.join(unpack(utils.flatten({ segments, dart_sdk })))
    end
  end

  if utils.executable("flutter") then
    local flutter_path = fn.resolve(fn.exepath("flutter"))
    local flutter_bin = fn.fnamemodify(flutter_path, ":h")
    return path.join(flutter_bin, dart_sdk)
  end

  if utils.executable("dart") then return fn.resolve(fn.exepath("dart")) end

  return ""
end

function Private.get_flutter_sdk_dart_bin(flutter_sdk)
  -- retrieve the Dart binary from the Flutter SDK
  local binary_name = path.is_windows and "dart.bat" or "dart"
  return path.join(flutter_sdk, "bin", binary_name)
end

---Get paths for flutter and dart based on the binary locations
---@return string?
function Private.get_default_flutter_binary()
  local flutter_bin = fn.resolve(fn.exepath("flutter"))
  if #flutter_bin <= 0 then return nil end
  return flutter_bin
end

return M
