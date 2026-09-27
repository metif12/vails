// mobile.v — mobile entry stubs, pure-V prep (M0).
// Zero prerequisites: no SDK/NDK, no Gradle/Xcode. Desktop builds are
// intentional no-ops — phones are fullscreen, so resizable geometry,
// menus and tray do not apply there (see ADR-0006). The Android PoC (M1)
// and iOS scaffold (M3) honor this seam behind `$if android/ios`.
module mobile

// is_mobile reports whether this build targets a mobile OS.
pub fn is_mobile() bool {
	$if android || ios {
		return true
	} $else {
		return false
	}
}

// apply_geometry requests a window size. On desktop it is an intentional
// no-op (after validating the size); on mobile backends it fails
// explicitly until M1/M3 implement it.
pub fn apply_geometry(width int, height int) ! {
	if width <= 0 || height <= 0 {
		return error('mobile.apply_geometry: size must be positive')
	}
	$if android || ios {
		return error('mobile.apply_geometry: not implemented yet (M1/M3)')
	} $else {
		return
	}
}
