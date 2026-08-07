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

- **Cloudflare somente**: aplicações públicas como `plinth`, `checkup` e `hello-world`. O túnel entrega no **router** (`kubernetes/apps/router`), um nginx estático que despacha por header `Host`.
- **Tailscale somente**: SSH, API do K3s, registry e openobserve. SSH (`22`) e K3s (`6443`) são liberados somente em `tailscale0`; os Ingresses de registry e openobserve usam exclusivamente o entrypoint Traefik `websecure` (`443`), que é onde o Traefik ainda atua.

A rota da Cloudflare é o wildcard `*.sh-lucas.dev`, então o `cloudflared` recebe request de qualquer subdomínio e precisa de alguém que despache por `Host`. Esse alguém é o router. Publicar aplicação nova é adicionar um `upstream` e um `server` no ConfigMap dele, mais uma entrada na allowlist de egress do `cloudflared` — sem tocar no painel.

O `cloudflared` só alcança o router (`8080`) e o Traefik (`8000`), por NetworkPolicy. Essa allowlist é a fronteira do que é publicamente alcançável: expor algo exige editá-la, então falha fechado. O firewall da Oracle bloqueia tudo externamente e o firewall do host é a segunda camada.

Não substituir essa separação por allowlists de IP em Middlewares do Traefik. O ServiceLB do K3s pode mascarar o IP de origem, quebrando acessos legítimos.

### Contenção de saída das aplicações

A separação por entrypoint acima controla **o que o `cloudflared` alcança para dentro**. Ela nunca controlou o que uma aplicação alcança para fora — são eixos diferentes, e por muito tempo o segundo ficou aberto: todas as NetworkPolicies eram `policyTypes: [Ingress]`, então qualquer pod de aplicação alcançava o apiserver, a porta `22` do nó (inclusive pelo IP da Tailscale) e a internet inteira. `registry` e `openobserve` só estavam protegidos pelas próprias policies de ingress.

Cada aplicação agora tem também uma policy de `Egress` no formato da `cloudflared-egress`: nega as faixas privadas em bloco (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`) e libera explicitamente apenas o que precisa — DNS do cluster e `otel-collector`. Isso fecha apiserver, nó, malha Tailscale e todo Service não liberado.

A internet segue aberta para `plinth` e `checkup` (o `checkup` depende dela para sondar alvos externos); `hello-world` só tem DNS. Bloquear a saída para a internet seria proteção contra exfiltração, desejável mas de alto risco de quebrar aplicação — o objetivo aqui é movimento lateral.

Isso importa porque `trustedInterfaces = [ "tailscale0" "cni0" "flannel.1" ]` no `configuration.nix` faz o tráfego pod→host pular o firewall do NixOS por completo. A NetworkPolicy é a única camada capaz de fechar esse caminho.

### Custo de CPU do caminho de entrada

O gargalo desta VPS nunca foi throughput bruto: era CPU gasta por request em intermediários. Medido com o benchmark real do plinth (200 workers), como fração do nó de 2 vCPU:

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

### Opção arquivada: expor direto, sem `cloudflared`

O `cloudflared` custa **16,1% do nó de forma contínua** — é um túnel QUIC com criptografia, não um roteador, então esse custo é o piso da arquitetura atual. Tirá-lo é a única forma de recuperar essa fatia.

Foi montado, medido e revertido. Normalizando por 1.000 rps na mesma rota:

| caminho | nó por 1.000 rps |
|---|---|
| túnel → router | 21,1% |
| **direto, sem Cloudflare** | **15,3%** |
| Cloudflare proxy → origem comum | pior de todos; o edge não empurra além de ~1.200 rps |

**Direto é ~27% mais barato por request.** Não é mais que isso porque o TLS não desaparece, muda de dono: a Cloudflare deixa de terminar e o nginx passa a terminar — barato com cache de sessão, mas não zero. Na carga real isso libera algo entre 11% e 13% da máquina, permanentemente.

A infraestrutura está **dormente e pronta**: o listener TLS na `8443` do router e o `Certificate` curinga (`*.sh-lucas.dev`, emitido por DNS01, que não exige porta aberta) continuam existindo. Para reexpor:

1. recriar um `Service` do tipo `LoadBalancer` em `apps/router/deployment.yaml`, porta `443` → `targetPort: https`;
2. adicionar em `apps/router/network.yaml` uma regra de ingress sem `from` na porta `8443`;
3. em `nixos/configuration.nix`, abrir `443` em **dois** lugares — `allowedTCPPorts` **e** um `ACCEPT` na cadeia `public-block`, que roda antes no `mangle PREROUTING` e descartaria o pacote antes do DNAT do K3s;
4. no Traefik (`infra/traefik.yaml`), `ports.websecure.expose.default: false`, porque o ServiceLB do K3s só admite um dono por porta;
5. na Cloudflare, DNS apontando para o IP público com **proxy desligado**; na Oracle, liberar `443` — de preferência com whitelist de IP.

**Custo:** o passo 4 derruba `registry` e `openobserve` pela Tailscale, e com eles o pull de imagem do containerd e a automação de imagem do Flux. Só faz sentido junto com uma solução alternativa de TLS para esses dois. O commit `c819511` tem a implementação completa e o `d81cec1` a reversão.

Comportamento esperado:

- `checkup` e `hello-world` via Cloudflare: sucesso;
- acesso direto às aplicações pela porta 80 da Tailscale: bloqueado;
- registry pela Tailscale: `401 Unauthorized` sem credenciais;
- registry pela Cloudflare: `404 Not Found`;
- SSH e K3s: acessíveis somente pela Tailscale;
- de dentro de um pod de aplicação: apiserver, `22` do nó e IPs da Tailscale bloqueados.

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
