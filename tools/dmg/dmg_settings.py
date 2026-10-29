# dmgbuild settings for Orbit's DMG. Run through make-dmg.sh, which passes:
#   -D app=<path to Orbit.app> -D background=<background.tiff> -D icon=<volume .icns>
import os

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
size = None
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821
badge_icon = None

background = defines["background"]  # noqa: F821
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_icon_preview = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 128

# Icon centres, in window points (top-left origin) — must match render_background.py.
icon_locations = {
    appname: (170, 178),
    "Applications": (490, 178),
    # Anything hidden that Finder might still show goes off-canvas.
    ".background.tiff": (170, 900),
    ".VolumeIcon.icns": (330, 900),
    ".fseventsd": (490, 900),
    ".Trashes": (650, 900),
}
hide_extension = [appname]
