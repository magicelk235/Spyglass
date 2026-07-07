-- Minimal Finder styling for the Spyglass DMG, run against a mounted RW volume.
-- create-dmg's bundled template trips a -10000 on macOS 26; this pared-down
-- version uses only the Finder icon-view APIs that still work (verified on 26),
-- so Finder itself writes the background alias (with a correct live cnid) and the
-- icon positions.
--
-- argv: volume_name  win_w win_h  icon_size  app_name  app_x app_y  apps_x apps_y
on run argv
	set volName to item 1 of argv
	set winW to (item 2 of argv) as integer
	set winH to (item 3 of argv) as integer
	set iconSize to (item 4 of argv) as integer
	set appName to item 5 of argv
	set appX to (item 6 of argv) as integer
	set appY to (item 7 of argv) as integer
	set appsX to (item 8 of argv) as integer
	set appsY to (item 9 of argv) as integer

	tell application "Finder"
		set diskRef to disk volName
		open diskRef
		set w to container window of diskRef
		set current view of w to icon view
		set toolbar visible of w to false
		set statusbar visible of w to false
		-- bounds: {left, top, right, bottom}
		set the bounds of w to {200, 120, 200 + winW, 120 + winH}

		set opts to the icon view options of w
		set arrangement of opts to not arranged
		set icon size of opts to iconSize
		set text size of opts to 13
		-- background: point at the folder image Finder can resolve on this volume
		set background picture of opts to file ".background:dmg-background.png" of diskRef

		set position of item appName of diskRef to {appX, appY}
		set position of item "Applications" of diskRef to {appsX, appsY}

		update diskRef without registering applications
		delay 1
		close w
	end tell
end run
