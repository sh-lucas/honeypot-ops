# NixOS & Kubernetes Configuration for GitOps and DevSecOps

Este repositório contém a configuração declarativa de infraestrutura para uma VPS Oracle Cloud (ARM64), unindo o gerenciamento do sistema operacional (NixOS) e o orquestrador de containers (K3s).

---

## 🛠️ O que usamos

- **NixOS**: Configuração declarativa do sistema via Flakes e particionamento Btrfs via Disko.
- **K3s**: Distribuição leve de Kubernetes para rodar as aplicações.
- **FluxCD**: Sincronização automatizada GitOps para os recursos do Kubernetes.
- **Traefik**: Ingress Controller nativo do K3s para gerenciamento de rotas HTTP.
- **Cloudflare Tunnel (cloudflared)**: Conexão segura que expõe as aplicações sem necessidade de abrir portas públicas no firewall da VPS.

---

## Arquitetura de Acesso

Existem dois grupos de serviços, e eles não devem compartilhar o mesmo caminho de entrada:

- **Cloudflare somente**: aplicações públicas autenticadas pelo Cloudflare, como `checkup` e `hello-world`. Seus Ingresses usam exclusivamente o entrypoint Traefik `web` (porta 80 interna), que é o destino do `cloudflared`.
- **Tailscale somente**: SSH, API do K3s e registry. SSH (`22`) e K3s (`6443`) são liberados somente em `tailscale0`; o Ingress do registry usa exclusivamente o entrypoint `websecure` (`443`).

O túnel Cloudflare aponta apenas para `traefik.kube-system.svc.cluster.local:80`. Portanto, ele não consegue alcançar o registry em `websecure`. A porta 80 não é permitida pela interface Tailscale, enquanto a porta 443 é. O firewall da Oracle bloqueia IPv4 e IPv6 externamente, e o firewall do host fornece uma segunda camada.

Não substituir essa separação por allowlists de IP em Middlewares do Traefik. O ServiceLB do K3s pode mascarar o IP de origem antes do Traefik, quebrando acessos legítimos. A fronteira deve continuar sendo os entrypoints `web` e `websecure`.

Comportamento esperado:

- `checkup` e `hello-world` via Cloudflare: sucesso;
- acesso direto às aplicações pela porta 80 da Tailscale: bloqueado;
- registry pela Tailscale: `401 Unauthorized` sem credenciais;
- registry pela Cloudflare: `404 Not Found`;
- SSH e K3s: acessíveis somente pela Tailscale.

---

## 📂 Estrutura do Projeto

- `nixos/`: Configurações de sistema operacional (`configuration.nix`, `flake.nix`, `disko.nix`, `hardware-configuration.nix`).
- `kubernetes/`: Manifestos do Kubernetes divididos em `apps/` e `flux-system/` para sincronização via FluxCD.
- `Makefile`: Atalhos para automação dos comandos de deploy do NixOS.

---

## 🚀 Fluxo de Deployment

As alterações do **NixOS** (sistema operacional e serviços do host) são copiadas localmente e aplicadas na VPS usando o comando `make deploy`. Já as alterações do **Kubernetes** (deployments, ingresses e secrets dentro da pasta `kubernetes/apps`) são aplicadas de forma totalmente automatizada pelo **FluxCD**: basta commitar e dar push dos manifestos para o GitHub e o cluster reconciliará o estado desejado automaticamente em poucos minutos.

---

## 🌍 Como deployar em outra VPS

Para rodar esta mesma configuração em qualquer outro provedor ou máquina virtual, o primeiro passo é adaptar o arquivo `nixos/hardware-configuration.nix` com os drivers, módulos de kernel e configurações de boot gerados pelo comando `nixos-generate-config` na máquina alvo. Também será necessário ajustar o particionamento de disco no `nixos/disko.nix` caso o disco principal mude (ex: `/dev/sda` para `/dev/vda`) e atualizar as flags do K3s no `nixos/configuration.nix` com o novo IP de rede do host.

---

## Observações sobre o Repositório Git

- IPs commitados atualmente e anteriormente são da rede privada (tailscale), não IPs públicos.
- Chaves SSH privadas não foram commitadas nesse repositório. Apenas chaves públicas.
- O makefile e a estrutura do projeto foi feita para mim especificamente, mas pode ser adaptado para ser agnostico de provedor ou usuário.


## Chaves e Secrets

Como você pode perceber, as chaves e secrets estão fora do git, e precisam ser deployados manualmente toda vez que a VPS reiniciar. O ideal é migrar futuramente para sops e criptografar tudo antes de fazer upload para um repositório git privado.
