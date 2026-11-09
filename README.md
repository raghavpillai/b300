# b300

One-command bring-up, tuning, and validation for an NVIDIA DGX/HGX B300 node
(DGX OS 7 or plain Ubuntu 24.04).

```bash
curl -fsSL raghavpillai.github.io/b300 | sudo bash
```

Knobs go on the `sudo` side, e.g. `curl -fsSL raghavpillai.github.io/b300 | sudo INSTALL_SGLANG=0 bash`.
See the header of [`install.sh`](install.sh) for every option. `index.html` is a
byte-identical copy of `install.sh` so the short URL works.

After it starts: `b300-setup -f` re-attaches to the log, `sudo b300-setup --test`
re-runs validation, `b300-setup -s` shows status.
