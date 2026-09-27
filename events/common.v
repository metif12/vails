// common.v — platform-neutral system event contract (M0).
// Future mobile backends (M2) and desktop services feed these names on
// the shared `Bus`; frontends subscribe via `window.vails.onEvent`.
// Payloads are JSON strings:
//
//	common:battery `{"level":0-100,"charging":bool}`
//	common:network `{"online":bool,"kind":"wifi"|"cellular"|"other"}`
//	common:theme   `{"mode":"light"|"dark"}`
//	common:low-memory `""` (no payload)
module events

// System event names (the `Common.*` contract). Distinct from app event
// names by the `common:` prefix so capability grants can scope them.
pub const common_battery = 'common:battery'
pub const common_network = 'common:network'
pub const common_theme = 'common:theme'
pub const common_low_memory = 'common:low-memory'
