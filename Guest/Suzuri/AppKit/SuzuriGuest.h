#pragma once

// Compiled into Ladybird after scripts/apply.sh.
// Start from ladybird_main when --suzuri-guest --port N is present.

#ifdef __cplusplus
extern "C" {
#endif

// Returns 1 if this process is a suzuri guest and the session is live.
int suzuri_guest_try_start(int argc, char const* const* argv);

#ifdef __cplusplus
}
#endif
