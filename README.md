# b300

Bring-up, tuning, pre-flight checks and diagnostics for an NVIDIA DGX B300
(factory DGX OS 7, or plain Ubuntu 24.04 HGX B300).

```bash
curl -sL is.gd/b300sh | sudo bash                  # install + validate
curl -sL is.gd/b300sh | sudo bash -s -- --check    # read-only pre-flight
```

After the first run: `b300-setup --check`, `sudo b300-setup --test`,
`b300-setup -f` (re-attach), `b300-setup -s` (status).

Knobs go on the `sudo` side, e.g. `curl -sL is.gd/b300sh | sudo INSTALL_SGLANG=0 bash`.
See the header of [`install.sh`](install.sh). `index.html` is a byte-identical
copy of `install.sh` so `raghavpillai.github.io/b300` works too.
