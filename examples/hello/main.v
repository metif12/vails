// examples/hello — minimal app: window + ping/pong bridge + ready event.
// Runs on Windows (Edge/WebView2 via webview lib) and Linux (WebKitGTK).
// Needs -gc none on Linux (Boehm GC vs WebKit subprocess fork, see ADR-0005).
module main

import application
import bridge
import webview

fn ping_handler(_ string) !string {
	return 'pong'
}

fn main() {
	mut app := application.new(title: 'Hello Vails')
	app.register_service('clipboard') or { eprintln(err.msg()) }
	mut router := bridge.new_router()
	router.register('ping', ping_handler) or { eprintln(err.msg()) }
	webview.run(
		title:  app.options.title
		width:  app.options.width
		router: &router
		html:   '<h1>Hello from Vails</h1><p id="status">backend: not connected</p><button id="ping">ping backend</button><script>(function(){var s=document.getElementById("status");var b=document.getElementById("ping");if(!window.vails){s.textContent="preview mode: run inside Vails window";b.disabled=true;return;}b.addEventListener("click",function(){window.vails.call("ping","").then(function(r){s.textContent="backend says: "+r;}).catch(function(e){s.textContent="error: "+e.message;});});window.vails.onEvent("ready",function(d){s.textContent="event: "+d;});})();</script>'
	) or {
		eprintln(err.msg())
		exit(1)
	}
}
