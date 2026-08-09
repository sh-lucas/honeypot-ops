# Handoff — custo de CPU do caminho de rede

Estado da investigação de performance de rede do cluster. Sessões de 08/08 e
09/08/2026.

**Conclusão em uma linha:** o caminho de ingresso custava ~63% de um core por
1000 rps e hoje custa **~11,8%**. Os dois ganhos vieram de remover camadas do
caminho do pacote — o túnel Cloudflare e o netns do pod do proxy —, não de tuning.

---

## 1. Método (para os números serem comparáveis)

Tudo que vale nesta página foi medido assim:

- CPU = `user + nice + system + irq + softirq + steal` do `/proc/stat`, ou seja
  **máquina inteira, kernel incluído**;
- **janela ociosa de controle** medida logo antes e subtraída;
- gerador de carga **na outra máquina**, para não contaminar a medição;
- normalizado como **% de 1 core por 1000 rps** = `(µs/req) ÷ 10`;
- app idêntico nas duas máquinas (mesma imagem `plinth`, mesmo endpoint `/`,
  27 bytes de JSON, health que não toca SQLite).

Máquinas: ambas Ampere A1 (Neoverse-N1), 2 OCPU, `sa-saopaulo-1`, mesmo subnet
`10.0.0.0/24`, steal desprezível (0,16% e 0,25%).

- `catnip-cloud` / `oracle` — 10.0.0.91 / 147.15.105.66, NixOS, k3s
- `network-degradation` — 10.0.0.134 / 147.15.91.95, Ubuntu, sem k3s

### Armadilhas de medição, as duas pagas em erro nesta investigação

1. **Gerador no link de casa satura antes do servidor.** 50 VUs contra São Paulo
   travam em ~1.900 rps porque o RTT domina (83 ms só de handshake TLS). Nessa
   faixa o nó está quase ocioso e diferenças de poucos µs/req somem no ruído —
   três configurações de rede diferentes deram o mesmo número. **Sempre gerar da
   VM vizinha**, dentro da VCN, onde se chega a 11-12k rps.
2. **O edge da Cloudflare reusa conexão com o origin.** Contar pacotes em
   `enp0s6` para decidir se o tráfego passa pelo túnel dá resultado invertido:
   o caminho direto com `curl --resolve` em loop refaz handshake a cada request
   (16,6 pacotes/req) e o caminho pelo edge, com keepalive, gasta 4,2. Para
   responder essa pergunta use o contador do próprio cloudflared
   (`cloudflared_tunnel_total_requests` na porta 2000 do pod).

### Instrumentos

Os scripts viveram em scratchpad e não estão no repo, mas são curtos:

- **split por modo de CPU** — lê `user/system/irq/softirq` de `/proc/stat` antes
  e depois de um `wrk` na VM, desconta janela ociosa escalada, divide por request.
  É o instrumento mais estável (três medições dentro de 0,7 ponto) e o único que
  separa processamento de pacote de trabalho de aplicação.
- **contagem de travessias** — delta de `/proc/net/dev` por interface, dividido
  pelo número de requests. `enp0s6` dá 2 pacotes/req (ida e volta), o que serve
  de âncora para normalizar sem depender do output do gerador.
- **decomposição por cgroup** — `usage_usec` dos `cpu.stat` dos pods contra o
  total da máquina. Útil, mas o grosso do custo de rede **não tem dono em
  cgroup**: é softirq. Preferir o split por modo.

`/proc/softirqs` **não serve** para isto: conta eventos, não tempo.

---

## 2. Resultado

### Evolução do caminho de ingresso, mesma rota, mesmo app

| configuração | % de 1 core / 1000 rps |
|---|---:|
| via túnel Cloudflare | ~63% |
| direto na 443, router em pod | 16,0% |
| **direto na 443, router com `hostNetwork`** | **~11,8%** |
| referência: VM sem k3s, nginx `--network host` | 11,9% |

**O cluster alcançou a VM sem k3s.** O que restava de sobrecusto do Kubernetes no
caminho de request era o netns do pod do proxy, e não o CNI, nem NetworkPolicy,
nem kube-proxy.

### Onde a CPU é gasta, por modo

| | antes (`hostNetwork` off) | depois | |
|---|---:|---:|---|
| user | 15,7 µs | 25,8 µs | subiu — ver fio solto 1 |
| system | 49,5 µs | ~49 µs | igual |
| irq | 2,3 µs | 2,1 µs | igual |
| **softirq** | **92,9 µs** | **~40,9 µs** | **−57%** |
| total | 160,4 µs (16,0%) | ~118 µs (11,8%) | |

Medições de confirmação, três rodadas a ~11,2-12,0k rps: 11,3% / 12,0% / 12,0%.

**58% do custo era softirq**, ou seja processamento de pacote no kernel. O `user`,
onde mora a criptografia TLS do nginx, sempre foi pequeno: TLS e a aplicação nunca
foram o problema.

### O mecanismo: travessias de pilha por request

| interface | router em pod | router com `hostNetwork` | VM sem k3s |
|---|---:|---:|---:|
| `enp0s6` | 2,00 | 2,03 | 2,00 |
| `cni0` | 2,03 | 2,03 | — |
| veth do plinth | 2,02 | 2,02 | — |
| **veth do router** | **4,05** | **—** | — |
| `lo` (nginx↔plinth) | — | — | 4,01 |
| **total** | **10,13** | **6,07** | **6,00** |

Um proxy dentro de um pod atravessa o netns **quatro vezes por request**: recebe
do cliente, manda pro upstream, recebe a resposta, devolve. Cada travessia de veth
reexecuta o caminho de recepção inteiro no namespace de destino (`netif_rx` →
softirq NET_RX → camada IP → conntrack → netfilter → NetworkPolicy).

Tirar o proxy do netns do pod elimina as 4,05 e leva o total ao número da VM. O
softirq caiu na proporção. **Previsão registrada antes do teste: 6 travessias e
12,3%. Medido: 6,07 e 11,8%.**

### Por que NIC real custa mais que loopback (normal, não defeito)

- `lo` tem MTU 65536: request e resposta cabem em um skb; sem driver, sem DMA, sem
  interrupção, sem checksum; vai da fila do socket emissor direto para a do
  receptor, com cache quente.
- `enp0s6` tem IRQ → NAPI → softirq, ring buffer do virtio e, por ser VM,
  notificação do virtio que pode custar vmexit.

Corolário prático: **não extrapole medição de loopback para o caminho real.** Foi
exatamente esse erro que fez o svclb parecer caro (ver seção 4).

---

## 3. Estado atual da infra

### Caminho de ingresso

```
internet → Cloudflare (proxy, wildcard A *.sh-lucas.dev → 147.15.105.66)
         → enp0s6:443 → REDIRECT → nginx router (hostNetwork, uid 101) :8443
         → cni0 → veth → pod da aplicação
```

O **cloudflared está em `replicas: 0`** e fora do caminho de dados — confirmado
por contador interno, não por inferência. O deployment segue no repo como
rollback.

DNS na Cloudflare: um wildcard `A *.sh-lucas.dev → 147.15.105.66` proxied atende
tudo. Não existem CNAMEs específicos para as apps; os registros `Tunnel` que
sobraram são `registry` (legado, o acesso real é por Tailscale) e `testing`
(a VM de teste, outro túnel).

### Isolamento

| camada | onde vive | o que garante |
|---|---|---|
| ingresso | `public-block` / `tailscale-block`, mangle PREROUTING, `nixos/configuration.nix` | da internet só entra 443; do tailnet, 22/53/443/6443 |
| egresso do router | `router-egress`, `--uid-owner 101`, mesmo arquivo | só DNS, `:80` das apps, `:5000` registry, `:5080` observe |
| serviços internos | `deny all` por IP de origem no nginx.conf | `registry`/`observe` só de faixa privada |

**NetworkPolicy não se aplica mais ao router** — pod em netns de host não tem veth
para o kube-router avaliar. Os objetos em `apps/router/network.yaml` continuam no
repo, inertes e com aviso no topo, porque voltam a valer sozinhos se alguém tirar
o `hostNetwork` (que é o caminho de rollback).

**Regressão conhecida, aceita:** a `router-egress` filtra por porta na faixa
`10.42.0.0/16`, não por label de pod. O router podia falar com o plinth na 80 e
agora pode falar com qualquer pod na 80. O `nat OUTPUT` roda antes do
`filter OUTPUT`, então o ClusterIP já virou IP de pod quando a regra vê o pacote;
casar por Service ali não é possível.

Verificado funcionando:

| | Tailscale | internet pública |
|---|---|---|
| `plinth` / `hello-world` | — | 200 |
| `registry.sh-lucas.dev` | 401 | **403** |
| `observe.sh-lucas.dev` | 308 | **403** |
| portas 8443 / 8080 cruas | — | **bloqueadas** |

### Detalhes que quebram em silêncio se mexerem

- **`dnsPolicy: ClusterFirstWithHostNet`** é obrigatório com `hostNetwork`. Sem
  isso o pod herda o `resolv.conf` do host (`127.0.0.53`), não resolve os
  `*.svc.cluster.local` dos upstreams, e o nginx **recusa subir** — ele resolve
  upstream no start, não em tempo de request.
- **Probes com `host: 127.0.0.1`**. O kubelet sondaria o IP do nó, e a 8080 hoje
  escuta só no loopback.
- **`allowedTCPPorts = [ 443 8443 ]`.** O REDIRECT acontece em `nat PREROUTING`,
  que roda antes do `filter INPUT`, então o INPUT vê o pacote já traduzido com
  dport 8443. Sem a 8443 ali o tráfego público morre no drop padrão e **só o
  tailnet funciona** — foi exatamente assim que o site caiu por alguns minutos em
  09/08. Não é exposição: a `public-block` roda antes, em mangle, e derruba quem
  bater direto na 8443.
- **`maxSurge: 0`** no router. Duas réplicas não podem disputar a 443 do host.
- Trocar destino em `network.yaml` exige trocar também na cadeia `router-egress`.
  As duas metades divergem em silêncio.

---

## 4. Hipóteses testadas e derrubadas

Registradas porque custaram tempo e porque a intuição erra de novo no mesmo lugar.

- **O hop do klipper-lb (`svclb`) era caro.** Medido em loopback: 19,4 µs/req e
  29% de vazão. **Falso no caminho real.** Removido junto com a Service
  `LoadBalancer`, a contagem de travessias não mudou (10,13 antes e depois) e a
  CPU não se moveu. O klipper-lb do k3s resolve por DNAT no host; o pacote nunca
  atravessava o netns do pod dele. O número de loopback media outra coisa.
- **MTU e encapsulamento eram a causa.** `enp0s6` estava em 1500 com a OCI
  entregando 9000, e `cni0`/`flannel.1` em 1450 num cluster de um nó só, onde
  VXLAN nunca encapsula nada. Os dois eram defeitos reais e foram corrigidos
  (`dhcpV4Config.UseMTU`, `--flannel-backend=host-gw`; `cni0` foi de 1450 para
  9000 e `flannel.1` sumiu). **Sem ganho mensurável** nesta carga — resposta de
  27 bytes não fragmenta em MTU nenhuma. Continuam candidatos para payload
  grande, que é onde a degradação original aparece, e isso segue não medido.
- **NetworkPolicy / firewall interno / CNI.** Inocentes desde a primeira sessão:
  nginx dentro de pod, atravessando netpol, CNI e kube-proxy, foi **mais rápido**
  que o mesmo nginx no loopback do host (78.363 vs 61.688 rps).
- **Os 130,6 µs "sem dono em cgroup" eram um mistério.** Não eram: 58% do custo
  total é softirq, que por definição não aparece em cgroup, e ele escala com
  travessia de netns.

---

## 5. Achados laterais que continuam valendo

- **`limits.cpu: 50m`** em `hello-world` e `checkup` = teto rígido de **452 rps**
  (`nr_throttled=738`, 89,7 s parado). É a causa das "rotas lentas de 1-3k" e não
  tem relação com o caminho de entrada. **Não foi corrigido** — o patch foi
  bloqueado, segue 50m.
- **Soma dos `requests` = 1.575m num nó de 2 cores** (79% comprometido). Pods com
  10m de request ficam com peso residual sob disputa.
- **Traefik vs nginx:** 32,0 vs 6,9 µs/req de CPU de processo na mesma resposta
  trivial, mesmo nó, mesmo netns — **4,6×**. Traefik `/ping` (2 bytes) faz 31.406
  rps, mais lento que o plinth servindo JSON real (40.390 rps).
- **Teto do túnel Cloudflare: ~1.050 rps**, independente de concorrência.
  `keepAliveConnections` 100 → 1000 tirou o colapso em alta concorrência mas não
  moveu o teto. Suspeito: as 4 conexões QUIC com o edge (`connIndex=0..3`).

---

## 6. Fios soltos

1. **O `user` subiu de 15,7 para ~25,8 µs/req** com o `hostNetwork`. Sem TLS novo
   no meio, o mais provável é que parte do que era espera em softirq virou
   trabalho útil do nginx. Não investigado.
2. **Os dois harnesses discordam.** O split por modo dá 11,3-12,0%; o ponta-a-ponta
   somando todos os modos dá 15,2-17,5% nas mesmas condições. O split é mais
   estável e mede a coisa certa, mas a diferença é grande e **não foi
   reconciliada**. Suspeitos: `steal`/`nice` incluídos num e não no outro, e a
   forma de escalar a janela ociosa.
3. **Payload grande nunca foi medido.** É a degradação original relatada, e é o
   único lugar onde MTU 9000 e `host-gw` deveriam aparecer. Teste óbvio: mesmo
   caminho com resposta de ~100 KB, antes e depois de forçar MTU 1500.
4. **Allowlist das faixas da Cloudflare na 443.** Hoje `147.15.105.66:443` aceita
   de qualquer origem; quem descobrir o IP fura o proxy. Decidido, não feito.
5. **Sem TLS nunca foi medido** — separaria o custo de TLS do custo de rede.
6. **A VM de teste `network-degradation` segue de pé**, com sujeira: nix, podman,
   container `plinth` na 9090, nginx, cloudflared como serviço systemd **com o
   token no unit**, CA local no trust store, `/etc/hosts` apontando
   `plinth.sh-lucas.dev` para 10.0.0.91. Ela é o gerador de carga da seção 1 —
   destruir só depois que a investigação fechar. **Rotacionar o token do túnel**,
   que foi colado em chat e gravado no unit.
