// support.v - does this build have a real backend for each service, on THIS
// platform? (Phase 5 S1 wave 2)
//
// A manifest describes a service's *contract* (ADR-0014), which is the same
// on every OS by design. What differs is whether the native half exists, and
// until now only the code knew: a Linux app that granted `notification.*`
// found out at runtime, from a promise rejection, that the feature was a
// stub. `vails doctor` should say it before the app runs.
//
// The answer is per service, from the service's own platform file, so the
// place that decides whether a backend exists is the place that answers.
// This file only collects the answers, and it is pure V (the per-service
// `*_support()` functions live in the `*_windows.c.v` / `*_linux.c.v` files
// or in the explicit-stub branch of the service's own file).
module services

// ServiceStatus is one service's answer. `ready` means "the command works
// here"; `note` says why not, in one line a human can act on. There is no
// third state: a service is either implemented on this platform or it is not,
// and pretending otherwise is the thing this file exists to prevent.
pub struct ServiceStatus {
pub mut:
	name  string
	ready bool
	note  string
}

// supports returns one entry per catalog service, in catalog order, so
// `vails doctor` prints the same order `vails dts` emits.
pub fn supports() []ServiceStatus {
	return [
		dialog_support(),
		notification_support(),
		balloon_support(),
		menu_support(),
		tray_support(),
		clipboard_support(),
		opener_support(),
		os_info_support(),
		drop_support(),
	]
}

// status_names returns the supported service names, in the same order. The
// list-based core of supports()'s test, so a test can assert coverage
// without depending on which platform compiled it.
pub fn status_names(list []ServiceStatus) []string {
	mut out := []string{}
	for s in list {
		out << s.name
	}
	return out
}

// status_of returns one service's status by name, or none when the name is
// not a service (so a caller can ask about a granted service without
// pre-checking).
pub fn status_of(name string) ?ServiceStatus {
	return status_of_in(supports(), name)
}

// status_of_in is the list-based core of status_of.
pub fn status_of_in(list []ServiceStatus, name string) ?ServiceStatus {
	for s in list {
		if s.name == name {
			return s
		}
	}
	return none
}

// report renders the statuses as the lines `vails doctor` prints. One line
// per service, `ok` or `stub` first so a human (or a grep) sees the state
// before the explanation. Pure V, so the formatting is unit-tested and the
// CLI only decides where to print it.
pub fn report(list []ServiceStatus) []string {
	mut out := []string{}
	for s in list {
		mark := if s.ready { 'ok   ' } else { 'stub ' }
		mut line := mark + s.name
		if s.note != '' {
			line += ' - ' + s.note
		}
		out << line
	}
	return out
}

// ok_count counts the services with a real backend here. A one-number
// summary is what makes a regression visible: a service dropping to a stub is
// a line in a changelog, and this is the number that says so.
pub fn ok_count(list []ServiceStatus) int {
	mut n := 0
	for s in list {
		if s.ready {
			n++
		}
	}
	return n
}
