# What DockOutline is

It's not an Outline. It's an Underline.
Why didn't I change it's name? I can't be bothered. This was for me. I'm just letting you have it if you want.

### What is does

This adds a Red or Yellow line under the running apps. I found the macOS default in macOS27 too hard to see on a dark background.

It adds an icon to the menu bar to refresh or quit the app.

There is a ReadMe that tells you how to change the line thickness (width) and recompile the app. If you know a bit of Swift you can edit the colours of the lines. If you know more Swift you can do any with it.

## How to install

### In the Terminal:

```
cd <path to DockOutline folder>
```

```
mkdir -p DockOutline.app/Contents/MacOS

swiftc -parse-as-library DockOutline.swift \
-o DockOutline.app/Contents/MacOS/DockOutline \
-framework AppKit \
-framework ApplicationServices
```
  
```
cat > DockOutline.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DockOutline</string>
    <key>CFBundleIdentifier</key>
    <string>local.dockoutline.app</string>
    <key>CFBundleName</key>
    <string>DockOutline</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>0.3</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF
```

```
codesign --force --deep --sign - DockOutline.app
open DockOutline.app
```

macOS may ask for Accessibility permission. This needs to be granted.
If you are updating the app remove the current permission and allow it again when requested.

Add it to your login items to launch at login/reboot.

---

# The ReadMe

### DockOutline


It polls the Dock every 0.15 seconds (a bit laggy but I didn't want it taking all the CPU cycles!) to make position changes during Dock magnification more responsive.

### Important visual limitation

The Dock icon and its background are normally composited by the Dock. This independent overlay window is drawn above the Dock, so this highlight is a translucent layer over the icon area, not a true layer underneath the icon artwork. If the line is strong or too weak, change `var lineWidth: CGFloat = 4` in OutlineView.


