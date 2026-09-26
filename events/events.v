// events.v — synchronous pub/sub bus for V-side handlers
// (JS delivery via evaluate_javascript arrives in Phase 2).
module events

pub type Handler = fn (data string)

// Bus keeps handlers in registration order; emit runs them synchronously
// and returns how many ran, so tests need no globals or sleeps.
pub struct Bus {
mut:
	handlers map[string][]Handler
}

pub fn new_bus() Bus {
	return Bus{
		handlers: map[string][]Handler{}
	}
}

pub fn (mut b Bus) on(event string, h Handler) {
	b.handlers[event] << h
}

// emit calls every handler registered for event and returns the count.
// Unknown events are a no-op returning 0.
pub fn (b Bus) emit(event string, data string) int {
	hs := b.handlers[event] or { return 0 }
	for h in hs {
		h(data)
	}
	return hs.len
}

pub fn (b Bus) handler_count(event string) int {
	return b.handlers[event] or { return 0 }.len
}
