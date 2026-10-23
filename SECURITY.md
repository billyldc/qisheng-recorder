# Security and privacy

This local recording application captures the user-selected display region
and optionally system audio. It posts real mouse and keyboard events only during an explicitly
started recording, cloud-game login or keep-alive workflow. Permission grants remain under macOS control.

No telemetry, cloud inference, browser-profile collection or recording uploads
are implemented. Favorites screenshots used for recognition are temporary and deleted on
normal completion. A crash may leave a temporary `Qisheng-*` folder; it is never
included in the repository or release package. Logs contain local file paths and
recording state, so review them before sharing a bug report.

Optional cloud-game login credentials are stored in the local login keychain
with an app-bound access list and synchronization disabled. They are never
written into settings, logs, subprocess arguments, clipboard or release packages.
Login uses Safari's visible official cloud-game form after switching to password
mode. Form filling is restricted to HTTPS cloud-game and known first-party login
frames. Account and password entry uses per-character native key-down/key-up
events, not clipboard paste or direct accessibility value replacement. Before
each key pair, the app checks the unlocked session, original official page,
foreground Safari window and exact focused input element. Events are addressed
to Safari's process; loss of focus or cancellation stops the sequence. Characters
that could navigate or submit a form are rejected before typing. Agreement
confirmation retries only submission, not credential entry.
The app attempts one submission per run and pauses for verification
codes and uncertain forms. A separate, off-by-default setting records the user's
agreement to the official user agreement and privacy policy and authorizes
checking their login checkbox in subsequent password logins. The user can revoke
this setting at any time. Ambiguous controls and bundled marketing consent are
not selected. No login or agreement actions run merely by enabling the setting.
After a successful read or save, credentials remain in process memory for the
current unlocked session so repeated login or account-edit actions do not repeat
the same keychain request. The cache is discarded on screen lock, keychain lock,
user-session deactivation, sleep, exit, account removal or replacement. If the
keychain lock observer cannot be installed, reads bypass the cache. Failed,
cancelled and missing reads are not cached or automatically retried. The app
does not modify an existing item's access list or bypass system authentication;
macOS may ask again after an update or keychain lock. Credentials also temporarily
exist in memory while editing or filling. Removing an account retains an
in-memory undo copy for five seconds, then releases it.

Post-recording review is offline OpenCV feature matching against local game card
art, not a hosted AI service. It keeps card-only evidence and candidates beside
the video in a `.review` directory. Source videos and initial JSON are unchanged.
These artifacts, the local review registry, and user-corrected labels are private
data; do not include them in a public issue or source release. The application
does not upload them or automatically add them to a training dataset.

Reference updates use HTTPS requests to Yatta for its public catalog and images.
The optional daily check is disabled by default and does not attach screenshots,
player information, cookies or API keys. Like any download, it exposes the client's
network address to the service. Failed or invalid downloads do not replace a
working image; incomplete updates are reported explicitly. Application updates
use GitHub CLI authentication stored outside the repository, never an embedded token.

Report vulnerabilities privately to the repository owner. Do not attach tokens,
OBS settings, or personal recordings to a public issue. Never disable SIP or
Gatekeeper globally to run the app.
