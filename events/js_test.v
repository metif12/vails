module events

fn test_to_js_shape() {
	snippet := to_js('ready', 'hello')
	assert snippet == "window.vails.__emit('ready', 'hello');"
}

fn test_to_js_escapes() {
	snippet := to_js("it's", 'a\nb</script>')
	assert snippet == "window.vails.__emit('it\\'s', 'a\\nb\\x3c/script>');"
}
