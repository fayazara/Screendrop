---
name: macos-notch-ui
description: >
  Add a Dynamic Island-style notch UI to a macOS app. Use this skill whenever the user wants to
  create a notch overlay, notch extender, Dynamic Island for Mac, notch indicator, or any UI that
  extends from the MacBook notch area. Also trigger when the user mentions "notch shape", "notch
  window", "notch cutout", "notch panel", "recording indicator near the notch", "Dynamic Island
  style", or wants to show status/content that appears to emerge from the hardware notch. This
  covers the NSPanel setup, the NotchShape with concave Bezier ear curves, screen positioning
  math, spring animations, and show/hide choreography.
---

# macOS Notch UI (Dynamic Island Style)

This skill creates a Dynamic Island-style overlay that extends from the MacBook's hardware notch. The overlay is a transparent floating panel positioned flush against the top of the screen, using a custom shape with concave "ear" curves that blend seamlessly with the physical notch cutout.

## Architecture

The implementation has 3 parts:

1. **`NotchWindow` (NSPanel subclass)** -- a borderless, transparent, click-through panel at `CGShieldingWindowLevel` that sits above everything, including the menu bar
2. **`NotchShape` (SwiftUI Shape)** -- draws the Dynamic Island silhouette with concave quadratic Bezier curves at the top corners and convex rounded corners at the bottom
3. **Your content view** -- whatever you want to show inside the notch (status indicators, waveforms, text, icons)

## How It Works

The MacBook notch is a black rectangle at the top-center of the screen. By placing a black-filled `NotchShape` at that exact position at the highest window level, it visually extends the notch area. Content inside the shape appears to "emerge" from the hardware notch.

The key positioning math:

```swift
// Use full screen frame (not visibleFrame) to include the menu bar / notch area
let screen = NSScreen.main!
let x = screen.frame.origin.x + (screen.frame.width - totalWidth) / 2
let y = screen.frame.origin.y + screen.frame.height - totalHeight
```

Using `screen.frame` (not `screen.visibleFrame`) is critical -- `visibleFrame` excludes the menu bar area where the notch lives.

## Reference Files

- `references/NotchWindow.swift` -- Drop-in NSPanel subclass with show/hide and positioning
- `references/NotchShape.swift` -- The Dynamic Island shape with animatable corner radii

## Step-by-Step Integration

### 1. Add the NotchShape

Copy `references/NotchShape.swift`. This is a SwiftUI `Shape` with two configurable corner radii:

- `topCornerRadius` (default 10) -- the concave "ear" curves at the top that mimic the hardware notch's inverse corners
- `bottomCornerRadius` (default 16) -- the standard convex rounded corners at the bottom

Both are animatable via `animatableData`, so SwiftUI can smoothly interpolate shape changes.

### 2. Create Your Content View

Build whatever you want to show inside the notch. The content should be clipped to `NotchShape` and filled with black background:

```swift
struct NotchContentView: View {
    var isVisible: Bool

    var body: some View {
        HStack {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
            Text("Recording")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: isVisible ? 200 : 0)
        .frame(height: 32)
        .background(NotchShape().fill(.black))
        .clipShape(NotchShape())
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
```

### 3. Add the NotchWindow

Copy `references/NotchWindow.swift`. This is a generic NSPanel that:

- Creates a borderless, transparent, non-activating panel
- Positions at `CGShieldingWindowLevel` (above everything)
- Centers at the top of the screen, flush with the top edge
- Ignores mouse events (fully click-through)
- Joins all spaces and survives fullscreen

### 4. Show and Hide

```swift
// Create once and reuse
let notchWindow = NotchWindow()

// Show with your content
let content = NotchContentView(isVisible: true)
notchWindow.showNotch(content: content)

// Hide with spring collapse animation
notchWindow.hideNotch()
```

## Spring Animation Choreography

The Dynamic Island effect comes from a specific animation sequence:

**Show:**
1. Window appears instantly (`orderFront`)
2. On the next runloop tick, `isVisible` toggles to `true`
3. The width animates from 0 to the target width with `.spring(response: 0.35, dampingFraction: 0.75)`

This two-step approach (instant window, then animated content) is necessary because SwiftUI needs the view to be in the hierarchy before it can animate.

**Hide (3-step choreography):**
1. Clear any expanded content (text, details) -- collapses to compact shape
2. After 0.25s, set `isVisible = false` -- triggers the spring width collapse to 0
3. After 0.65s, remove the window (`orderOut`)

The delays are tuned so each animation completes before the next starts. This creates the smooth "shrink into the notch" effect.

```swift
// Step 1: collapse content
state.isExpanded = false

// Step 2: shrink width
DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
    state.isVisible = false
}

// Step 3: remove window
DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
    window.orderOut(nil)
}
```

## Screen Geometry Details

| Property | Value | Why |
|----------|-------|-----|
| Window level | `CGShieldingWindowLevel()` | Above everything including menu bar |
| Position origin | `NSScreen.main.frame` (not `visibleFrame`) | Must include the notch/menu bar area |
| Horizontal | Centered: `(screen.width - totalWidth) / 2` | Aligned with the hardware notch |
| Vertical | Flush top: `screen.height - totalHeight` | Top edge touches the screen edge |
| Collection behavior | `.stationary, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle` | Doesn't move with Spaces, survives fullscreen, hidden from Cmd+Tab |

## Fallback for Non-Notch Macs

Not all Macs have a notch (e.g., external displays, older MacBooks). You can detect this:

```swift
var hasNotch: Bool {
    guard let screen = NSScreen.main else { return false }
    // Notch Macs have a safe area inset at the top
    return screen.safeAreaInsets.top > 0
}
```

For non-notch displays, fall back to a floating pill at the bottom of the screen using `screen.visibleFrame` and standard `.floating` window level.

## Design Guidelines

- **Fill the shape with solid black** -- this is what makes it blend with the hardware notch
- **Use white or colored text/icons** on the black background for contrast
- **Keep content compact** -- the notch area is small. A single row with an icon + short text works best
- **Use red for recording indicators** -- matches iOS convention
- **Animate width, not opacity** -- the Dynamic Island effect is about the shape growing/shrinking, not fading
