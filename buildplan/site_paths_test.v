module buildplan

import os

fn test_the_site_output_paths_are_covered() {
	// One assertion per shape, so a failure names the case rather than the file.
	home := site_output_path('/')
	notfound := site_output_path('/404')
	nested := site_output_path('/docs/getting-started')
	assert home.ends_with(os.join_path('docs', 'site', 'dist', 'index.html')), home
	assert notfound.ends_with(os.join_path('docs', 'site', 'dist', '404.html')), notfound
	assert nested.ends_with(os.join_path('docs', 'site', 'dist', 'docs', 'getting-started', 'index.html')), nested
	// And the two that are not merely a prefix of each other, which is the
	// regression that matters: a home page and a 404 page that write the same
	// file would silently overwrite one another during an export.
	assert home != notfound
	assert notfound != nested
}
