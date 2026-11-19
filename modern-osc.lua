-- Floating controls and a track sidebar for the mpv window opened by Stremio.
local mp = require 'mp'
local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local options = require 'mp.options'
local is_windows = mp.get_property('platform') == 'windows' or package.config:sub(1, 1) == '\\'

local opt = {
    width = 540, sidebar_width = 264, hide_delay = 2, scale = 1, sidebar_open = false,
    controls_left = 'volume', controls_center = 'back,play,forward', controls_right = 'tracks,playlist,settings,fullscreen',
    controls_layout = 'floating', button_size = 32, button_spacing = 2,
    sidebar_side = 'right', sidebar_mode = 'docked', sidebar_layout = 'stacked', sidebar_order = 'sub,audio',
    font = '', font_scale = 1, radius = 16, panel_opacity = 1, sidebar_opacity = 1,
    subtitle_backdrop = true, dark_title_bar = true,
    color_panel = '232529', color_border = '454B54', color_sidebar = '1B1F25', color_text = 'EDF0F4', color_muted = 'ABB5C1',
    color_track = '505A66', color_selected = '334A4C', color_accent = 'B8DDD7', color_hover = '39424E',
}
local overlay = mp.create_osd_overlay('ass-events')
overlay.z = 20
local state = {
    sidebar = opt.sidebar_open, sidebar_view = 'tracks', pinned = false, alpha = 1, last_move = mp.get_time(),
    x_ratio = .5, y_ratio = 1, mouse_x = -1, mouse_y = -1,
    hover = false, regions = {}, scroll = {}, groups = {}, reveal_selected = {},
}
local saved_margins = {
    left = mp.get_property_number('video-margin-ratio-left', 0),
    right = mp.get_property_number('video-margin-ratio-right', 0),
}
local saved_sub_margin = mp.get_property_number('sub-margin-y', 24)
local saved_sub_offset = mp.get_property_number('sub-margin-y-offset')
local saved_sub_use_margins = mp.get_property_native('sub-use-margins')
local style_options = {
    subtitle_backdrop = {
        ['sub-border-style'] = 'background-box', ['sub-back-color'] = '0.04/0.06/0.08/0.72',
        ['sub-shadow-offset'] = '3', ['sub-outline-size'] = '0',
    },
    dark_title_bar = {['macos-title-bar-appearance'] = 'darkAqua', ['macos-title-bar-color'] = '#1B1E21'},
}
local saved_style = {}
for _, properties in pairs(style_options) do
    for name in pairs(properties) do saved_style[name] = mp.get_property(name) end
end
local bindings_active = false
local mouse_section = mp.get_script_name() .. '_mouse'
local escape_active = false
local draw_pending = false
local draw
local click
local wheel
local min_video_width = 300
local min_osd_height = 320

local default_colors = { panel = '232529', border = '454B54', sidebar = '1B1F25', text = 'EDF0F4', muted = 'ABB5C1',
    track = '505A66', selected = '334A4C', accent = 'B8DDD7', hover = '39424E' }
local colors = {}
local control_groups = {}
local sidebar_order = {}
local control_names = {volume = true, back = true, play = true, forward = true, tracks = true,
    playlist = true, settings = true, pin = true, fullscreen = true}
local sidebar_titles = {tracks = '字幕與音軌', playlist = '播放清單', settings = '播放設定'}
local list_titles = {sub = '字幕', audio = '音軌', speed = '播放速度'}
local list_properties = {sub = 'sid', audio = 'aid', playlist = 'playlist-pos', speed = 'speed'}
local languages = { zho = '中文', chi = '中文', zh = '中文', cmn = '國語',
    ['zh-Hant'] = '繁體中文', eng = 'English', en = 'English', jpn = '日本語', ja = '日本語', kor = '한국어' }

local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function bgr(value) return value:sub(5, 6) .. value:sub(3, 4) .. value:sub(1, 2) end
local function escape(value)
    return tostring(value or ''):gsub('\\', '\\\239\187\191'):gsub('{', '\\{'):gsub('}', '\\}'):gsub('[\r\n]', ' ')
end
local function time_label(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds >= 3600 then return string.format('%d:%02d:%02d', math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60) end
    return string.format('%02d:%02d', math.floor(seconds / 60), seconds % 60)
end
local function contains(rect, x, y)
    return rect and x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h
end
local function redraw()
    if draw_pending then return end
    draw_pending = true
    mp.add_timeout(0, function() draw_pending = false; draw() end)
end
local function parse_order(value, allowed, seen)
    local result = {}
    for token in value:gmatch('[^,]+') do
        token = token:match('^%s*(.-)%s*$')
        if allowed[token] and not seen[token] then
            seen[token] = true
            result[#result + 1] = token
        elseif not allowed[token] then
            msg.warn('Unknown layout item: ' .. token)
        end
    end
    return result
end
local function text(ass, x, y, size, value, color, alpha, align, clip)
    ass:new_event()
    ass:append(string.format('{\\an%d\\pos(%.1f,%.1f)\\fs%.1f\\fn%s\\bord0\\shad0\\1c&H%s&\\alpha&H%02X&}',
        align or 4, x, y, size * opt.font_scale, state.font, bgr(color or colors.text),
        math.floor(255 * (1 - (alpha or 1)))))
    if clip then
        ass:append(string.format('{\\clip(%d,%d,%d,%d)}', math.floor(clip.x), math.floor(clip.y),
            math.ceil(clip.x + clip.w), math.ceil(clip.y + clip.h)))
    end
    ass:append(escape(value))
end
local function start_shape(ass, color, alpha, border)
    ass:new_event()
    local outline = border and '\\bord1\\3c&H' .. bgr(border) .. '&' or '\\bord0'
    ass:append(string.format('{\\an7\\pos(0,0)%s\\shad0\\1c&H%s&\\alpha&H%02X&}',
        outline, bgr(color), math.floor(255 * (1 - (alpha or 1)))))
    ass:draw_start()
end
local function rectangle(ass, x, y, w, h, color, radius, alpha, border)
    if w <= 0 or h <= 0 then return end
    start_shape(ass, color, alpha, border)
    if radius and radius > 0 then ass:round_rect_cw(x, y, x + w, y + h, math.min(radius, w / 2, h / 2))
    else ass:rect_cw(x, y, x + w, y + h) end
    ass:draw_stop()
end
local function region(x, y, w, h, action, data)
    local hit = {x = x, y = y, w = w, h = h, action = action, data = data}
    state.regions[#state.regions + 1] = hit
    return hit
end
local function hovered(rect) return state.hover and contains(rect, state.mouse_x, state.mouse_y) end
local function button(ass, x, y, w, value, action, alpha, height, data)
    height = height or opt.button_size
    local hit = region(x, y, w, height, action, data)
    if hovered(hit) then rectangle(ass, x, y, w, height, colors.hover, opt.radius * .4, alpha) end
    text(ass, x + w / 2, y + height / 2, 13, value, colors.text, alpha, 5)
    return hit
end
local function tracks(kind)
    local result = {}
    local selected = mp.get_property(list_properties[kind], 'no')
    for _, track in ipairs(mp.get_property_native('track-list', {})) do
        if track.type == kind then
            local name = track.title or languages[track.lang] or track.lang
            if not name or name == '' then name = (kind == 'sub' and '字幕 ' or '音軌 ') .. track.id end
            local detail = {}
            if track.lang then detail[#detail + 1] = track.lang end
            if track.codec then detail[#detail + 1] = track.codec:upper() end
            if track['demux-channel-count'] then detail[#detail + 1] = track['demux-channel-count'] .. ' 聲道' end
            detail[#detail + 1] = track.external and '外掛' or '內嵌'
            result[#result + 1] = {id = track.id, name = name, detail = table.concat(detail, ' · '), selected = tostring(track.id) == selected}
        end
    end
    if kind == 'sub' then result[#result + 1] = {id = 'no', name = '關閉字幕', detail = '', selected = selected == 'no'} end
    return result
end
local function playlist()
    local result = {}
    local current = mp.get_property_number('playlist-pos', -1)
    for index, entry in ipairs(mp.get_property_native('playlist', {})) do
        local path = entry.filename or ''
        local name = entry.title
        if not name or name == '' then
            if not path:find('://', 1, true) then name = path:match('[^/\\]+$') end
        end
        if not name or name == '' or name:find('://', 1, true) then name = '播放項目 ' .. index end
        result[#result + 1] = {id = index - 1, name = name, detail = '', selected = index - 1 == current}
    end
    return result
end
local function speeds()
    local result = {}
    local current = mp.get_property_number('speed', 1)
    for _, speed in ipairs({.75, 1, 1.25, 1.5, 2}) do
        result[#result + 1] = {id = speed, name = speed .. '×', detail = '', selected = math.abs(current - speed) < .001}
    end
    return result
end
local function set_number(name, value)
    if math.abs(mp.get_property_number(name, 0) - value) > .0001 then mp.set_property_number(name, value) end
end
local function update_subtitle_margin(hud_top, height, scale, use_margins)
    local property = saved_sub_offset and 'sub-margin-y-offset' or 'sub-margin-y'
    local margin = saved_sub_offset or saved_sub_margin
    if hud_top and mp.get_property('sub-align-y', 'bottom') == 'bottom' then
        local dims = mp.get_property_native('osd-dimensions', {})
        local screen_height = height * scale
        local inset = (height - hud_top + 16) * scale
        local area_height = screen_height
        if not use_margins then
            inset = inset - (dims.mb or 0)
            area_height = area_height - (dims.mt or 0) - (dims.mb or 0)
        end
        -- mpv measures subtitle margins in pixels at a height of 720.
        local target = clamp(inset * 720 / math.max(1, area_height), 0, 576)
        if saved_sub_offset then target = target - mp.get_property_number('sub-margin-y', saved_sub_margin) end
        margin = math.max(margin, target)
    end
    set_number(property, math.floor(margin + .5))
end
local function close_sidebar()
    state.sidebar = false
    redraw()
end
local function toggle_sidebar(view)
    state.sidebar = not state.sidebar or state.sidebar_view ~= view
    state.sidebar_view = view
    state.last_move = mp.get_time()
    redraw()
end
local function set_bindings(active)
    if active == bindings_active then return end
    bindings_active = active
    if active then
        -- Keep window dragging from taking over a control drag.
        mp.enable_key_bindings(mouse_section, 'allow-hide-cursor')
    else
        mp.disable_key_bindings(mouse_section)
    end
end
local function publish()
    mp.set_property_native('user-data/modern-osc', {
        sidebar = state.sidebar, sidebar_view = state.sidebar_view, pinned = state.pinned, width = opt.width,
        subtitles = tracks('sub'), audio = tracks('audio'), hud = state.hud,
        sidebar_side = opt.sidebar_side, sidebar_layout = state.effective_sidebar_layout,
        sidebar_order = sidebar_order, active_group = state.active_group,
        controls_layout = opt.controls_layout, control_groups = control_groups,
        controls = state.control_cells, viewport = state.viewport, sidebar_rect = state.sidebar_rect,
        sidebar_mode = state.effective_sidebar_mode,
    })
end
local function draw_group(ass, x, y, width, kind, rows, list, show_heading)
    if show_heading then
        text(ass, x + 17, y + state.group_heading / 2, 13, list_titles[kind], colors.muted)
        y = y + state.group_heading
    end
    local scroll = state.scroll[kind] or 0
    if state.reveal_selected[kind] then
        for index, track in ipairs(list) do
            if track.selected then
                if index <= scroll then scroll = index - 1
                elseif index > scroll + rows then scroll = index - rows end
                break
            end
        end
        state.reveal_selected[kind] = false
    end
    scroll = clamp(scroll, 0, math.max(0, #list - rows))
    state.scroll[kind] = scroll
    local row_height = state.track_row_height
    state.groups[kind] = {x = x, y = y, w = width, h = rows * row_height, rows = rows, count = #list}
    if #list == 0 then
        text(ass, x + 18, y + 22, 13, kind == 'audio' and '這個檔案沒有音軌' or '播放清單是空的', colors.muted)
    end
    for slot = 1, rows do
        local track = list[scroll + slot]
        if not track then break end
        local row_y = y + (slot - 1) * row_height
        local hit = region(x + 10, row_y, width - 20, row_height - 3, 'select-row', {kind = kind, id = track.id})
        if track.selected or hovered(hit) then
            rectangle(ass, hit.x, hit.y, hit.w, hit.h, track.selected and colors.selected or colors.hover, opt.radius * .44, opt.sidebar_opacity)
        end
        local cy = row_y + row_height / 2
        rectangle(ass, x + 21, cy - 5, 10, 10, colors.track, 5)
        if track.selected then rectangle(ass, x + 23, cy - 3, 6, 6, colors.accent, 3) end
        local clip = {x = x + 42, y = row_y, w = width - 57, h = row_height - 3}
        text(ass, x + 43, row_y + (track.detail == '' and row_height / 2 or row_height * .31), 14, track.name, colors.text, 1, 4, clip)
        if track.detail ~= '' then text(ass, x + 43, row_y + row_height * .69, 11, track.detail, colors.muted, 1, 4, clip) end
    end
    if #list > rows then
        local height = rows * row_height
        local thumb = math.max(12, height * rows / #list)
        local top = y + (height - thumb) * scroll / (#list - rows)
        rectangle(ass, x + width - 5, top, 2, thumb, colors.muted, 1)
    end
    return y + rows * row_height + 13
end

local function control_width(name)
    if name == 'volume' then return opt.button_size + 62 end
    if name == 'play' then return opt.button_size + 10 end
    return opt.button_size
end

local function arrange_controls(width)
    local cells, widths = {}, {}
    local spacing = opt.button_spacing
    local row_height = math.ceil(math.max(opt.button_size + 4, 42 * opt.font_scale))
    local total, populated = 0, 0
    for index, group in ipairs(control_groups) do
        local group_width = 0
        for _, name in ipairs(group.items) do group_width = group_width + math.min(control_width(name), width) end
        group_width = group_width + math.max(0, #group.items - 1) * spacing
        widths[index] = group_width
        total = total + group_width
        if #group.items > 0 then populated = populated + 1 end
    end
    total = total + math.max(0, populated - 1) * 8
    if total <= width then
        local center_min = widths[1] > 0 and widths[1] + 8 or 0
        local center_max = width - widths[2] - (widths[3] > 0 and widths[3] + 8 or 0)
        local offsets = {0, clamp((width - widths[2]) / 2, center_min, center_max), width - widths[3]}
        for index, group in ipairs(control_groups) do
            local x = offsets[index]
            for _, name in ipairs(group.items) do
                local item_width = math.min(control_width(name), width)
                cells[#cells + 1] = {name = name, x = x, y = 0, w = item_width, h = row_height}
                x = x + item_width + spacing
            end
        end
        return cells, populated > 0 and row_height or 0
    end

    local y = 0
    for _, group in ipairs(control_groups) do
        local rows, row, used = {}, {}, 0
        for _, name in ipairs(group.items) do
            local item_width = math.min(control_width(name), width)
            local gap = #row > 0 and spacing or 0
            if #row > 0 and used + gap + item_width > width then
                rows[#rows + 1] = {items = row, width = used}
                row, used, gap = {}, 0, 0
            end
            row[#row + 1] = {name = name, w = item_width}
            used = used + gap + item_width
        end
        if #row > 0 then rows[#rows + 1] = {items = row, width = used} end
        for _, line in ipairs(rows) do
            local x = 0
            if group.align == 'center' then x = (width - line.width) / 2
            elseif group.align == 'right' then x = width - line.width end
            for _, item in ipairs(line.items) do
                cells[#cells + 1] = {name = item.name, x = x, y = y, w = item.w, h = row_height}
                x = x + item.w + spacing
            end
            y = y + row_height
        end
    end
    return cells, y
end

local function control_heights(body_height)
    local grip_height = opt.controls_layout == 'bottom' and 8 or 19
    local timeline_height = math.ceil(30 * opt.font_scale)
    return grip_height, timeline_height, grip_height + body_height + timeline_height + 8
end

local function apply_options(changed)
    opt.width = math.max(180, opt.width)
    opt.sidebar_width = math.max(160, opt.sidebar_width)
    opt.hide_delay = math.max(0, opt.hide_delay)
    opt.scale = clamp(opt.scale, .5, 3)
    opt.font_scale = clamp(opt.font_scale, .75, 1.6)
    opt.button_size = clamp(opt.button_size, 24, 56)
    opt.button_spacing = clamp(opt.button_spacing, 0, 20)
    opt.radius = clamp(opt.radius, 0, 40)
    opt.panel_opacity = clamp(opt.panel_opacity, 0, 1)
    opt.sidebar_opacity = clamp(opt.sidebar_opacity, 0, 1)
    if opt.controls_layout ~= 'bottom' then opt.controls_layout = 'floating' end
    if opt.sidebar_side ~= 'left' then opt.sidebar_side = 'right' end
    if opt.sidebar_mode ~= 'overlay' then opt.sidebar_mode = 'docked' end
    if opt.sidebar_layout ~= 'tabs' then opt.sidebar_layout = 'stacked' end
    for name, fallback in pairs(default_colors) do
        local value = opt['color_' .. name]:gsub('^#', '')
        colors[name] = value:match('^%x%x%x%x%x%x$') and value or fallback
    end
    local seen = {}
    control_groups = {
        {align = 'left', items = parse_order(opt.controls_left, control_names, seen)},
        {align = 'center', items = parse_order(opt.controls_center, control_names, seen)},
        {align = 'right', items = parse_order(opt.controls_right, control_names, seen)},
    }
    -- Account for the tallest wrapped control layout when choosing the OSD scale.
    local min_panel_width = opt.controls_layout == 'bottom' and min_video_width or math.min(opt.width, min_video_width - 24)
    local _, body_height = arrange_controls(min_panel_width - 24)
    local _, _, panel_height = control_heights(body_height)
    min_osd_height = math.max(320, panel_height + 24)

    local groups = {}
    sidebar_order = parse_order(opt.sidebar_order, {sub = true, audio = true}, groups)
    if #sidebar_order == 0 then
        sidebar_order = {'sub', 'audio'}
        groups = {sub = true, audio = true}
    end
    if not groups[state.active_group] then state.active_group = sidebar_order[1] end
    if not changed or changed.sidebar_open then
        state.sidebar = opt.sidebar_open
        state.sidebar_view = 'tracks'
    end
    for key, properties in pairs(style_options) do
        if not changed or changed[key] then
            for name, value in pairs(properties) do
                if saved_style[name] then mp.set_property(name, opt[key] and value or saved_style[name]) end
            end
        end
    end
    state.drag, state.pressed = nil, nil
    state.reveal_selected = {sub = true, audio = true, playlist = true, speed = true}
    state.last_move = mp.get_time()
    redraw()
end

-- Draw vector icons on a 24-unit grid so they use the same shapes on each OS.
local speaker = {2, 9, 6, 9, 11, 5, 11, 19, 6, 15, 2, 15, 2, 9}
local rotation = {
    {20, 7, 17, 4.7, 13.5, 3.2, 9.4, 3.4, 6, 5, 3.8, 8, 3, 12, 4, 15.8,
        6.7, 19, 10.2, 20.7, 14.4, 20.6, 18, 18.4, 20.3, 15.6, 21, 12},
    {21, 3.6, 21, 8, 16.5, 8},
}
local icon_paths = {
    volume = {speaker, {14.5, 8.7, 15.7, 10.1, 16.2, 12, 15.7, 13.9, 14.5, 15.3},
        {18.4, 5.9, 20.3, 8.7, 21, 12, 20.3, 15.3, 18.4, 18.1}},
    mute = {speaker, {15.5, 9, 21, 15}, {21, 9, 15.5, 15}},
    back = rotation,
    forward = rotation,
    tracks = {{5, 3, 19, 3, 21, 5, 21, 19, 19, 21, 5, 21, 3, 19, 3, 5, 5, 3}, {14, 3, 14, 21}},
    playlist = {{3, 5, 21, 5}, {3, 12, 10, 12}, {3, 19, 10, 19}, {14, 11, 21, 15.5, 14, 20, 14, 11}},
    settings = {{3, 5, 10, 5}, {13, 5, 21, 5}, {13, 3, 13, 7}, {3, 12, 7, 12}, {10, 12, 21, 12}, {7, 10, 7, 14},
        {3, 19, 14, 19}, {17, 19, 21, 19}, {17, 17, 17, 21}},
    fullscreen = {{3, 8, 3, 3, 8, 3}, {16, 3, 21, 3, 21, 8}, {21, 16, 21, 21, 16, 21}, {8, 21, 3, 21, 3, 16}},
    close = {{5, 5, 19, 19}, {19, 5, 5, 19}},
    pin = {{8, 4, 16, 4}, {9.5, 4, 9.5, 10, 6, 14, 18, 14, 14.5, 10, 14.5, 4}, {12, 14, 12, 21}},
}
local icon_drawings = {}
local function stroke_path(ass, path, mirror)
    local radius = .9
    for i = 1, #path - 2, 2 do
        local ax, ay, bx, by = path[i], path[i + 1], path[i + 2], path[i + 3]
        if mirror then ax, bx = 24 - ax, 24 - bx end
        local dx, dy = bx - ax, by - ay
        local factor = radius / math.sqrt(dx * dx + dy * dy)
        local nx, ny = dy * factor, -dx * factor
        ass:move_to(ax + nx, ay + ny)
        ass:line_to(bx + nx, by + ny)
        ass:line_to(bx - nx, by - ny)
        ass:line_to(ax - nx, ay - ny)
        ass:line_to(ax + nx, ay + ny)
        ass:round_rect_cw(ax - radius, ay - radius, ax + radius, ay + radius, radius)
    end
    local x, y = path[#path - 1], path[#path]
    if mirror then x = 24 - x end
    ass:round_rect_cw(x - radius, y - radius, x + radius, y + radius, radius)
end
for name, paths in pairs(icon_paths) do
    local ass = assdraw.ass_new()
    ass:draw_start()
    for _, path in ipairs(paths) do stroke_path(ass, path, name == 'back') end
    ass:draw_stop()
    icon_drawings[name] = ass.text
end
do
    local ass = assdraw.ass_new()
    ass:draw_start()
    ass:move_to(5, 5)
    ass:bezier_curve(5, 3, 6.2, 2.2, 8.3, 3.4)
    ass:line_to(19.3, 9.9)
    ass:bezier_curve(21.6, 11.2, 21.6, 12.8, 19.3, 14.1)
    ass:line_to(8.3, 20.6)
    ass:bezier_curve(6.2, 21.8, 5, 21, 5, 19)
    ass:line_to(5, 5)
    ass:draw_stop()
    icon_drawings.play = ass.text

    ass = assdraw.ass_new()
    ass:draw_start()
    ass:round_rect_cw(5.5, 3.5, 10, 20.5, 1.4)
    ass:round_rect_cw(14, 3.5, 18.5, 20.5, 1.4)
    ass:draw_stop()
    icon_drawings.pause = ass.text
end

local control_labels = {back = '倒退 5 秒', forward = '前進 5 秒', tracks = sidebar_titles.tracks,
    playlist = sidebar_titles.playlist, settings = sidebar_titles.settings}

local function draw_icon(ass, icon, x, y, size, color, alpha)
    local scale = size * (100 / 24)
    ass:new_event()
    ass:append(string.format('{\\an7\\pos(%.2f,%.2f)\\fscx%.2f\\fscy%.2f\\bord0\\shad0\\1c&H%s&\\alpha&H%02X&}',
        x, y, scale, scale, bgr(color), math.floor(255 * (1 - alpha))))
    ass:append(icon_drawings[icon])
end

local function icon_button(ass, x, y, width, height, action, icon, label, alpha, selected)
    local hit = region(x, y, width, height, action)
    if hovered(hit) then
        rectangle(ass, x, y + 3, width, height - 6, colors.hover, opt.radius * .4, alpha)
        state.hint = {x = x + width / 2, label = label}
    end
    local size = math.min(width, height, opt.button_size) * .52
    draw_icon(ass, icon, x + (width - size) / 2, y + (height - size) / 2, size,
        selected and colors.accent or colors.text, alpha)
end

local function draw_window_close(ass, width)
    if not is_windows then return end
    local fullscreen = mp.get_property_native('fullscreen', false)
    local has_title_bar = mp.get_property_native('border', true) and mp.get_property_native('title-bar', true)
    if not fullscreen and has_title_bar then return end

    local right = width
    if state.sidebar_rect and opt.sidebar_side == 'right' then right = state.sidebar_rect.x end
    local size, inset = 32, 8
    local x = math.max(4, right - size - inset)
    if fullscreen and not hovered({x = x - 16, y = 0, w = size + 24, h = size + 20}) then return end

    local hit = region(x, inset, size, size, 'close-window')
    rectangle(ass, x, inset, size, size, hovered(hit) and colors.hover or colors.panel, opt.radius * .5, 1, colors.border)
    draw_icon(ass, 'close', x + 7, inset + 7, 18, colors.text, 1)
    return hit
end

local function draw_slider(ass, x, y, width, progress, alpha, fill)
    rectangle(ass, x, y - 1.5, width, 3, colors.track, 1.5, alpha)
    if progress == nil then return end
    local filled = width * clamp(progress, 0, 1)
    rectangle(ass, x, y - 1.5, filled, 3, fill, 1.5, alpha)
    rectangle(ass, x + filled - 3.8, y - 3.8, 7.6, 7.6, fill, 3.8, alpha)
end

local function draw_control(ass, cell, x, y, alpha)
    x, y = x + cell.x, y + cell.y
    local name, height = cell.name, cell.h
    if name == 'volume' then
        local volume = mp.get_property_number('volume', 70)
        local muted = mp.get_property_native('mute')
        local button_width = math.min(opt.button_size, cell.w - 16)
        icon_button(ass, x, y, button_width, height, 'mute', muted and 'mute' or 'volume',
            muted and '取消靜音' or '靜音', alpha)
        local slider = region(x + button_width + 2, y + 4, cell.w - button_width - 4, height - 8, 'volume')
        draw_slider(ass, slider.x, y + height / 2, slider.w, volume / 100, alpha, muted and colors.muted or colors.accent)
        return
    end
    local icon, label = name, control_labels[name]
    local selected = state.sidebar and state.sidebar_view == name
    if name == 'play' then
        icon = mp.get_property_native('pause') and 'play' or 'pause'
        label = icon == 'play' and '播放' or '暫停'
    elseif name == 'pin' then
        selected = state.pinned
        label = selected and '解除固定' or '固定控制列'
    elseif name == 'fullscreen' then
        label = mp.get_property_native('fullscreen') and '離開全螢幕' or '全螢幕'
    end
    icon_button(ass, x, y, cell.w, height, name, icon, label, alpha, selected)
end

local function draw_sidebar(ass, x, width, height)
    state.sidebar_rect = {x = x, y = 0, w = width, h = height}
    rectangle(ass, x, 0, width, height, colors.sidebar, 0, opt.sidebar_opacity)
    local header_height = math.ceil(math.max(50 * opt.font_scale, opt.button_size + 10))
    local header_clip = {x = x + 17, y = 0, w = width - 68, h = header_height}
    local title_size = math.min(16, (width - 72) / (5 * opt.font_scale))
    local view = state.sidebar_view
    text(ass, x + 17, header_height / 2, title_size, sidebar_titles[view], colors.text, 1, 4, header_clip)
    button(ass, x + width - 44, (header_height - opt.button_size) / 2, 34, '×', 'close-sidebar', 1)
    local y = header_height + 9
    if view == 'playlist' then
        local rows = math.max(1, math.floor((height - y - 13) / state.track_row_height))
        draw_group(ass, x, y, width, 'playlist', rows, playlist(), false)
        return
    elseif view == 'settings' then
        local pin_label = state.pinned and '解除固定控制列' or '固定控制列'
        button(ass, x + 10, y, width - 20, pin_label, 'pin', 1, state.track_row_height)
        y = y + state.track_row_height + 6
        local rows = math.max(1, math.floor((height - y - state.group_heading - 13) / state.track_row_height))
        draw_group(ass, x, y, width, 'speed', rows, speeds(), true)
        return
    end
    local lists = {sub = tracks('sub'), audio = tracks('audio')}
    local minimum_height = y + #sidebar_order * (state.group_heading + state.track_row_height + 13)
    local use_tabs = #sidebar_order > 1 and (opt.sidebar_layout == 'tabs' or height < minimum_height)
    state.effective_sidebar_layout = use_tabs and 'tabs' or 'stacked'
    if use_tabs then
        local tab_height = math.ceil(math.max(32, opt.button_size) * opt.font_scale)
        local tab_width = (width - 20) / #sidebar_order
        for index, kind in ipairs(sidebar_order) do
            local tab_x = x + 10 + (index - 1) * tab_width
            if state.active_group == kind then rectangle(ass, tab_x, y, tab_width, tab_height, colors.selected, opt.radius * .4, opt.sidebar_opacity) end
            button(ass, tab_x, y, tab_width, list_titles[kind], 'tab', 1, tab_height, {kind = kind})
        end
        y = y + tab_height + 12
        local rows = math.max(1, math.floor((height - y - 13) / state.track_row_height))
        draw_group(ass, x, y, width, state.active_group, rows, lists[state.active_group], false)
        return
    end
    local budget = math.max(#sidebar_order, math.floor((height - y - #sidebar_order * (state.group_heading + 13)) / state.track_row_height))
    local row_counts, remaining = {}, budget
    for index, kind in ipairs(sidebar_order) do
        local count = math.max(1, #lists[kind])
        local share = math.max(1, math.floor(remaining / (#sidebar_order - index + 1)))
        row_counts[index] = math.min(count, share)
        remaining = remaining - row_counts[index]
    end
    for index, kind in ipairs(sidebar_order) do
        local extra = math.min(remaining, math.max(0, #lists[kind] - row_counts[index]))
        row_counts[index] = row_counts[index] + extra
        remaining = remaining - extra
    end
    for index, kind in ipairs(sidebar_order) do
        y = draw_group(ass, x, y, width, kind, row_counts[index], lists[kind], true)
    end
end

draw = function()
    local pixel_w, pixel_h = mp.get_osd_size()
    if pixel_w <= 0 or pixel_h <= 0 then return end
    local preferred_scale = math.max(.5, mp.get_property_number('display-hidpi-scale', 1) * opt.scale)
    local scale = math.min(preferred_scale, pixel_w / 360, pixel_h / min_osd_height)
    local w, h = pixel_w / scale, pixel_h / scale
    state.scale, state.width, state.height = scale, w, h
    state.font = (opt.font ~= '' and opt.font or mp.get_property('osd-font', 'sans-serif')):gsub('[{}\\]', '')
    state.track_row_height = math.ceil(48 * opt.font_scale)
    state.group_heading = math.ceil(34 * opt.font_scale)
    local has_file = mp.get_property('path') ~= nil
    local sidebar_w = state.sidebar and has_file and math.min(opt.sidebar_width, w - 24) or 0
    local compact_sidebar = sidebar_w > 0 and w - sidebar_w < min_video_width
    local left_sidebar = sidebar_w > 0 and opt.sidebar_side == 'left'
    local viewport = {
        x = left_sidebar and not compact_sidebar and sidebar_w or 0, y = 0,
        w = compact_sidebar and w or w - sidebar_w, h = h,
    }
    state.effective_sidebar_mode = compact_sidebar and 'overlay' or opt.sidebar_mode
    state.effective_sidebar_layout = opt.sidebar_layout
    state.viewport = viewport
    local ass = assdraw.ass_new()
    state.regions, state.groups, state.sidebar_rect, state.hint = {}, {}, nil, nil
    for _, side in ipairs({'left', 'right'}) do
        local extra = state.effective_sidebar_mode == 'docked' and opt.sidebar_side == side and sidebar_w / w or 0
        local margin = saved_margins[side] + math.min(extra, math.max(0, .85 - saved_margins[side]))
        set_number('video-margin-ratio-' .. side, margin)
    end
    local use_margins = saved_sub_use_margins
    if sidebar_w > 0 and state.effective_sidebar_mode == 'docked' then use_margins = false end
    if use_margins ~= nil and mp.get_property_native('sub-use-margins') ~= use_margins then
        mp.set_property_native('sub-use-margins', use_margins)
    end
    if sidebar_w > 0 then draw_sidebar(ass, left_sidebar and 0 or w - sidebar_w, sidebar_w, h) end

    local bottom = opt.controls_layout == 'bottom'
    local bw = bottom and viewport.w or math.min(opt.width, viewport.w - 24)
    local cells, body_height = arrange_controls(bw - 24)
    local grip_height, timeline_height, bh = control_heights(body_height)
    local bx = bottom and viewport.x or viewport.x + 12 + state.x_ratio * math.max(0, viewport.w - bw - 24)
    local by = bottom and h - bh or 12 + state.y_ratio * math.max(0, h - bh - 24)
    state.hud = {x = bx, y = by, w = bw, h = bh}
    state.control_cells = cells
    local opacity = has_file and not compact_sidebar and state.alpha or 0
    if opacity > .01 then
        rectangle(ass, bx, by, bw, bh, colors.panel, bottom and 0 or opt.radius, opacity * opt.panel_opacity, colors.border)
        if not bottom then
            region(bx + bw / 2 - 45, by, 90, grip_height, 'drag')
            rectangle(ass, bx + bw / 2 - 12, by + 9, 24, 3, colors.muted, 2, opacity)
        end
        for _, cell in ipairs(cells) do draw_control(ass, cell, bx + 12, by + grip_height, opacity) end
        local timeline_y = by + grip_height + body_height
        local center_y = timeline_y + timeline_height / 2
        local duration = mp.get_property_number('duration', 0)
        local position = mp.get_property_number('time-pos', 0)
        local elapsed_label, duration_label = time_label(position), time_label(duration)
        local time_chars = math.max(#elapsed_label, #duration_label)
        local time_width = math.min(math.ceil(25 + time_chars * 7 * opt.font_scale), (bw - 36) / 2)
        local time_size = math.min(14, (time_width - 18) / (time_chars * .59 * opt.font_scale))
        text(ass, bx + 17, center_y, time_size, elapsed_label, colors.text, opacity)
        text(ass, bx + bw - 17, center_y, time_size, duration_label, colors.muted, opacity, 6)
        local seek = region(bx + time_width, timeline_y, bw - time_width * 2, timeline_height, 'seek')
        draw_slider(ass, seek.x, center_y, seek.w, duration > 0 and position / duration or nil, opacity, colors.accent)
        if state.hint then
            local hint_w, hint_h = 100 * opt.font_scale, 24 * opt.font_scale
            local hint_x = clamp(state.hint.x - hint_w / 2, viewport.x + 4, viewport.x + viewport.w - hint_w - 4)
            local hint_y = by >= hint_h + 8 and by - hint_h - 6 or by + bh + 6
            rectangle(ass, hint_x, hint_y, hint_w, hint_h, colors.panel, 6, opacity, colors.border)
            text(ass, hint_x + hint_w / 2, hint_y + hint_h / 2, 11, state.hint.label, colors.text, opacity, 5)
        end
    end
    local window_close = draw_window_close(ass, w)
    local raise_subs = opacity > .1 and by + bh > h - 65
    update_subtitle_margin(raise_subs and by or nil, h, scale, use_margins)
    local in_sidebar = state.hover and contains(state.sidebar_rect, state.mouse_x, state.mouse_y)
    local in_hud = opacity > .1 and state.hover and contains(state.hud, state.mouse_x, state.mouse_y)
    set_bindings(in_sidebar or in_hud or hovered(window_close) or state.drag ~= nil or state.pressed ~= nil)
    local sidebar_visible = state.sidebar_rect ~= nil
    if sidebar_visible ~= escape_active then
        escape_active = sidebar_visible
        if escape_active then mp.add_forced_key_binding('ESC', 'modern-close', close_sidebar)
        else mp.remove_key_binding('modern-close') end
    end
    overlay.res_x, overlay.res_y, overlay.data = w, h, ass.text
    overlay:update()
    publish()
end

local function update_drag(x, y)
    local drag = state.drag
    if not drag then return end
    if drag.action == 'drag' then
        local x_space = math.max(1, state.viewport.w - state.hud.w - 24)
        local y_space = math.max(1, state.height - state.hud.h - 24)
        state.x_ratio = clamp((x - drag.offset_x - state.viewport.x - 12) / x_space, 0, 1)
        state.y_ratio = clamp((y - drag.offset_y - 12) / y_space, 0, 1)
    elseif drag.action == 'seek' then
        local duration = mp.get_property_number('duration', 0)
        if duration > 0 then mp.commandv('no-osd', 'seek', clamp((x - drag.x) / drag.w, 0, 1) * duration, 'absolute+exact') end
    elseif drag.action == 'volume' then
        mp.set_property_number('volume', clamp((x - drag.x) / drag.w, 0, 1) * 100)
    end
    redraw()
end

click = function(event)
    if event.event == 'down' or event.event == 'press' then
        state.pressed = nil
        for i = #state.regions, 1, -1 do
            local hit = state.regions[i]
            if contains(hit, state.mouse_x, state.mouse_y) then
                if hit.action == 'drag' or hit.action == 'seek' or hit.action == 'volume' then
                    state.drag = {action = hit.action, x = hit.x, w = hit.w,
                        offset_x = state.mouse_x - state.hud.x, offset_y = state.mouse_y - state.hud.y}
                    update_drag(state.mouse_x, state.mouse_y)
                else state.pressed = hit end
                break
            end
        end
    end
    if event.event == 'up' or event.event == 'press' then
        local hit = state.pressed
        state.drag, state.pressed = nil, nil
        if hit and not event.canceled and contains(hit, state.mouse_x, state.mouse_y) then
            if sidebar_titles[hit.action] then toggle_sidebar(hit.action)
            elseif hit.action == 'close-sidebar' then close_sidebar()
            elseif hit.action == 'close-window' then mp.commandv('quit')
            elseif hit.action == 'play' then mp.commandv('no-osd', 'cycle', 'pause')
            elseif hit.action == 'back' then mp.commandv('no-osd', 'seek', -5, 'relative+exact')
            elseif hit.action == 'forward' then mp.commandv('no-osd', 'seek', 5, 'relative+exact')
            elseif hit.action == 'mute' then mp.commandv('no-osd', 'cycle', 'mute')
            elseif hit.action == 'pin' then state.pinned = not state.pinned
            elseif hit.action == 'fullscreen' then mp.commandv('cycle', 'fullscreen')
            elseif hit.action == 'tab' then state.active_group = hit.data.kind
            elseif hit.action == 'select-row' then mp.set_property_native(list_properties[hit.data.kind], hit.data.id) end
        end
        state.last_move = mp.get_time()
        redraw()
    end
end
wheel = function(delta)
    for kind, group in pairs(state.groups) do
        if contains(group, state.mouse_x, state.mouse_y) then
            state.scroll[kind] = clamp(state.scroll[kind] + delta, 0, math.max(0, group.count - group.rows))
            redraw()
            return
        end
    end
    for _, hit in ipairs(state.regions) do
        if contains(hit, state.mouse_x, state.mouse_y) and (hit.action == 'volume' or hit.action == 'mute') then
            mp.commandv('no-osd', 'add', 'volume', -delta * 3)
            return
        elseif contains(hit, state.mouse_x, state.mouse_y) and hit.action == 'seek' then
            mp.commandv('no-osd', 'seek', -delta * 5, 'relative+exact')
            return
        end
    end
end

mp.add_key_binding(nil, 'modern-click', click, {complex = true})
mp.add_key_binding(nil, 'modern-wheel-up', function() wheel(-1) end, {repeatable = true})
mp.add_key_binding(nil, 'modern-wheel-down', function() wheel(1) end, {repeatable = true})
local binding = 'script-binding ' .. mp.get_script_name() .. '/'
mp.set_key_bindings({
    {'MBTN_LEFT', binding .. 'modern-click'},
    {'MBTN_LEFT_DBL', 'ignore'},
    {'WHEEL_UP', 'repeatable ' .. binding .. 'modern-wheel-up'},
    {'WHEEL_DOWN', 'repeatable ' .. binding .. 'modern-wheel-down'},
}, mouse_section, 'force')

mp.observe_property('mouse-pos', 'native', function(_, mouse)
    if not mouse then return end
    state.hover = mouse.hover
    local scale = state.scale or 1
    state.mouse_x, state.mouse_y = mouse.x / scale, mouse.y / scale
    if mouse.hover or state.drag then
        state.last_move = mp.get_time()
        update_drag(state.mouse_x, state.mouse_y)
    end
    redraw()
end)
for _, name in ipairs({'osd-dimensions', 'display-hidpi-scale', 'time-pos', 'duration', 'pause', 'volume', 'mute', 'path',
        'fullscreen', 'border', 'title-bar'}) do
    mp.observe_property(name, 'native', redraw)
end
for kind, property in pairs(list_properties) do
    mp.observe_property(property, 'native', function() state.reveal_selected[kind] = true; redraw() end)
end
mp.observe_property('track-list', 'native', function()
    state.reveal_selected.sub, state.reveal_selected.audio = true, true
    redraw()
end)
mp.observe_property('playlist', 'native', function() state.reveal_selected.playlist = true; redraw() end)
mp.add_periodic_timer(.05, function()
    local over_controls = state.alpha > .1 and hovered(state.hud)
    local keep_visible = state.pinned or state.drag or state.pressed or over_controls or mp.get_property_native('pause')
    local target = (keep_visible or mp.get_time() - state.last_move < opt.hide_delay) and 1 or 0
    if state.alpha ~= target then
        state.alpha = clamp(state.alpha + (target == 1 and .3 or -.2), 0, 1)
        redraw()
    end
end)
local function coordinate_uosc()
    mp.set_property_native('osc', false)
    mp.commandv('script-message-to', 'uosc', 'disable-elements', 'modern-osc', 'timeline,controls,volume,top_bar,pause_indicator')
end
mp.register_script_message('uosc-version', coordinate_uosc)
mp.add_timeout(.3, coordinate_uosc)
mp.register_event('file-loaded', function()
    state.scroll = {}
    state.reveal_selected = {sub = true, audio = true, playlist = true, speed = true}
    state.last_move = mp.get_time()
    coordinate_uosc()
    redraw()
end)
local function toggle_tracks() toggle_sidebar('tracks') end
local function show_tracks()
    state.sidebar, state.sidebar_view = true, 'tracks'
    redraw()
end
mp.add_key_binding('F9', 'tracks-sidebar', toggle_tracks)
mp.register_script_message('toggle-sidebar', toggle_tracks)
mp.register_script_message('show-sidebar', show_tracks)
mp.register_script_message('select-subtitle', function(id) mp.set_property('sid', id) end)
mp.register_script_message('select-audio', function(id) mp.set_property('aid', id) end)
mp.register_script_message('show-track-group', function(kind)
    for _, allowed in ipairs(sidebar_order) do
        if kind == allowed then state.active_group = kind; show_tracks(); return end
    end
end)
mp.register_event('shutdown', function()
    set_bindings(false)
    overlay:remove()
end)
options.read_options(opt, 'modern-osc', apply_options)
apply_options()
