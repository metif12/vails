// channels.v — light streaming channels over the T2 event path (T3).
// Tauri `ipc::Channel` equivalent: a channel id (`ch_<n>`), repeated
// pushes via `to_js`-style eval snippets, explicit close. No native
// changes — the native side only evaluates the snippets on the webview
// main thread. Delivery is `__emit`-compatible: the frontend subscribes
// with `window.vails.onEvent(channel_id, cb)`.
module bridge

import events

// Channel is one streaming subscription. Pushes deliver to the channel
// id (not the source event name) so parallel streams never interleave.
pub struct Channel {
pub:
	id    string
	event string
mut:
	closed bool
}

// is_closed reports whether close() already ran.
pub fn (c Channel) is_closed() bool {
	return c.closed
}

// push_js builds the eval snippet delivering one chunk to the channel
// subscribers. Any string (including '') is a valid chunk; pushing after
// close is an error so producers fail fast instead of losing data silently.
pub fn (c Channel) push_js(data string) !string {
	if c.closed {
		return error('channel closed: ' + c.id)
	}
	return events.to_js(c.id, data)
}

// close_js marks the channel closed and builds the terminal snippet.
// Closing is idempotent: the second and later calls re-emit the close
// marker without failing so deferred cleanups stay safe.
pub fn (mut c Channel) close_js() string {
	c.closed = true
	return events.to_js(c.id + ':close', '')
}

// ChannelHub mints channel ids without globals (see AGENTS.md: no
// globals). Keep one hub per window/router; ids are `ch_<n>`.
pub struct ChannelHub {
mut:
	seq int
}

// new_hub returns an empty hub.
pub fn new_hub() ChannelHub {
	return ChannelHub{}
}

// open mints one channel for the given source event name. The name is
// only a debugging label (empty names rejected); delivery always uses
// the minted id.
pub fn (mut h ChannelHub) open(event string) !Channel {
	if event == '' {
		return error('bad channel: event must not be empty')
	}
	h.seq++
	return Channel{
		id:    'ch_${h.seq}'
		event: event
	}
}
