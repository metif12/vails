// updater.v — the pure core of the self-updater (U1).
//
// Pure V, no C, no network, no filesystem. The network, the downloader and
// the swap live in U2-U5; this module owns the DECISION: given the running
// version and a list of published releases, which (if any) should be
// installed. Keeping the decision pure is what makes it testable against a
// table of versions without a server or a temp directory.
module updater

// Channel is the release track an app follows.
pub enum Channel {
	stable
	beta
}

// Version is a parsed semantic version (major.minor.patch, optional pre-release).
pub struct Version {
pub mut:
	major int
	minor int
	patch int
	pre   string // empty for a stable release
}

// parse_version turns "1.2.3" or "1.2.3-rc1" into a Version. Anything that
// does not look like at least "major.minor.patch" is an error.
pub fn parse_version(s string) !Version {
	mut v := Version{}
	// strip a leading 'v' if present
	mut t := s.trim_space()
	if t.starts_with('v') || t.starts_with('V') {
		t = t[1..]
	}
	// split off pre-release
	mut core := t
	if idx := t.index('-') {
		core = t[..idx]
		v.pre = t[idx + 1..]
	}
	parts := core.split('.')
	if parts.len < 3 {
		return error('updater: version needs major.minor.patch, got "' + s + '"')
	}
	v.major = parts[0].int()
	v.minor = parts[1].int()
	v.patch = parts[2].int()
	return v
}

// compare returns -1/0/1 for a vs b. Pre-release versions sort before their
// stable counterpart (1.0.0-rc1 < 1.0.0), and among pre-releases the strings
// are compared lexicographically.
pub fn compare(a Version, b Version) int {
	if a.major != b.major {
		if a.major < b.major { return -1 } else { return 1 }
	}
	if a.minor != b.minor {
		if a.minor < b.minor { return -1 } else { return 1 }
	}
	if a.patch != b.patch {
		if a.patch < b.patch { return -1 } else { return 1 }
	}
	// both stable
	if a.pre == '' && b.pre == '' {
		return 0
	}
	// pre-release sorts before stable
	if a.pre == '' && b.pre != '' {
		return 1
	}
	if a.pre != '' && b.pre == '' {
		return -1
	}
	if a.pre < b.pre { return -1 }
	if a.pre > b.pre { return 1 }
	return 0
}

// Release is one published artifact.
pub struct Release {
pub:
	version Version
	channel Channel
	url     string
	sha256  string
}

// channel_of maps a release's channel string ("stable"/"beta") to the enum.
pub fn channel_from_string(s string) !Channel {
	match s.to_lower() {
		'stable' { return Channel.stable }
		'beta' { return Channel.beta }
		else { return error('updater: unknown channel "' + s + '"') }
	}
}

// should_update reports whether `candidate` is newer than `current` and is on
// a channel the app is willing to follow. A beta app follows beta and stable;
// a stable app follows stable only.
pub fn should_update(current Version, candidate Release, followed Channel) bool {
	if candidate.channel == .beta && followed == .stable {
		return false
	}
	return compare(candidate.version, current) > 0
}

// pick_best returns the newest eligible release, or none if nothing is newer.
pub fn pick_best(current Version, releases []Release, followed Channel) ?Release {
	mut best := ?Release(none)
	for r in releases {
		if !should_update(current, r, followed) {
			continue
		}
		if b := best {
			if compare(r.version, b.version) <= 0 {
				continue
			}
		}
		best = r
	}
	return best
}