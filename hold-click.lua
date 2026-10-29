-- hold-click.lua: press F to toggle automatic left-click hold. For manual play.
-- Independent of the farm bot. Rejoin or press F again to stop. No log needed.

local UIS = game:GetService("UserInputService")
local on = false

UIS.InputBegan:Connect(function(i, gp)
  if gp then return end
  if i.KeyCode == Enum.KeyCode.F then
    on = not on
    print("[hold] " .. (on and "ON (F to stop)" or "OFF"))
  end
end)

task.spawn(function()
  while true do
    if on then
      local pos = UIS:GetMouseLocation()
      -- try VirtualUser hold first, fall back to VirtualInputManager clicks
      local ok = pcall(function()
        game:GetService("VirtualUser"):Button1Hold()
      end)
      if not ok then
        pcall(function()
          game:GetService("VirtualInputManager"):SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
          task.wait(0.25)
          game:GetService("VirtualInputManager"):SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
        end)
      else
        task.wait(0.4)
        pcall(function() game:GetService("VirtualUser"):Button1Release() end)
      end
    end
    task.wait(0.05)
  end
end)

print("[hold] loaded, press F to toggle auto left-click")
