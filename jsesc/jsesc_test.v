module jsesc

fn test_escape_plain() {
	assert escape('hello') == 'hello'
	assert escape('') == ''
}

fn test_escape_quotes_and_backslash() {
	assert escape("it's") == "it\\'s"
	assert escape('a\\b') == 'a\\\\b'
}

fn test_escape_newlines() {
	assert escape('a\nb\rc') == 'a\\nb\\rc'
}

fn test_escape_lt_breaks_script_close() {
	assert escape('</script>') == '\\x3c/script>'
}

fn test_escape_combined() {
	assert escape("x contemplating  <tag>\n'y'") == "x contemplating  \\x3ctag>\\n\\'y\\'"
}
