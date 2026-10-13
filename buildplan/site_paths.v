module buildplan

import os

// site_paths.v — the docs site's export path rule, kept apart from the veb app
// so it can be tested without a server.
//
// Why it is worth a file of its own: the mapping from a URL to a file under
// `dist/` is the one piece of the site that GitHub Pages depends on absolutely,
// and it is also the piece the first version got wrong twice — once by writing
// `dist` against the current working directory (so a run from the repository
// root put the site next to the Dockerfile), and once by nesting `/404` as
// `dist/404/index.html` when Pages looks for `dist/404.html` by exact name.
//
// Neither failure was visible in the site's own output: both produced files, just
// in the wrong place, which is exactly the class of bug a pure-V unit test
// catches and a manual look at a browser does not. So the rule lives here, next
// to the other build-plan checks, and `docs/site/veb_site.v` calls into it.

// site_root is the repository root, derived from THIS file's directory rather
// than from the current working directory.
//
// It is `os.dir` applied twice — once strips `site_paths.v`, the second strips
// `buildplan/` — rather than a `..` join, because a `..` in the path works and
// then shows up in every log line and every error message as
// `buildplan/../docs/site/dist`, which reads like a bug to anyone reviewing CI.
const site_root = os.dir(os.dir(@FILE))

// site_out_dir is where the export writes, resolved from the repository rather
// than from wherever the command happened to run.
pub fn site_out_dir() string {
	return os.join_path(site_root, 'docs', 'site', 'dist')
}

// site_output_path maps a route URL to the file the export must write.
//
// The three shapes Pages serves directly, and the reason each is special-cased:
//
//   `/`        -> `dist/index.html`            the only path with no subdirectory
//   `/404`     -> `dist/404.html`              exact name; Pages looks for this
//                                              and NOTHING else, which is why
//                                              nesting it as a directory breaks it
//   `/docs/x`  -> `dist/docs/x/index.html`    a nested path needs an index, not
//                                              a file named `x`
//
// A trailing slash is tolerated rather than producing a second file for the same
// page, because a link written `/docs/` and one written `/docs` are the same page
// and a static host that serves two copies has a duplicate-content problem.
pub fn site_output_path(path string) string {
	mut p := path
	if p == '' {
		p = '/'
	}
	if !p.starts_with('/') {
		p = '/' + p
	}
	p = p.trim_right('/')
	if p == '' {
		return os.join_path(site_out_dir(), 'index.html')
	}
	if p == '/404' {
		return os.join_path(site_out_dir(), '404.html')
	}
	return os.join_path(site_out_dir(), p.trim_left('/'), 'index.html')
}

fn test_the_home_page_writes_dist_index_html() {
	out := site_output_path('/')
	assert out.ends_with('docs/site/dist/index.html') || out.ends_with('docs\\site\\dist\\index.html')
	assert !out.ends_with('dist/index.html/index.html')
}

fn test_the_404_page_is_a_file_not_a_directory() {
	// GitHub Pages serves `404.html` by exact name. Nesting it as
	// `dist/404/index.html` leaves Pages to fall back to its own error page,
	// with broken navigation — measured reasoning, not superstition.
	out := site_output_path('/404')
	assert out.ends_with('dist/404.html') || out.ends_with('dist\\404.html')
	assert !out.contains('404/index.html'), out
	assert !out.contains('404\\index.html'), out
}

fn test_a_nested_path_gets_an_index_of_its_own() {
	out := site_output_path('/docs/getting-started')
	assert out.ends_with('dist/docs/getting-started/index.html')
}

fn test_a_trailing_slash_is_the_same_page_not_a_second_one() {
	assert site_output_path('/docs/') == site_output_path('/docs')
	assert site_output_path('/') == site_output_path('')
}

fn test_the_export_path_does_not_depend_on_the_working_directory() {
	// The first version wrote `dist` relative to the CWD, so the same command
	// produced a different site depending on where it was run from. This asserts
	// the path is rooted at the repository, which is the property CI needs.
	out := site_output_path('/docs/x')
	assert out.contains('docs/site/dist'), out
	assert !out.starts_with('dist'), out
}
