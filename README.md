# NixOS & Kubernetes Configuration for GitOps and DevSecOps

Este repositório contém a configuração declarativa de infraestrutura para uma VPS Oracle Cloud (ARM64), unindo o gerenciamento do sistema operacional (NixOS) e o orquestrador de containers (K3s).

---

## Quickstart

Na primeira máquina, restaure a identidade pessoal em
`~/.config/sops/age/keys.txt` e entre uma vez no ambiente do projeto caso o
`just` ainda não esteja instalado:

```sh
nix develop ./nixos
```

Depois disso, a rotina local fica concentrada no `justfile`:

```sh
just                         # lista os comandos
just check                   # valida tudo sem deploy
just se CAMINHO.sops.yaml    # edita um secret existente no micro
just sc CAMINHO.sops.yaml    # cria e edita um secret novo no micro
just ds CAMINHO.sops.yaml NOME NAMESPACE # captura do cluster e criptografa
just secret-scan             # procura credenciais no histórico e no stage
```

Para criar um Secret Kubernetes, você pode informar nome e namespace diretamente:

```sh
just sc kubernetes/apps/checkup/another.sops.yaml checkup-extra checkup
```

Inclua um Secret Kubernetes novo no `kustomization.yaml` correspondente.
`just ds` preserva tipo e dados do Secret ativo, removendo apenas metadados do
servidor antes de criptografar. O fluxo normal de publicação continua sendo Git
+ Flux. `just us` existe somente para break-glass e exige
`ALLOW_DIRECT_SECRET_UPLOAD=1`.

O `lefthook.yml` executa Gitleaks sobre o conteúdo staged antes de cada commit.
Rode `lefthook install` uma vez após clonar. Linhas realmente criptografadas
por SOPS são ignoradas, mas plaintext acidental dentro de `*.sops.yaml` continua
sendo analisado.
Depois de `just check`, revise, faça commit e push: o Flux aplica as mudanças
Kubernetes. Alterações do host exigem `just deploy`, executado pelo operador.
O [bootstrap inicial do host e do Flux](nixos/secrets/README.md) é feito uma só
vez e precisa acontecer antes do primeiro push com secrets SOPS.

---

## 🛠️ O que usamos

- **NixOS**: Configuração declarativa do sistema via Flakes e particionamento Btrfs via Disko.
- **K3s**: Distribuição leve de Kubernetes para rodar as aplicações.
- **FluxCD**: Sincronização automatizada GitOps para os recursos do Kubernetes.
- **Traefik**: Ingress Controller do K3s, hoje só rollback (fora dos caminhos de entrada).
- **Cloudflare**: proxy (wildcard `*.sh-lucas.dev`, proxied) + WAF na frente da `443`; túnel (`cloudflared`) aposentado (`replicas: 0`, rollback).

---

## Arquitetura de Acesso

Dois grupos de serviços, cada um com seu caminho de entrada:

- **Público (via Cloudflare)**: `plinth`, `checkup`, `hello-world` — servidos pelo **router** (`kubernetes/apps/router`), nginx que despacha por `Host`. Entrada: wildcard `*.sh-lucas.dev` → proxied na Cloudflare → `443` do host → REDIRECT → router (hostNetwork) `:8443` → pod.
- **Tailscale**: SSH (`22`), K3s (`6443`) e, no router `:8443` (restrito a IP privado), `registry` e `observe`.

Só IPs da Cloudflare chegam na `443` (`public-block` no `configuration.nix`). App nova = bloco `upstream` + `server` no ConfigMap do router + porta na cadeia `router-egress`.

### Contenção de saída das aplicações

**Egress das apps públicas** (plinth, checkup, hello-world): nega `10/8`, `172.16/12`, `192.168/16`, `100.64/10` — fecha apiserver, nó, Tailscale e demais Services. Permite só DNS (`kube-dns`), `otel-collector` e, para plinth/checkup, a internet (`hello-world` só DNS).

**Não é default-deny:** registry, observe, otel-collector e Traefik não têm policy de egress; pod novo sem NetworkPolicy nasce com acesso total. E a policy é a única camada: `trustedInterfaces = [ "tailscale0" "cni0" "flannel.1" ]` faz o tráfego pod→host pular o firewall do NixOS.

### Custo de CPU do caminho de entrada

O gargalo desta VPS nunca foi throughput bruto: era CPU gasta por request em intermediários. Medido com o benchmark real do plinth (200 workers), como fração do nó de 2 vCPU — com o túnel ainda no caminho:

| bloco | % do nó | fatia |
|---|---|---|
| **aplicação** (`plinth`) | 23,0% | 28% |
| entrada (`cloudflared` 16,1 + softirq 14,6 + `nginx` 4,2) | 34,9% | 42% |
| observabilidade (`otel` 11,1 + `openobserve` 4,1 + `containerd` 5,1) | 20,3% | 24% |
| plataforma (`k3s`, resto) | ~5% | 6% |

O Traefik ocupava **12,1% do nó** nesse mesmo lugar onde o nginx ocupa **4,2%** — 2,9x mais caro pelo mesmo trabalho. A causa foi confirmada por profile de CPU (pprof) sob carga: ~30% do tempo dele era o middleware de métricas mais uma segunda camada de métricas semânticas OTel, ambas sem consumidor no cluster; o resto se divide entre runtime do Go e uma cadeia de ~15 middlewares por request. Em A/B interno, mesma rota e mesmo backend: **6.778 rps via Traefik contra 17.381 via nginx**.

Duas notas de método, para não repetir erros:

- **Vazão medida de fora não serve como métrica desta infra.** As medições variaram até 3x entre execuções com servidor idêntico e ocioso, porque o limite era o link do cliente. O que é reprodutível é CPU por request medida no servidor.
- **A stack de rede do kernel não é o problema.** O caminho interno atravessa as mesmas cadeias de iptables, veth, bridge, conntrack e NetworkPolicy, e faz 32.867 rps com 35µs de kernel por request.

### Caminho de entrada atual: direto, sem `cloudflared`

O `cloudflared` está fora de produção (`replicas: 0`, rollback). O custo por request caiu de ~63% para **~11,8% de 1 core por 1000 rps** — o ganho veio de remover camadas do caminho do pacote (o túnel e o netns do pod do proxy), não de tuning.

```
internet → Cloudflare (wildcard A *.sh-lucas.dev → <IP do servidor>, proxied)
         → enp0s6:443 (só IPs da Cloudflare — public-block)
         → REDIRECT → router nginx (hostNetwork, uid 101) :8443
         → pod da aplicação
```

- TLS agora termina no router (`Certificate` curinga DNS01, cache de sessão no configmap).
- registry/observe: router `:8443`, restrito a origem privada (`deny all` por IP no nginx.conf); Traefik fora (`websecure` desligado, fica como rollback).
- SSH/K3s: só Tailscale.

Comportamento verificado: hello-world/checkup `200`; registry `401` (tailnet) / `403` (internet); observe `308` (tailnet) / `403` (internet); `8443`/`8080` cruas bloqueadas; de dentro de pod: apiserver, `22` do nó e Tailscale bloqueados.

---

## 📂 Estrutura do Projeto

- `nixos/`: Configurações de sistema operacional (`configuration.nix`, `flake.nix`, `disko.nix`, `hardware-configuration.nix`).
- `kubernetes/`: Manifestos do Kubernetes divididos em `apps/` e `flux-system/` para sincronização via FluxCD.
- `justfile`: Interface para secrets, kubeconfig e deploy do NixOS.

---

## 🚀 Fluxo de Deployment

As alterações do **NixOS** (sistema operacional e serviços do host) são copiadas localmente e aplicadas na VPS usando o comando `just deploy`. Já as alterações do **Kubernetes** (deployments, ingresses e secrets dentro da pasta `kubernetes/apps`) são aplicadas de forma totalmente automatizada pelo **FluxCD**: basta commitar e dar push dos manifestos para o GitHub e o cluster reconciliará o estado desejado automaticamente em poucos minutos. Veja o Quickstart acima para os comandos locais.

---

## 🌍 Como deployar em outra VPS

Para rodar esta mesma configuração em qualquer outro provedor ou máquina virtual, o primeiro passo é adaptar o arquivo `nixos/hardware-configuration.nix` com os drivers, módulos de kernel e configurações de boot gerados pelo comando `nixos-generate-config` na máquina alvo. Também será necessário ajustar o particionamento de disco no `nixos/disko.nix` caso o disco principal mude (ex: `/dev/sda` para `/dev/vda`) e atualizar as flags do K3s no `nixos/configuration.nix` com o novo IP de rede do host.

---

## Observações sobre o Repositório Git

- IPs commitados atualmente e anteriormente são da rede privada (tailscale), não IPs públicos.
- Chaves privadas devem permanecer fora do Git. A inspeção dos caminhos no histórico alcançável não é uma garantia de ausência de segredos em todo o histórico.
- O justfile e a estrutura do projeto foram feitos para este ambiente, mas podem ser adaptados para outro provedor ou usuário.


## Chaves e Secrets

Os secrets Kubernetes e a autenticação do registry agora podem ser mantidos
como arquivos SOPS criptografados. O Git contém apenas ciphertext; as chaves
privadas ficam fora da árvore e fora do Nix store. O bootstrap está documentado
em [nixos/secrets/README.md](nixos/secrets/README.md).

O host usa `~/.config/sops/age/oracle-host-key.txt` como identidade age e ela
deve ser instalada manualmente em `/var/lib/sops-nix/key.txt` com permissões
restritas antes do primeiro rebuild. A identidade pessoal em
`~/.config/sops/age/keys.txt` também é recipient dos secrets compartilhados,
permitindo recuperação por qualquer uma das duas chaves. O backup do kubeconfig
em `secrets/kubeconfig.sops.yaml` é exclusivo da chave pessoal. O Secret
`sops-age` e a configuração de descriptografia da Kustomization principal precisam
estar preparados antes de publicar os manifests, conforme o guia de bootstrap.

Arquivos locais legados:

- `.source.sh` não é consumido pelo `justfile`. Se ainda existir numa cópia de
  trabalho antiga, trate-o como material legado e mantenha-o fora do repositório.
- `registries.yaml` era a fonte plaintext da configuração agora versionada como
  `nixos/secrets/registries.sops.yaml`; não participa mais do deploy.
- o acesso SSH ao host usa `~/.ssh/oracle_ed25519`. Os antigos arquivos
  `nixos/ssh-key-2026-07-01.key{,.pub}` eram cópias idênticas dessa chave RSA;
  apesar do nome local, ela não é a Ed25519 usada pelo Git.
- a chave Ed25519 usada pelo Git continua em `~/.ssh/id_ed25519` e não é
  armazenada neste repositório, nem mesmo em formato SOPS.
