// application.v — OS-agnostic app lifecycle (guide: v3/pkg/application).
module application

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
}

pub fn new(opts AppOptions) App {
	return App{
		options: opts
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
