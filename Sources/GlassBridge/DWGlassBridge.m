#import <AppKit/AppKit.h>

// Kept in a tiny macOS 26-built dylib so the Swift app can continue using the
// stable SDK required by the currently installed Command Line Tools.
void *DWCreateGlassEffectView(void) {
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [NSGlassEffectView new];
        // Clear is the most transparent system Liquid Glass treatment. Keep the
        // popover neutral so the wallpaper and desktop behind it remain visible.
        glass.style = NSGlassEffectViewStyleClear;
        glass.cornerRadius = 26.0;
        glass.tintColor = NSColor.clearColor;
        glass.contentView = [NSView new];
        return (__bridge_retained void *)glass;
    }
    return NULL;
}
