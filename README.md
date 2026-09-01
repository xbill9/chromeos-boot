# chromeos-boot

Bring a fresh ChromeOS Linux (Crostini) container up from nothing, when the
things you want to install live in a **private** Cloud Storage bucket.

That is a chicken-and-egg problem: reading the bucket needs `gcloud`, and a
bare container has no `gcloud`. This script is the one piece that has to be
fetchable without credentials, so it lives here instead of in the bucket.

## Use

```sh
bash <(curl -sSL https://raw.githubusercontent.com/xbill9/chromeos-boot/main/stage)
```

No `git` required — `curl` is enough, so there is nothing to `apt-get install`
first.

Process substitution rather than a pipe is deliberate. `curl ... | bash` hands
the script to bash on **stdin**, which is the same stdin `gcloud auth login`
needs to read your answers from; the login then fails or silently eats the rest
of the script. `bash <(curl ...)` passes it as a file descriptor instead and
leaves stdin attached to your terminal.

If your shell has no process substitution, download and run in two steps:

```sh
curl -sSL https://raw.githubusercontent.com/xbill9/chromeos-boot/main/stage -o /tmp/stage
bash /tmp/stage
```

## What it does

1. Installs the Google Cloud CLI from the tarball into `$HOME` — **no sudo,
   no apt, no keyring setup**.
2. Logs you in, opening a browser tab. Crostini hands the URL to the ChromeOS
   browser you are already signed into.
3. Copies `nnn` out of the bucket into `~/bin` and runs it, which fetches
   everything else.

It is idempotent: existing `gcloud` and an active login are detected and
skipped, so re-run it to repair a half-finished container.

## Why gcloud goes in $HOME and not on PATH

The tarball install is deliberately never added to `PATH`. It exists only to
read the bucket once. Whatever your `.bashrc` sets up afterwards is free to
install the apt-managed `gcloud` into `/usr/bin` without conflict.

Credentials live in `~/.config/gcloud` and are shared by both copies, so you
log in exactly once. Remove the bootstrap copy with `rm -rf ~/google-cloud-sdk`
once the real one is in place.

## Bucket

Defaults to the stage bucket; pass another as the first argument, or set
`BUCKET`. The name is not sensitive - the bucket is private and IAM gates every
object in it, so knowing the name gets you nothing without an authorised
account. Step 2 is what establishes that.
