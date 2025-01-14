---@class AnimationEffect
---@field type string The type of animation effect
---@field settings table Animation settings and configuration
---@field selection table Selection coordinates {start_line, start_col, end_line, end_col}
---@field start_time number Animation start timestamp
---@field active boolean Whether the animation is currently active
---@field yanked_content table[] Array of yanked content lines
---@field yank_type string Type of yank operation
---@field operation string Operator used for the operation
---@field visual_highlight table Visual mode highlight settings
---@field id number Animation effect identifier
---@field virt_text_settings table Virtual text configuration
local AnimationEffect = {}
AnimationEffect.__index = AnimationEffect

local tiny_glimmer_ns = vim.api.nvim_create_namespace("tiny-glimmer")

-- Required dependencies
local utils = require("tiny-glimmer.utils")
local animation_effects = require("tiny-glimmer.effects")

---Validate animation settings
---@param animation_type string
---@param animation_settings table
---@return boolean, string?
local function validate_settings(animation_type, animation_settings)
	if not animation_effects[animation_type] and not animation_type == "custom" then
		return false, string.format("Invalid animation type: %s", animation_type)
	end

	local required_fields = { "max_duration", "chars_for_max_duration" }
	for _, field in ipairs(required_fields) do
		if not animation_settings[field] then
			return false, string.format("Missing required setting: %s", field)
		end
	end

	return true
end

local animation_pool_id = 0

---Creates a new animation effect instance
---@param animation_type string Type of animation to apply
---@param animation_settings table Configuration for the animation
---@param selection table Selection coordinates
---@param yanked_content string[] Array of yanked content lines
---@return AnimationEffect|nil effect The created animation effect
---@return string? error Error message if creation failed
function AnimationEffect.new(animation_type, animation_settings, selection, yanked_content)
	-- Validate inputs
	local is_valid, error_msg = validate_settings(animation_type, animation_settings)
	if not is_valid then
		return nil, error_msg
	end

	local self = setmetatable({}, AnimationEffect)

	self.type = animation_type
	self.settings = animation_settings
	self.selection = selection
	self.start_time = vim.loop.now()
	self.active = true

	self.yanked_content = yanked_content
	self.yank_type = vim.v.event.regtype or "v"
	self.operation = vim.v.event.operator or "y"

	self.visual_highlight = utils.get_highlight("Visual")
	self.virt_text_settings = animation_settings.virt_text or {}

	self.id = animation_pool_id
	animation_pool_id = animation_pool_id + 1

	return self
end

---Calculate animation duration based on content length
---@param content string[] Yanked content lines
---@param settings table Animation settings
---@return number duration
local function calculate_duration(content, settings)
	if #content ~= 1 then
		return settings.max_duration
	end

	local calculated_duration = #content[1] * settings.max_duration / settings.chars_for_max_duration
	return math.min(calculated_duration, settings.max_duration)
end

---Calculate end position for a line in the animation
---@param self AnimationEffect
---@param line_content string Content of the line
---@param line_index number Index of the line
---@param animation_progress number Progress of the animation
---@return number
local function calculate_end_position(self, line_content, line_index, animation_progress)
	local end_position = #line_content * animation_progress

	if string.byte(self.yank_type) == 22 then
		return self.selection.end_col * animation_progress
	end

	if self.yank_type:lower() == "v" then
		if line_index == 1 then
			end_position = (self.selection.start_col + #line_content) * animation_progress
		elseif line_index == #self.selection then
			end_position = (self.selection.start_col + #line_content) * animation_progress
		end
	end

	return end_position
end

---Prepare lines for animation
---@param self AnimationEffect
---@param animation_progress number
---@return table[] lines Array of line configurations
local function prepare_lines_to_animate(self, animation_progress)
	local lines = {}

	for i, line_content in ipairs(self.yanked_content) do
		local end_position = calculate_end_position(self, line_content, i, animation_progress)
		table.insert(lines, {
			line_number = i - 1,
			start_position = (i == 1 or string.byte(self.yank_type) == 22) and self.selection.start_col or 0,
			end_position = end_position,
		})
	end

	return lines
end

---Apply animation effect to a line
---@param self AnimationEffect
---@param line table Line configuration
---@param animation_progress number
local function apply_line_animation(self, line, animation_progress)
	local animated_end = math.ceil(line.end_position * animation_progress)

	if animated_end < line.start_position then
		animated_end = line.start_position
	elseif animated_end == 0 then
		animated_end = 1
	end

	vim.api.nvim_buf_set_extmark(
		0,
		tiny_glimmer_ns,
		self.selection.start_line + line.line_number,
		line.start_position,
		{
			end_col = animated_end,
			hl_group = "TinyGlimmerAnimationHighlight_" .. self.id,
			hl_mode = "blend",
			priority = self.virt_text_settings.priority,
			strict = false,
		}
	)
end

---Update the animation state
---@param refresh_interval_ms number Interval between updates in milliseconds
function AnimationEffect:update(refresh_interval_ms)
	if not self.active then
		return
	end

	local current_time = vim.loop.now()
	local elapsed_time = current_time - self.start_time
	local duration = calculate_duration(self.yanked_content, self.settings)
	local progress = math.min(elapsed_time / duration, 1)
	local effect

	if self.type == "custom" then
		effect = self.settings.effect
	else
		effect = animation_effects[self.type]
	end

	local color, animation_progress = effect(self, progress)

	vim.api.nvim_set_hl(0, "TinyGlimmerAnimationHighlight_" .. self.id, { bg = color })
	vim.api.nvim_buf_clear_namespace(0, tiny_glimmer_ns, self.selection.start_line, self.selection.end_line + 1)

	local lines_to_animate = prepare_lines_to_animate(self, animation_progress)
	for _, line in ipairs(lines_to_animate) do
		apply_line_animation(self, line, animation_progress)
	end

	if progress >= 1 then
		self.active = false
		vim.defer_fn(function()
			vim.api.nvim_buf_clear_namespace(0, tiny_glimmer_ns, self.selection.start_line, self.selection.end_line + 1)
		end, self.settings.lingering_time or 0)

		animation_pool_id = animation_pool_id - 1
		if animation_pool_id < 0 then
			animation_pool_id = 0
		end
		return true
	else
		vim.defer_fn(function()
			self:update(refresh_interval_ms)
		end, refresh_interval_ms)
	end
end

return AnimationEffect
