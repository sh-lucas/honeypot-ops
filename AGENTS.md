# What you can do

Instruct me, verify nixos configurations, and ask for permission for "ssh sudo" and registry commands. You should not try to run any `just deploy` or sudo command since it will block your execution.

## Setups and Objectives

The VPS is deployed at oracle cloud. Ingress: TCP 443 straight at the origin IP
(`147.15.105.66`), served by the nginx router (`kubernetes/apps/router`, hostNetwork,
REDIRECT to 8443); Cloudflare in front (wildcard A, proxied) terminates TLS. Only
Cloudflare IPs reach the 443 (`cloudflareIPv4` list, mangle chain `public-block` in
`nixos/configuration.nix`).
cloudflared is retired (`replicas: 0`, rollback). `tailscale0` is the mesh;
`registry`/`observe` are served by the router on 8443, private origin only.

Images are already pushed to the private repository and you can pull them with podman when connected to the tailnet. Do not mess with my docker setup.
