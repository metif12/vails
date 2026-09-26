// js.v — V -> JS direction of the event bus (guide: v3/pkg/events).
// to_js builds the snippet the native side evaluates (run_javascript) to
// fire a frontend listener registered via window.vails.onEvent.
module events

import jsesc

pub fn to_js(event string, data string) string {
	return "window.vails.__emit('" + jsesc.escape(event) + "', '" + jsesc.escape(data) +
		"');"
}
