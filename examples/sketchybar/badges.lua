-- SketchyBar (SbarLua) example: one item per badged app.
--
-- dock-badge-counter pushes `--trigger dock_badges BADGES=<json>`; SbarLua decodes the JSON
-- value into a Lua table, so the handler only renders. No process is spawned by SketchyBar.
--
-- Add to your config:  require("badges")   (before sbar.event_loop())

local items = {} -- app name -> item

local function item_name(app)
  return "badge." .. app:gsub("[^%w]", "_")
end

-- Hidden anchor item: it exists only to receive the event.
local anchor = sbar.add("item", "badge.anchor", { drawing = false })

anchor:subscribe("dock_badges", function(env)
  local badges = env.BADGES or {}

  -- Remove items for apps whose badge disappeared.
  for app, item in pairs(items) do
    if badges[app] == nil then
      sbar.remove(item.name)
      items[app] = nil
    end
  end

  -- Create or update the rest.
  for app, count in pairs(badges) do
    local item = items[app]
    if not item then
      item = sbar.add("item", item_name(app), {
        position = "right",
        icon = { string = app }, -- swap for an app icon glyph of your choice
        label = { string = count },
      })
      items[app] = item
    else
      item:set({ label = { string = count } })
    end
  end
end)
