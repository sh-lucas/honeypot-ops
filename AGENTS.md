# What you can do

Instruct me, verify nixos configurations, and ask for permission for "ssh sudo" and registry commands. You should not try to run any `make deploy` or sudo command since it will block your execution.

## Setups and Objectives

This project is meant to be a semi-zero-trust infraestructure implementation; that's why no public ip and ports are exposed. All comunication and auth is double-checked (tailscale and cloudflare only exposes authenticated services for example).

The VPS is deployed at oracle cloud, there is a cloudflared tunnel for all ingress and a tailscale0 for internal mesh; do not mess with this networking, cloudflare already does all TLS you may need to deploy simple applications (see 'hello-world' service example).

Images are already pushed to the private repository and you can pull them with podman when connected to the tailnet. Do not mess with my docker setup.
