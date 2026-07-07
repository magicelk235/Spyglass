# dmgbuild settings for Spyglass.dmg — Finder-free window sizing (works on
# macOS 26, where create-dmg's AppleScript step fails with -10000).
# Invoked by build-dmg.sh:
#   dmgbuild -s dmg/dmg-settings.py -D app=<path> -D bg=<tiff> -D icon=<icns> Spyglass Spyglass.dmg
#
# Coordinates: dmgbuild uses a bottom-left origin (y grows upward), unlike
# create-dmg's top-left. Window is 990x630, so a create-dmg top-y of 398 maps
# to bottom-y 630-398 = 232. Icons sit at x 297 (app) / 683 (Applications).
import os.path

app = defines.get("app", "Spyglass.app")
bg  = defines.get("bg", "dmg/assets/dmg-bg.png")
icon = defines.get("icon", None)

app_name = os.path.basename(app)

# Contents of the disk image: the app plus an Applications symlink.
files = [app]
symlinks = {"Applications": "/Applications"}

# Volume icon (the mounted disk's icon in Finder).
if icon:
    icon = icon  # dmgbuild reads `icon` for the volume icon

# Window & layout.
background = bg
window_rect = ((200, 120), (990, 630))
icon_size = 165
icon_locations = {
    app_name:       (297, 232),
    "Applications": (683, 232),
}

# Cosmetics matching the old create-dmg output.
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
text_size = 20
label_pos = "bottom"

format = "UDZO"      # compressed, same as create-dmg default
