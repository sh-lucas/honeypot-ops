# What you can do

Instruct me, verify nixos configurations, and ask for permission for "ssh sudo" and registry commands. You should not try to run any `make deploy` or sudo command since it will block your execution.

## Setups and Objectives

The VPS is deployed at oracle cloud. Public ingress arrives on TCP 443 straight at
the origin IP (`147.15.105.66`), served by the nginx router; Cloudflare still sits in
front as a proxy (wildcard A record, orange cloud) and terminates TLS for clients.
The cloudflared tunnel is being retired -- it cost ~70% of the CPU of the ingress path.
`tailscale0` is the internal mesh and is how `registry`/`observe` are reached.

Pending: restrict TCP 443 on `enp0s6` to Cloudflare's published IP ranges, so the
origin cannot be hit directly by anyone who learns the IP.

Images are already pushed to the private repository and you can pull them with podman when connected to the tailnet. Do not mess with my docker setup.
