local config = require("diffview.config")
local oop = require("diffview.oop")
local renderer = require("diffview.renderer")
local utils = require("diffview.utils")
local Panel = require("diffview.ui.panel").Panel
local api = vim.api
local M = {}

---@class TreeOptions
---@field flatten_dirs boolean
---@field folder_statuses "never"|"only_folded"|"always"

---@class FilePanel : Panel
---@field git_ctx GitContext
---@field files FileDict
---@field path_args string[]
---@field rev_pretty_name string|nil
---@field cur_file FileEntry
---@field listing_style "list"|"tree"
---@field tree_options TreeOptions
---@field render_data RenderData
---@field components CompStruct
---@field constrain_cursor function
local FilePanel = oop.create_class("FilePanel", Panel)

FilePanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = {
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "WinSeparator:DiffviewWinSeparator",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
    opt = { method = "prepend" },
  },
})

FilePanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  filetype = "DiffviewFiles",
})

---FilePanel constructor.
---@param git_ctx GitContext
---@param files FileEntry[]
---@param path_args string[]
function FilePanel:init(git_ctx, files, path_args, rev_pretty_name)
  local conf = config.get_config()
  FilePanel:super().init(self, {
    config = conf.file_panel.win_config,
    bufname = "DiffviewFilePanel",
  })
  self.git_ctx = git_ctx
  self.files = files
  self.path_args = path_args
  self.rev_pretty_name = rev_pretty_name
  self.listing_style = conf.file_panel.listing_style
  self.tree_options = conf.file_panel.tree_options

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })
end

---@override
function FilePanel:open()
  FilePanel:super().open(self)
  vim.cmd("wincmd =")
end

function FilePanel:setup_buffer()
  local conf = config.get_config()

  local default_opt = { silent = true, nowait = true, buffer = self.bufid }
  for lhs, mapping in pairs(conf.keymaps.file_panel) do
    if type(lhs) == "number" then
      local opt = vim.tbl_extend("force", mapping[4] or {}, { buffer = self.bufid })
      vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
    else
      vim.keymap.set("n", lhs, mapping, default_opt)
    end
  end
end

function FilePanel:update_components()
  local conflicting_files
  local working_files
  local staged_files

  if self.listing_style == "list" then
    conflicting_files = { name = "files" }
    working_files = { name = "files" }
    staged_files = { name = "files" }

    for _, file in ipairs(self.files.conflicting) do
      table.insert(conflicting_files, {
        name = "file",
        context = file,
      })
    end

    for _, file in ipairs(self.files.working) do
      table.insert(working_files, {
        name = "file",
        context = file,
      })
    end

    for _, file in ipairs(self.files.staged) do
      table.insert(staged_files, {
        name = "file",
        context = file,
      })
    end

  elseif self.listing_style == "tree" then
    self.files.conflicting_tree:update_statuses()
    self.files.working_tree:update_statuses()
    self.files.staged_tree:update_statuses()

    conflicting_files = {
      name = "files",
      unpack(self.files.conflicting_tree:create_comp_schema({
        flatten_dirs = self.tree_options.flatten_dirs
      })),
    }

    working_files = {
      name = "files",
      unpack(self.files.working_tree:create_comp_schema({
        flatten_dirs = self.tree_options.flatten_dirs
      })),
    }

    staged_files = {
      name = "files",
      unpack(self.files.staged_tree:create_comp_schema({
        flatten_dirs = self.tree_options.flatten_dirs
      })),
    }
  end

  ---@type CompStruct
  self.components = self.render_data:create_component({
    { name = "path" },
    {
      name = "conflicting",
      { name = "title" },
      conflicting_files,
    },
    {
      name = "working",
      { name = "title" },
      working_files,
    },
    {
      name = "staged",
      { name = "title" },
      staged_files,
    },
    {
      name = "info",
      { name = "title" },
      { name = "entries" },
    },
  })

  self.constrain_cursor = renderer.create_cursor_constraint({
    self.components.conflicting.files.comp,
    self.components.working.files.comp,
    self.components.staged.files.comp,
  })
end

---@return FileEntry[]
function FilePanel:ordered_file_list()
  if self.listing_style == "list" then
    local list = {}

    for _, file in self.files:ipairs() do
      list[#list + 1] = file
    end

    return list
  else
    local nodes = utils.vec_join(
      self.files.conflicting_tree.root:leaves(),
      self.files.working_tree.root:leaves(),
      self.files.staged_tree.root:leaves()
    )

    return vim.tbl_map(function(node)
      return node.data
    end, nodes) --[[@as vector ]]
  end
end

function FilePanel:set_cur_file(file)
  if self.cur_file then
    self.cur_file:set_active(false)
  end

  self.cur_file = file
  if self.cur_file then
    self.cur_file:set_active(true)
  end
end

function FilePanel:prev_file()
  local files = self:ordered_file_list()
  if not self.cur_file and self.files:len() > 0 then
    self:set_cur_file(files[1])
    return self.cur_file
  end

  local i = utils.vec_indexof(files, self.cur_file)
  if i ~= -1 then
    self:set_cur_file(files[(i - vim.v.count1 - 1) % #files + 1])
    return self.cur_file
  end
end

function FilePanel:next_file()
  local files = self:ordered_file_list()
  if not self.cur_file and self.files:len() > 0 then
    self:set_cur_file(files[1])
    return self.cur_file
  end

  local i = utils.vec_indexof(files, self.cur_file)
  if i ~= -1 then
    self:set_cur_file(files[(i + vim.v.count1 - 1) % #files + 1])
    return self.cur_file
  end
end

---Get the file entry under the cursor.
---@return FileEntry|any|nil
function FilePanel:get_item_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]

  local comp = self.components.comp:get_comp_on_line(line)
  if comp and (comp.name == "file" or comp.name == "directory") then
    return comp.context
  end
end

function FilePanel:highlight_file(file)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  if self.listing_style == "list" then
    for _, file_list in ipairs({
      self.components.conflicting.files,
      self.components.working.files,
      self.components.staged.files,
    }) do
      for _, comp_struct in ipairs(file_list) do
        if file == comp_struct.comp.context then
          utils.set_cursor(self.winid, comp_struct.comp.lstart + 1, 0)
        end
      end
    end

  else -- tree
    for _, comp_struct in ipairs({
      self.components.conflicting.files,
      self.components.working.files,
      self.components.staged.files,
    }) do
      comp_struct.comp:deep_some(function(cur)
        if file == cur.context then
          local was_concealed = false
          local last = cur.parent

          while last do
            local dir = last.components[1]

            if dir.context and dir.context.collapsed then
              was_concealed = true
              dir.context.collapsed = false
            end

            last = last.parent
          end

          if was_concealed then
            self:render()
            self:redraw()
          end

          utils.set_cursor(self.winid, cur.lstart + 1, 0)
          return true
        end

        return false
      end)
    end
  end

  -- Needed to update the cursorline highlight when the panel is not focused.
  utils.update_win(self.winid)
end

function FilePanel:highlight_cur_file()
  if self.cur_file then
    self:highlight_file(self.cur_file)
  end
end

function FilePanel:highlight_prev_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  pcall(
    api.nvim_win_set_cursor,
    self.winid,
    { self.constrain_cursor(self.winid, -vim.v.count1), 0 }
  )
  utils.update_win(self.winid)
end

function FilePanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, vim.v.count1),
    0,
  })
  utils.update_win(self.winid)
end

function FilePanel:reconstrain_cursor()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, 0),
    0,
  })
end

function FilePanel:set_item_fold(item, open)
  if open == item.collapsed then
    item.collapsed = not open
    self:render()
    self:redraw()
  end
end

function FilePanel:toggle_item_fold(item)
  item.collapsed = not item.collapsed
  self:render()
  self:redraw()
end

function FilePanel:render()
  require("diffview.scene.views.diff.render")(self)
end

M.FilePanel = FilePanel
return M