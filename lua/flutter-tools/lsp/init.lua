local lazy = require("flutter-tools.lazy")
local utils = lazy.require("flutter-tools.utils") ---@module "flutter-tools.utils"
local path = lazy.require("flutter-tools.utils.path") ---@module "flutter-tools.utils.path"
local ui = lazy.require("flutter-tools.ui") ---@module "flutter-tools.ui"
local color = lazy.require("flutter-tools.lsp.color") ---@module "flutter-tools.lsp.color"
local lsp_utils = lazy.require("flutter-tools.lsp.utils") ---@module "flutter-tools.lsp.utils"

local api = vim.api
local lsp = vim.lsp
local fmt = string.format

local FILETYPE = "dart"

---@class LSPInitModule
---@field lsps table<string, { client_id: integer, initialized: boolean, attach_on_init: { buf: integer, project_root: string }[] }>
local M = {
  lsps = {},
}

---Merge a set of default configurations with a user's own settings
--- NOTE: a user can specify a function in which case this will be used
---to determine how to merge the defaults with a user's config
---@param default table
---@param user table|function
---@return table
local function merge_config(default, user)
  if type(user) == "function" then return user(default) end
  if not user or vim.tbl_isempty(user) then return default end
  return vim.tbl_deep_extend("force", default or {}, user or {})
end

local function create_debug_log(level)
  return function(msg)
    local levels = require("flutter-tools.config").debug_levels
    if level <= levels.DEBUG then require("flutter-tools.ui").notify(msg, level) end
  end
end

---Handle progress notifications from the server
---@param err table
---@param result table
---@param ctx table
local function handle_progress(err, result, ctx)
  -- Call the existing handler for progress so plugins can also handle the event
  -- but only whilst not editing the buffer as dartls can be spammy
  if api.nvim_get_mode().mode ~= "i" then vim.lsp.handlers["$/progress"](err, result, ctx) end
  -- NOTE: this event gets called whenever the analysis server has completed some work
  -- rather than just when the server has started.
  if result and result.value and result.value.kind == "end" then
    utils.emit_event(utils.events.LSP_ANALYSIS_COMPLETED)
  end
end

local function handle_super(err, result)
  if err then
    return vim.notify("Error when finding super" .. vim.inspect(err), vim.log.levels.ERROR)
  end
  if not result or vim.tbl_isempty(result) then return end
  local client = lsp_utils.get_dartls_client()
  if not client then return end
  local locations = {}
  local win = api.nvim_get_current_win()
  local from = vim.fn.getpos(".")
  local bufnr = api.nvim_get_current_buf()
  from[1] = bufnr
  local tagname = vim.fn.expand("<cword>")
  if result then locations = vim.islist(result) and result or { result } end
  local items = vim.lsp.util.locations_to_items(locations, client.offset_encoding)
  if vim.tbl_isempty(items) then
    vim.notify("No locations found", vim.log.levels.INFO)
    return
  end
  if #items == 1 then
    local item = items[1]
    local b = item.bufnr or vim.fn.bufadd(item.filename)

    -- Save position in jumplist
    vim.cmd("normal! m'")
    -- Push a new item into tagstack
    local tagstack = { { tagname = tagname, from = from } }
    vim.fn.settagstack(vim.fn.win_getid(win), { items = tagstack }, "t")

    vim.bo[b].buflisted = true
    api.nvim_win_set_buf(win, b)
    api.nvim_win_set_cursor(win, { item.lnum, item.col - 1 })
    vim._with({ win = win }, function()
      -- Open folds under the cursor
      vim.cmd("normal! zv")
    end)
    return
  else
    vim.notify("More than one location found", vim.log.levels.ERROR)
  end
end

---Create default config for dartls
---@param opts table
---@return table
local function get_defaults(opts)
  local flutter_sdk_path = opts.flutter_sdk
  local config = {
    init_options = {
      onlyAnalyzeProjectsWithOpenFiles = true,
      suggestFromUnimportedLibraries = true,
      closingLabels = true,
      outline = true,
      flutterOutline = true,
    },
    settings = {
      dart = {
        completeFunctionCalls = true,
        showTodos = true,
        analysisExcludedFolders = {
          path.join(flutter_sdk_path, "packages"),
          path.join(flutter_sdk_path, ".pub-cache"),
        },
        updateImportsOnRename = true,
      },
    },
    handlers = {
      -- TODO: can this be replaced with the initialized capability
      ["$/progress"] = handle_progress,
      ["dart/textDocument/publishClosingLabels"] = utils.lsp_handler(
        require("flutter-tools.labels").closing_tags
      ),
      ["dart/textDocument/publishOutline"] = utils.lsp_handler(
        require("flutter-tools.outline").document_outline
      ),
      ["dart/textDocument/publishFlutterOutline"] = utils.lsp_handler(
        require("flutter-tools.guides").widget_guides
      ),
      ["textDocument/documentColor"] = require("flutter-tools.lsp.color").on_document_color,
      ["dart/reanalyze"] = function() end, -- returns: None
      ["dart/textDocument/super"] = handle_super,
    },
    commands = {
      ["refactor.perform"] = require("flutter-tools.lsp.commands").refactor_perform,
    },
    capabilities = (function()
      local capabilities = lsp.protocol.make_client_capabilities()
      capabilities.workspace.configuration = true
      -- This setting allows document changes to be made via the lsp e.g. renaming a file when
      -- the containing class is renamed also
      -- @see: https://microsoft.github.io/language-server-protocol/specifications/specification-current/#workspaceEdit
      capabilities.workspace.workspaceEdit.documentChanges = true
      capabilities.textDocument.completion.completionItem.snippetSupport = true
      capabilities.textDocument.documentColor = { dynamicRegistration = true }
      -- @see: https://github.com/hrsh7th/nvim-compe#how-to-use-lsp-snippet
      capabilities.textDocument.completion.completionItem.resolveSupport = {
        properties = { "documentation", "detail", "additionalTextEdits" },
      }
      return capabilities
    end)(),
  }
  return config
end

function M.restart()
  local client = lsp_utils.get_dartls_client()
  if client then
    local bufs = lsp.get_buffers_by_client_id(client.id)
    lsp.stop_client(client.id)
    local client_id = lsp.start_client(client.config)
    for _, buf in pairs(bufs) do
      if client_id then lsp.buf_attach_client(buf, client_id) end
    end
  end
end

---@return string?
function M.get_project_root_dir()
  local conf = require("flutter-tools.config")
  local current_buffer_path = path.current_buffer_path()
  local root_path = lsp_utils.is_valid_path(current_buffer_path)
      and path.find_root(conf.root_patterns, current_buffer_path)
    or nil

  if root_path ~= nil then return root_path end

  local client = lsp_utils.get_dartls_client()
  return client and client.config.root_dir or nil
end

-- FIXME: I'm not sure how to correctly wait till a server is ready before
-- sending this request. Ideally we would wait till the server is ready.
M.document_color = function()
  local client = lsp_utils.get_dartls_client()
  if client and client.server_capabilities.colorProvider then color.document_color() end
end
M.on_document_color = color.on_document_color

function M.dart_lsp_super()
  local conf = require("flutter-tools.config")
  local user_config = conf.lsp
  local debug_log = create_debug_log(user_config.debug)
  local client = lsp_utils.get_dartls_client()
  if client == nil then
    debug_log("No active dartls server found")
    return
  end
  -- Get current cursor position (1-based)
  local line, col = unpack(api.nvim_win_get_cursor(0))

  -- Note: line is 1-based but col is 0-based
  -- To make line 0-based for LSP, subtract 1:
  local lsp_line = line - 1
  local lsp_col = col
  local params = {
    textDocument = {
      uri = vim.uri_from_bufnr(0), -- gets URI of current buffer
    },
    position = {
      line = lsp_line, -- 0-based line number
      character = lsp_col, -- 0-based character position
    },
  }
  client.request("dart/textDocument/super", params, nil, 0)
end

function M.dart_reanalyze() lsp.buf_request(0, "dart/reanalyze") end

---@param user_config table
---@param callback fun(table, table)
local function get_server_config(user_config, callback)
  local config = utils.merge({ name = lsp_utils.SERVER_NAME }, user_config, { "color" })
  local executable = require("flutter-tools.executable")
  --- TODO: if a user specifies a command we do not need to call executable.get
  executable.get(function(paths)
    if not paths then
      ui.notify(
        "Flutter executable could not be found, please make sure that flutter_path is given"
          .. " or flutter_lookup_cmd is given or fvm is setup or that the flutter binary is "
          .. "in your path"
      )
      return
    end
    local defaults = get_defaults({ flutter_sdk = paths.flutter_sdk })
    local root_path = paths.dart_sdk
    local debug_log = create_debug_log(user_config.debug)
    debug_log(fmt("dart_sdk_path: %s", root_path))

    config.cmd = config.cmd or { paths.dart_bin, "language-server", "--protocol=lsp" }

    if config.analyzer_web_port then
      table.insert(config.cmd, "--port=" .. tostring(config.analyzer_web_port))
    end

    config.filetypes = { FILETYPE }
    config.capabilities = merge_config(defaults.capabilities, config.capabilities)
    config.init_options = merge_config(defaults.init_options, config.init_options)
    config.handlers = merge_config(defaults.handlers, config.handlers)
    config.settings = merge_config(defaults.settings, { dart = config.settings })
    config.commands = merge_config(defaults.commands, config.commands)

    config.on_init = function(client, _)
      if vim.fn.has("nvim-0.12") == 0 then
        client.notify("workspace/didChangeConfiguration", { settings = config.settings })
      else
        client:notify("workspace/didChangeConfiguration", { settings = config.settings })
      end

      local lsp_entry = M._get_lsp_entry(paths.dart_bin)
      assert(lsp_entry ~= nil, "LSPEntry should not be nil during on init")

      for _, entry in ipairs(lsp_entry.attach_on_init) do
        if api.nvim_buf_is_valid(entry.buf) then
          M._attach_buffer_and_add_workspace_folder(client, entry.buf, entry.project_root)
        end
      end

      lsp_entry.initialized = true
    end

    config.on_exit = function()
      M._delete_lsp_entry(paths.dart_bin)
      M.attach()
    end

    callback(config, paths)
  end)
end

---This was heavily inspired by nvim-metals implementation of the attach functionality
function M.attach()
  local conf = require("flutter-tools.config")
  local user_config = conf.lsp
  local debug_log = create_debug_log(user_config.debug)
  debug_log("attaching LSP")

  local buf = api.nvim_get_current_buf()

  if not lsp_utils.is_buf_valid(buf) then return end

  local key = "dart_lsp_attaching"

  local success, attaching = pcall(vim.api.nvim_buf_get_var, buf, key)
  if success and attaching == true then return end
  vim.api.nvim_buf_set_var(buf, key, true)

  local buffer_path = api.nvim_buf_get_name(buf)

  if not lsp_utils.is_valid_path(buffer_path) then
    return vim.api.nvim_buf_set_var(buf, key, false)
  end

  get_server_config(user_config, function(c, paths)
    vim.api.nvim_buf_set_var(buf, key, false)

    if lsp_utils.is_excluded_path(paths.fvm_versions_directory, paths.flutter_sdk, buffer_path) then
      return
    end

    local project_root = M.get_project_root_dir()

    local root_dir = paths.fvm_dir or project_root
    c.root_dir = root_dir

    if M._get_lsp_entry(paths.dart_bin) == nil then
      local id = vim.lsp.start(c)
      M._get_or_create_lsp_entry(paths.dart_bin, id)
    end

    M._attach_buffer(paths.dart_bin, buf, project_root)
  end)
end

---@param dart_bin string
function M._get_lsp_entry(dart_bin) return M.lsps[dart_bin] end

---@param dart_bin string
---@param client_id integer
function M._get_or_create_lsp_entry(dart_bin, client_id)
  if M.lsps[dart_bin] == nil then
    M.lsps[dart_bin] = {
      client_id = client_id,
      initialized = false,
      attach_on_init = {},
    }
  end
  return M.lsps[dart_bin]
end

---@param dart_bin string
function M._delete_lsp_entry(dart_bin) M.lsps[dart_bin] = nil end

---@param dart_bin string
function M._delete_attach_list(dart_bin)
  local lsp_entry = M._get_lsp_entry(dart_bin)
  if lsp_entry == nil then return end
  lsp_entry.attach_on_init = {}
end

---@param dart_bin string
---@param buf integer
---@param project_root string
function M._attach_buffer(dart_bin, buf, project_root)
  local lsp_entry = M._get_lsp_entry(dart_bin)
  if lsp_entry == nil then return end
  if lsp_entry.initialized then
    local client = lsp_utils.get_dartls_client_with_id(lsp_entry.client_id)
    if client == nil then return end
    M._attach_buffer_and_add_workspace_folder(client, buf, project_root)
    return
  end
  local attach_entry = { buf = buf, project_root = project_root }
  table.insert(lsp_entry.attach_on_init, attach_entry)
end

---@param buf integer
---@param client vim.lsp.Client
---@param project_root string
function M._attach_buffer_and_add_workspace_folder(client, buf, project_root)
  lsp.buf_attach_client(buf, client.id)
  for _, folder in pairs(client.workspace_folders or {}) do
    if folder.name == project_root then return end
  end
  client:_add_workspace_folder(project_root)
end

return M
