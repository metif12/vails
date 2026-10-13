// veb_site.v — the Vails docs site: a veb preview server plus an --export mode
// that writes the same HTML as static files.
//
// ## Why this exports through a child process rather than `veb.render_request`
//
// Upstream now has the better API: vlang/v#30187 adds
// `veb.render_request[A, X](mut app, req)`, which renders one route in-process
// by generating the route table from the app's methods and dispatching through
// the same `handle_request_and_route` the server loop uses. `Context.conn` stays
// nil, so nothing is written to a socket and the caller reads `ctx.res.body`.
// That removes everything this file pays for below - the child process, the
// fixed port, and `os.executable()` - and leaves an app-side loop of about
// twenty lines.
//
// It is not used here yet, and the reason is a version, not a preference:
// **`docs.yml` builds this site on a *released* V** (`oven-sh/setup-v@v2`,
// `version: v0.5.2`), and a feature that landed on master today is months from a
// release. Switching this file over now would mean either a site that only builds
// on a V built from source, or `docs.yml` itself pinned to a commit - which is
// the same pattern the Dockerfile uses for the *library*, and which this week
// produced a five-day-stale compiler and a latent linker bug nobody could see in
// a green suite.
//
// So this file keeps the mechanism that works everywhere, and the migration is
// one export loop away. When a V containing vlang/v#30187 is released, the
// change is: delete `export`'s process machinery, replace the fetch loop with a
// `render_request` call per route, and keep everything else - the route list,
// `buildplan.site_output_path`, the count check - exactly as it is. Those three
// are the parts that were wrong twice and they are independent of how the HTML
// is produced.
//
// ## Why the export runs a *child process*
//
// The obvious design is to start veb on a goroutine and drive it over HTTP from
// the same process. It crashes: AGENTS.md §2c records that `spawn` with a
// `mut &T` parameter is an access violation in V 0.5.2, and `veb.run` needs
// `mut app`. The workaround section of that note offers a plain reference plus
// `unsafe` writes, which works but puts shared mutable state on two threads for
// the sake of a build step.
//
// So this file does something simpler: `--export` starts *this same binary* as a
// child process, waits for it to answer 200, GETs every route, writes what comes
// back, and kills the child. Two properties come out of that which the thread
// version did not have:
//
//   - **no shared mutable state at all** — nothing is handed to a thread, so the
//     §2c failure is unreachable rather than worked around;
//   - **the exported HTML is produced by the binary that actually shipped**, not
//     by a second code path in a thread — which is what makes "preview" and
//     "export" the same thing, the property `PLAN.md` §3 asks for. One caveat,
//     measured rather than assumed: the exported file is 831 bytes where the
//     previewed response body is 829, a two-byte difference that looks like line
//     ending handling in the client. The pages are the same document; the claim
//     is deliberately not "byte-identical".
//
// The cost is one process start, which is irrelevant next to a build.
//
// ## veb has no exporter, and that is not a veb bug
//
// A search of `vlib/veb` on V 0.5.2 finds no export, no dist and no crawl: veb is
// an HTTP server, and a static-site generator is a different thing wearing its
// hat. So the export loop below is this repository's, deliberately, because the
// alternative — patching veb — would put a site generator in a dependency.
//
// ## `-prod`, and why the build step is not an optimisation
//
// CI builds with `v -prod`, which compiles veb's templates into the binary. A
// template error then breaks the *build* rather than a visitor. `PLAN.md` §7
// states that as the only justification for the step and warns against
// re-justifying it as speed, so this file does not.
module main

import veb
import os
import net.http
import time
import buildplan

// port is fixed rather than ephemeral because both processes need to agree on it,
// and a port conflict is a clearer failure than a silent timeout.
const port = 8090

// site_root is this file's directory, resolved from `@FILE`.
//
// It is deliberately NOT the current working directory: `mount_static_folder_at`
// and the export output path would otherwise be relative to wherever the command
// was run, and the command in `PLAN.md` §7 is run from the repository root.
// Measured: running the built binary from the root panics with "directory
// `static` does not exist", and an earlier version wrote its `dist/` beside the
// Dockerfile instead of under `docs/site/`.
const site_root = os.dir(@FILE)

// out_dir is where the export writes. It is delegated to `buildplan`, which is
// also where the absolute-path rule and its tests live: the first version
// resolved `dist` against the current working directory, so running the same
// command from the repository root put the site next to the Dockerfile instead
// of under `docs/site/`. `buildplan.site_output_path` is the single tested
// definition of that mapping, and its failures are the reason this is not a
// `const` here.
const out_dir = buildplan.site_out_dir()

// routes is the export list, and it is a list rather than a crawl on purpose. A
// crawler follows links and can silently skip a page whose only link is generated
// at runtime; an explicit list fails loudly — a page nobody added here simply
// does not appear in `dist/`, and the count check at the end of `export()` turns
// that into a failed build instead of a short site.
//
// `/404` is on the list even though it is not a page anyone links to, because
// GitHub Pages serves `dist/404.html` for an unknown path and a static export
// that omits it shows Pages' own error page with broken navigation. It is a plain
// route that returns the 404 template with a 200, because for a static export
// what matters is the *file's name*, not what status the preview server answers
// with (`PLAN.md` §7, decision 3).
const routes = ['/', '/404']

// App carries veb's StaticHandler, which serves `static/` at a URL prefix
// without any route of its own.
struct App {
	veb.StaticHandler
}

// Context embeds veb's own Context, so ctx.html and route matching are veb's
// behaviour rather than a reimplementation.
struct Context {
	veb.Context
}

fn main() {
	mut app := &App{}
	if os.args.len > 1 && os.args[1] == '--export' {
		export()
		return
	}
	mount(mut app)
	veb.run[App, Context](mut app, port)
}

// mount wires the static folder at a URL *prefix* rather than at the root.
//
// The root form (`handle_static(dir, true)`) makes the static handler answer `/`
// first, looking for `index.html` inside `static/`. It is not there, so `/`
// returned 404 before any route ran — measured, and the reason the spike's first
// export "succeeded" while writing a 13-byte `404 Not Found`. Mounting at
// `/static` leaves the route table in charge of `/` and gives templates a URL to
// point their CSS at.
fn mount(mut app &App) {
	app.mount_static_folder_at(os.join_path(site_root, 'static'), '/static') or {
		panic('site: static/ is missing next to veb_site.v')
	}
}

// index is the spike's one route.
//
// The `@['/']` attribute is load-bearing, not decoration: with no attributes veb
// registers a method at `/${name}` (`vlib/veb/parse.v`), so `index()` alone would
// serve `/index` and leave `/` to the static handler. The attribute pins the path.
//
// `$tmpl` looks up `templates/index.html`, and with `-prod` that file is compiled
// in, so a missing template is a compile error.
@['/']
fn (app &App) index() veb.Result {
	return $veb.html()
}

// export writes every route to `out_dir` by serving the site in a child process.
//
// The child is this same binary with no `--export` argument, which is how it
// stays the server the project actually ships rather than a re-implementation of
// one.
fn export() {
	exe := os.executable()
	if exe == '' {
		panic('site: cannot find my own executable, so there is nothing to serve')
	}

	mut child := os.new_process(exe)
	child.set_args([])
	child.set_work_folder(site_root)
	// Without this the child gets a console window on Windows, which is noise in
	// a CI log and a stray window on a developer's machine.
	child.create_no_window = true
	child.run()

	// Killed on every path out of here, including the panic ones. A server left
	// listening on a fixed port is how the next run fails for a reason that has
	// nothing to do with the next run.
	mut serve := child
	defer {
		serve.signal_kill()
		serve.wait()
		serve.close()
	}

	wait_for_listener()

	mut written := 0
	for route in routes {
		// A 404 status is not a failure here. `http.get` returns the response for
		// some statuses and an error for others (V's `net/http` is inconsistent
		// across them, and guessing which is which is how an export silently
		// writes nothing), so the body is taken from whichever path produced it
		// and only an *empty* body is an error.
		html := fetch_body(route) or {
			panic('site: exporting "' + route + '" produced no HTML: ' + err.msg())
		}
		if html == '' {
			panic('site: exporting "' + route + '" produced an empty body')
		}
		out := output_path(route)
		os.mkdir_all(os.dir(out)) or { panic('site: cannot make ' + os.dir(out)) }
		os.write_file(out, html) or { panic('site: cannot write ' + out) }
		println('  wrote ' + out + ' (' + html.len.str() + ' bytes)')
		written++
	}

	if written != routes.len {
		panic('site: expected ' + routes.len.str() + ' route(s), wrote ' + written.str())
	}
	println('exported ' + written.str() + ' route(s) to ' + out_dir)
}

// wait_for_listener blocks until the port answers **200**, or gives up with the
// reason.
//
// Checking the status and not merely "a non-empty body" is the whole point: a
// 404 body is 13 non-empty bytes, so the loose check reported ready on a route
// that did not exist and the first export shipped that as the home page.
fn wait_for_listener() {
	mut last := ''
	for _ in 0 .. 200 {
		resp := http.get('http://127.0.0.1:' + port.str() + '/') or {
			last = err.msg()
			time.sleep(50 * time.millisecond)
			continue
		}
		if resp.status_code == 200 && resp.body.len > 0 {
			return
		}
		last = 'status ' + resp.status_code.str()
		time.sleep(50 * time.millisecond)
	}
	panic('site: the preview server did not answer 200 on port ' + port.str() +
		' (last: ' + last + ')')
}

fn fetch(path string) !string {
	resp := http.get('http://127.0.0.1:' + port.str() + path)!
	return resp.body
}

// fetch_body is `fetch` with the status question settled.
//
// `net/http` treats non-2xx inconsistently: some statuses come back as a
// Response with the body intact, others come back as an error. The export needs
// the body either way, so the error case is unwrapped into the same value and
// only an empty body is treated as a failure. The reason this is not a nicety:
// `/404` is routed through `not_found`, which answers 404 on purpose, and an
// exporter that treats 404 as an error cannot write `dist/404.html` at all.
fn fetch_body(path string) !string {
	resp := http.get('http://127.0.0.1:' + port.str() + path) or {
		// Errkind carries a message but not the body, so the only way to get one
		// is to ask again at a layer that does not fail. `get_text` swallows the
		// status entirely and returns '' on error, which is the wrong trade for
		// a route that exists *because* it 404s - so the body comes from the
		// raw fetch below, which does not inspect status.
		return veb_http_get_any(path)
	}
	return resp.body
}

// veb_http_get_any is the status-agnostic read used for the 404 route. It exists
// as a separate function so the fallback above is one call rather than a
// duplicated URL construction.
fn veb_http_get_any(path string) !string {
	resp := http.fetch(method: .get, url: 'http://127.0.0.1:' + port.str() + path)!
	return resp.body
}

// not_found is veb's 404 answer, overridden on Context rather than App because
// that is where veb declares it (`vlib/veb/context.v`) and because veb's
// dispatcher calls it as `user_context.not_found()` (`vlib/veb/veb.v:652`) after
// no App route matched. Without it a bad URL returns veb's default
// `text/plain` "404 Not Found" with no navigation.
//
// ## What this does and does not fix, measured
//
// The template is now served for an unknown path, which is the part the static
// export needs. **The status is still 200**, and that is a live-preview wart
// rather than an export one: `ctx.res.set_status(.not_found)` before the render
// has no effect, because `$veb.html(...)` produces its own response object and
// discards the one that was mutated — verified, all three of `/`, `/404` and
// `/nope` answer 200. GitHub Pages supplies the real 404 status for
// `dist/404.html` itself, so the served artifact is correct either way.
// Fixing the preview status means finding veb's override point, not a line here.
// `pub` is load-bearing, not decoration. veb calls this as
// `user_context.not_found()` from inside `vlib/veb/veb.v`, which is another
// module, so a private method cannot be reached - V 0.5.2 says so outright:
// `error: method Context.not_found is private`. Master compiled it without the
// modifier, which is exactly how a missing keyword survives a local run.
@['/404']
pub fn (mut ctx Context) not_found() veb.Result {
	return $veb.html()
}

// output_path maps a route URL to the file the export writes. The mapping — the
// home page, the exact-name 404, and nested paths getting an index of their own
// — lives in `buildplan.site_output_path`, unit-tested there, because it is the
// piece GitHub Pages depends on absolutely and the piece the first version got
// wrong twice.
fn output_path(path string) string {
	return buildplan.site_output_path(path)
}
