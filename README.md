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
4. Replaces the tarball with the apt-managed `google-cloud-cli` in `/usr/bin`,
   then deletes `~/google-cloud-sdk`.

It is idempotent: existing `gcloud` and an active login are detected and
skipped, so re-run it to repair a half-finished container.

## Why gcloud is installed twice

The tarball is the only kind of `gcloud` a bare container can install: no sudo,
no keyring, no apt repo to add — and adding one needs `gnupg`, which may not be
there yet either. It exists to read the bucket once, and is deliberately never
added to `PATH`.

It is not the copy you want to keep. Step 4 adds Google's apt repo and installs
`google-cloud-cli` into `/usr/bin`, which is what everything downstream expects
and what gets updated along with the rest of the machine, and then removes
`~/google-cloud-sdk`. This used to be left to the `bootstrap` function in the
fetched `.bashrc`; `stage` now does it, so `bootstrap`'s `gcloud` stage finds
the CLI already in place and does nothing.

Step 4 is non-fatal. Without `sudo`, or with apt unreachable, it warns, keeps
the tarball and leaves the job to `bootstrap gcloud`.

Credentials live in `~/.config/gcloud`, a separate directory shared by both
copies, so you log in exactly once and removing the tarball does not log you
out.

## Bucket

Defaults to the stage bucket; pass another as the first argument, or set
`BUCKET`. The name is not sensitive - the bucket is private and IAM gates every
object in it, so knowing the name gets you nothing without an authorised
account. Step 2 is what establishes that.
