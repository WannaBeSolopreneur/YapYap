# dmgbuild settings for YapYap.dmg: the window people see when they open the download.
# Used by scripts/release.sh: dmgbuild -s scripts/dmg/settings.py -D app=<YapYap.app> "YapYap" <out.dmg>
# The background (background.tiff, 1x + 2x) is rendered from background.html; the icon spots
# below match the arrow drawn there.
# Paths are relative to the repo root, where release.sh runs it.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"

background = "scripts/dmg/background.tiff"
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    os.path.basename(app): (170, 190),
    "Applications": (490, 190),
}
