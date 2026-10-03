// application.v — OS-agnostic app lifecycle (guide: v3/pkg/application).
module application

import state

// AppOptions mirrors the Wails idea of a single options struct, trimmed to
// what the MVP needs. More fields (frameless, fullscreen, …) arrive in Phase 5+.
pub struct AppOptions {
pub mut:
	title      string = 'Vails App'
	width      int    = 1024
	height     int    = 768
	assets_dir string = 'frontend'
}

// App owns services by name and a running flag. It never touches GTK/WebKit;
// webview.run() receives a plain Config derived from these options.
pub struct App {
pub:
	options AppOptions
mut:
	services []string
	running  bool
	// state is the managed app state (T4, Tauri `.manage()` equivalent): one
	// AppState per App, read/written from inside command handlers. Handlers
	// capture `&app` and call set_state/get_state; values stay raw JSON.
	// Named `state` and not `store` so nothing here collides with the
	// persisted `store` service (ADR-0026) - it shares this module's import
	// name, and a field is always reached as `a.state`, never bare.
	state state.AppState
}

pub fn new(opts AppOptions) App {
	return App{
		options: opts
		state:   state.new_appstate()
	}
}

// register_service records a native capability (e.g. 'clipboard').
// Duplicate registration is an error so misconfiguration fails fast.
pub fn (mut a App) register_service(name string) ! {
	if name in a.services {
		return error('service already registered: ' + name)
	}
	a.services << name
}

pub fn (a App) has_service(name string) bool {
	return name in a.services
}

pub fn (a App) is_running() bool {
	return a.running
}

// set_state records val_json under key in the App's managed app state (T4).
pub fn (mut a App) set_state(key string, val_json string) ! {
	a.state.set(key, val_json)!
}

// get_state returns the value stored under key, or an error when absent.
pub fn (a App) get_state(key string) !string {
	return a.state.get(key)!
}

// has_state reports whether key is present in the App's managed app state.
pub fn (a App) has_state(key string) bool {
	return a.state.has(key)
}
