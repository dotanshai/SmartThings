local safety = require "contracts.families.zcl.sensors.safety"

local catalogs = {
  safety,
}
local registrations = {}
for _, catalog in ipairs(catalogs) do
  for _, registration in ipairs(catalog.registrations) do
    registrations[#registrations + 1] = registration
  end
end

return {
  id = "zcl.sensors",
  registrations = registrations,
}
