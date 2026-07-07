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
