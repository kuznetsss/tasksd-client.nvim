---The tasksd release this client is built against. Everything that has to move
---when that release moves lives here, so a bump touches one file.
local M = {}

M.REPO_URL = "https://github.com/kuznetsss/tasksd"

---Bump together with `M.MIN_VERSION`; the test suite asserts this is never
---older.
M.VERSION = "0.2.0"

---The oldest daemon this client can talk to, whoever supplied it. Here rather
---than in `tasksd.client` because `tasksd.daemon` needs it too, and client.lua
---already requires daemon.lua -- reaching back would close a require cycle.
---Bump it when this client starts relying on a newer daemon feature.
M.MIN_VERSION = "0.2.0"

---The commit `VERSION` was tagged at. Given `--tag` and `--rev` together cargo
---silently ignores the rev, so `cargo.argv` passes only `--rev` and
---`install.verify` checks the result against `VERSION`.
M.REV = "322c09dde5fea179e7e40750f1be2ed8e7e37db2"

---What GitHub reports as each release asset's digest, keyed by target. Pinned
---rather than read from the API during an install: a digest served by the same
---host as the asset only proves the download was not truncated, and GitHub
---leaves release assets replaceable after publication.
M.SHA256 = {
  ["x86_64-unknown-linux-gnu"] = "5fdcf76046c86c1cbf1b2299d0bc749257cc9052a57a017b8dd7d8a9fd5b3cc6",
  ["aarch64-unknown-linux-gnu"] = "915ab4f99c8575ac16722c403a40126f5d8c27a0058e0b3c608dc4ce759a39ea",
}

return M
