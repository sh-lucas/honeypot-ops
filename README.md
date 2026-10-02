# honeypot-ops: NixOS & Kubernetes Configuration for GitOps and DevSecOps

Este repositório contém a configuração declarativa de infraestrutura para uma VPS Oracle Cloud (ARM64), unindo o gerenciamento declarativo do sistema operacional (**NixOS**) e o orquestrador de containers (**K3s** / Kubernetes) com entrega contínua via **FluxCD**.

---

## Quickstart

Na primeira máquina, restaure a identidade pessoal em `~/.config/sops/age/keys.txt` e entre uma vez no ambiente do projeto caso o `just` e ferramentas auxiliares ainda não estejam instalados:

```sh
nix develop ./nixos
```

Depois disso, a rotina local fica concentrada no `justfile`:

```sh
just                         # lista todos os comandos disponíveis
just check                   # roda todas as validações (linter, SOPS, gitleaks, kustomize, nix) sem deploy
just se CAMINHO.sops.yaml    # edita um secret existente usando micro (recriptografa ao fechar)
just sc CAMINHO.sops.yaml    # cria e edita um secret novo com template seguro
just ds CAMINHO.sops.yaml NOME NAMESPACE # captura secret ativo do cluster e converte em SOPS
just secret-scan             # executa gitleaks no histórico e no conteúdo staged
```

Para criar um Secret Kubernetes, você pode informar nome e namespace diretamente:

```sh
just sc kubernetes/apps/checkup/another.sops.yaml checkup-extra checkup
```

Inclua o novo Secret no `kustomization.yaml` correspondente para que o Flux o aplique. `just ds` preserva tipo e dados do Secret ativo, removendo apenas metadados voláteis do servidor antes de criptografar. O fluxo normal de publicação é sempre Git + Flux. `just us` (upload direto) existe exclusivamente para break-glass emergencial e exige `ALLOW_DIRECT_SECRET_UPLOAD=1`.

O `lefthook.yml` executa o Gitleaks sobre o conteúdo staged antes de cada commit. Rode `lefthook install` uma vez após clonar (o `lefthook` não vem no `nix develop`; instale-o à parte). Linhas criptografadas por SOPS (`ENC[AES256_GCM...]`) são ignoradas, mas plaintext acidental dentro de `*.sops.yaml` é bloqueado.

Depois de validar com `just check`, revise, faça commit e push: o Flux aplica as mudanças no Kubernetes automaticamente. Alterações do sistema operacional do host exigem `just deploy`. `just kubeconfig` baixa o kubeconfig do K3s para `kubernetes/kubeconfig.yaml` (ignorado pelo Git). O [bootstrap inicial do host e do Flux](nixos/secrets/README.md) é feito uma só vez e precisa acontecer antes do primeiro push com secrets SOPS.

---

## 🛠️ Stack Tecnológica

- **NixOS**: Configuração declarativa do sistema via Flakes e particionamento Btrfs via Disko.
- **K3s**: Distribuição leve e otimizada de Kubernetes para rodar as aplicações.
- **FluxCD**: Sincronização automatizada GitOps e automação de atualização de tags de imagem (`ImageUpdateAutomation`).
- **Nginx Router**: Proxy de entrada reverso de alta performance (`hostNetwork`) despachando por header `Host` e terminando TLS.
- **Traefik**: Ingress Controller embutido do K3s, fora do caminho de dados. O entrypoint `websecure` está desligado (`expose: false` em `kubernetes/infra/traefik.yaml`); o rollback exige reverter isso e liberar a 443 do router. Só o hostPort 80 continua publicado, e é dropado no `public-block`/`tailscale-block`.
- **Cloudflare**: Proxy reverso (wildcard `*.sh-lucas.dev`, proxied) + WAF na borda; túnel legado (`cloudflared`) aposentado (`replicas: 0`, rollback).
- **Tailscale**: Malha privada Mesh VPN para acesso administrativo e serviços internos isolados da internet.
- **OpenObserve & OpenTelemetry**: Coleta centralizada de logs, métricas do host/cluster e traces das aplicações com alertas integrados.
- **SOPS + age**: Criptografia de ponta a ponta para secrets em repouso no repositório Git.

---

## 🌐 Arquitetura de Acesso e Rede

Dois grupos de serviços, cada um com seu caminho e nível de isolamento:

- **Público (via Cloudflare)**: `plinth`, `checkup`, `hello-world` — servidos pelo **router** (`kubernetes/apps/router`), nginx operando com `hostNetwork` que despacha por `Host`.
  * **Caminho**: wildcard `*.sh-lucas.dev` → Cloudflare Edge (WAF + TLS) → `443` do host → `iptables REDIRECT` → router `:8443` → pod da aplicação.
- **Privado (Tailscale)**: a cadeia `tailscale-block` aceita só SSH (`22`), DNS (`53`, CoreDNS via socat), `443` (→ router `:8443`) e K3s API (`6443`). `registry` e `observe` só respondem a IPs privados (`allow`/`deny` no nginx do router).

### Defesa em Profundidade na Porta 443

Pela interface pública (`enp0s6`), só pacotes originados de faixas oficiais da Cloudflare alcançam a porta 443 do host:
1. **Borda (Oracle Cloud)**: A Security List / NSG no nível da VCN descarta qualquer tráfego na porta 443 fora da lista de CIDRs da Cloudflare antes de atingir a VM (configurado no console da OCI, fora deste repositório).
2. **Host (NixOS)**: A cadeia `public-block` em `mangle PREROUTING` no [nixos/configuration.nix](nixos/configuration.nix) valida os CIDRs da Cloudflare e dropa qualquer conexão direta no IP de origem do servidor.

**IPv4 apenas.** A `public-block` não tem equivalente em ip6tables, e o `allowedTCPPorts` abre 443/8443 também em IPv6. Hoje a `enp0s6` não tem IPv6 global; se um dia a VCN ganhar IPv6, a origem fica exposta sem o filtro da Cloudflare.

### Contenção de Saída (Egress) das Aplicações

As aplicações públicas rodam com NetworkPolicies de egresso rígidas:
- `plinth` e `checkup`: DNS (`kube-dns`), telemetria para o `otel-collector` (`:4318`) e internet pública, com bloqueio explícito de faixas privadas (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`), isolando o apiserver, a porta 22 do nó, a malha Tailscale e outros serviços internos.
- `hello-world`: apenas DNS.
- `router`: roda com `hostNetwork`, onde NetworkPolicy não vale. O egresso dele é contido pela cadeia `router-egress` (iptables por uid 101) em `nixos/configuration.nix`.

### Custo de CPU e Performance do Ingress

O gargalo da VPS não era throughput bruto de rede, e sim o ciclo de CPU gasto por request em intermediários:
- O Traefik consumia **12,1% do nó** pelo mesmo trabalho onde o nginx consome **4,2%** (2,9x mais eficiente). Profile pprof revelou middlewares ociosos de métricas e alocações excessivas de runtime Go.
- A migração para o router nginx direto (sem túnel cloudflared em userspace) reduziu o custo por request de ~63% para **~11,8% de 1 core por 1000 rps**.
- O benchmark A/B na mesma rota trivial e mesmo backend subiu de **6.778 rps (Traefik)** para **17.381 rps (nginx)**. A medição de 2 hops documentada em `kubernetes/apps/router/configmap.yaml` (wrk -c50 → proxy → plinth) deu 7.696 → 24.515 rps.

---

## 📂 Estrutura do Projeto

```
honeypot-ops/
├── nixos/                       # Configurações do sistema operacional e serviços do host
│   ├── configuration.nix        # Kernel params, firewall iptables, K3s, Tailscale e otimizações BBR
│   ├── flake.nix / flake.lock   # Definição declarativa do Flake e shells de desenvolvimento
│   ├── disko.nix                # Particionamento declarativo de disco Btrfs
│   ├── hardware-configuration.nix # Módulos de kernel e suporte de arquitetura (aarch64)
│   └── secrets/                 # Secrets do host (ex: registries.sops.yaml) e guia de bootstrap
├── kubernetes/                  # Manifestos do cluster reconciliados pelo FluxCD
│   ├── apps/                    # Aplicações (router, plinth, checkup, hello-world, observability, registry, coredns-custom, cloudflare [aposentado])
│   ├── infra/                   # Infraestrutura base do cluster (cert-manager, traefik)
│   ├── flux-system/             # Componentes do Flux, sync e credencial do registry (automações de imagem ficam em apps/checkup e apps/plinth)
│   ├── kustomization.yaml       # Kustomization raiz de entrada do cluster
│   └── sync.yaml                # Definição das Kustomizations de sincronização (infra e apps)
├── secrets/                     # Backups de credenciais protegidos por SOPS (kubeconfig.sops.yaml)
├── .sops.yaml                   # Regras de recipients SOPS/age por caminho
├── .gitleaks.toml               # Allowlist do Gitleaks (linhas ENC[...] do SOPS)
├── AGENTS.md                    # Regras para agentes de IA neste repositório
├── justfile                     # Comandos de automação, validação e deploy
├── about_alerts.md              # Documentação prática para criação de alertas no OpenObserve
├── about.txt                    # Anotações locais de IPs e nó (ignorado pelo Git)
└── lefthook.yml                 # Configuração de hooks git pre-commit (Gitleaks)
```

---

## 🚀 Fluxo de Deployment

- **Alterações no NixOS**: Sistema operacional, firewall e flags do K3s são sincronizados localmente e aplicados na VPS pelo comando `just deploy` (que copia a configuração via SSH e executa `nixos-rebuild switch`).
- **Alterações no Kubernetes**: Deployments, Services, ConfigMaps, Ingresses e Secrets são 100% gerenciados pelo **FluxCD**. Qualquer commit e push na branch `master` deste repositório é detectado em até 1 minuto (polling do `GitRepository`) e aplicado em seguida; as Kustomizations também reconciliam a cada 10 minutos para corrigir drift.
- **Automação Contínua de Imagens**: O Flux inspeciona o registry interno (`registry.sh-lucas.dev`) e um `ImageUpdateAutomation` commita a nova tag no manifesto. O `checkup` segue tags de data (`YYYY.MM.DD--run--sha`, ordem alfabética); o `plinth` segue semver (`vX.Y.Z`).

---

## 🔒 Segurança e Segredos

- **Zero Plaintext no Git**: Todo e qualquer segredo (senhas de banco, JWT, credenciais de container registry, token de API da Cloudflare do cert-manager) é versionado estritamente como arquivo `*.sops.yaml` criptografado via AES256-GCM com chaves Age. Exceção: o token do `cloudflared` aposentado fica fora do repositório.
- **Separação de Chaves**: A chave host (`oracle-host-key.txt`) fica restrita ao nó `/var/lib/sops-nix/key.txt` e ao secret `sops-age` do Flux. A chave pessoal (`keys.txt`) permite recuperação e edição local. Ambas são recipients dos secrets em `kubernetes/` e `nixos/secrets/`; o backup `secrets/kubeconfig.sops.yaml` usa só a pessoal.
- **Anotações de Infraestrutura**: O arquivo [about.txt](about.txt) na raiz guarda IPs e identificadores locais do nó e é ignorado no Git pelo [.gitignore](.gitignore).

---

## 💾 Estado e Backup

Quase tudo é reconstruível a partir do Git. O que não é:

| Estado | Onde fica no host |
|---|---|
| SQLite do `plinth` e do `checkup` | PVCs `local-path` em `/var/lib/rancher/k3s/storage/` |
| Imagens do registry (zot) e dados do OpenObserve | idem |
| Datastore do K3s (SQLite via kine, não etcd) | `/var/lib/rancher/k3s/server/db/state.db` |
| Token, CA e chave do `--secrets-encryption` | `/var/lib/rancher/k3s/server/{token,tls,cred}` |
| Identidades age (pessoal e host) | `~/.config/sops/age/` no computador; host também em `/var/lib/sops-nix/key.txt` |

Os PVCs ficam no mesmo disco da VM. **Hoje não há backup off-site** de nenhum desses itens. Para restaurar um `state.db`, é preciso também o `cred/encryption-config.json`; sem ele, os Secrets ficam ilegíveis. O procedimento das chaves age está em [nixos/secrets/README.md](nixos/secrets/README.md).
