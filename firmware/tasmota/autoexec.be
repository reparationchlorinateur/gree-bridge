# Runs at every Tasmota boot. Upload together with gree_bus.be, gree_matter.be and gree_tools.be
# (Tools > Manage File system). gree_tools.be is optional: without it the board works the same,
# only the "Gree tools" page (IR brand, bus speed detection, captures) is missing.
load("gree_bus.be")
load("gree_matter.be")
import path
if path.exists("gree_tools.be") load("gree_tools.be") end
