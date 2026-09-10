# What you can do

Instruct me, verify nixos configurations, and ask for permission for "ssh sudo" and registry commands. You should not try to run any `just deploy` or sudo command since it will block your execution.
You can ask for further permissions and is intended to help the repository evolve as a self-contained, reproducible deployment. 


## Setups and Objectives

The VPS is deployed at oracle cloud. Ingress: TCP 443 straight at the origin IP, served by the nginx router (`kubernetes/apps/router`, hostNetwork, REDIRECT to 8443); Cloudflare in front (wildcard A, proxied) terminates TLS. Only Cloudflare IPs reach the 443 (`cloudflareIPv4` list, mangle chain `public-block` in `nixos/configuration.nix`).
cloudflared is retired (`replicas: 0`, rollback). `tailscale0` is the mesh; `registry`/`observe` are served by the router on 8443, private origin only.

Images are already pushed to the private repository and you can pull them with podman when connected to the tailnet. Do not mess with my docker setup.


# Instructions

- Keep it clean, for the sake of god: infraestructure is hard, a human HAS to review it, so please, avoid making it harder.
- Do not commit IPs, do not commit passwords, do not let the user commit credentials.
- Follow the fucking script: you shouldn't need 20 files to run a simple deployment, my god, but even then, it's better to follow the current project structure then reinventing the wheel.
- Discuss and rethink, always. 
- Keep the repository useful and direct to use: the simpler the usage cycle, the harder it is to break something. Thats the reason a `just deploy` exists.
