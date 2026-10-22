# Loop AGYX em container (Podman + systemd + pi/NVIDIA NIM)

O supervisor autônomo do `agyx-next` rodando dentro de um container Debian 13
(trixie-slim) com **systemd como PID 1**, usando a CLI **pi** (`@earendil-works/pi-coding-agent`)
contra a API **NVIDIA NIM** (modelos gratuitos por tempo limitado). O repositório do
`agyx-next` é montado no container no **mesmo caminho do host**, então todo o estado
do loop (`loop/state/`, `loop/var/`, worktrees do git) fica no seu disco normal —
você acompanha tudo de fora, sem entrar no container.

## Modelos (tier gratuito da NIM)

| Papel | Principal | Fallbacks |
|---|---|---|
| worker (implementa) | `z-ai/glm-5.3-flash` | `z-ai/glm-5.3` → `deepseek-ai/deepseek-v4.1-flash` |
| revisor (só leitura) | `z-ai/glm-5.3` | `glm-5.3-flash` → `deepseek-v4.1-flash` |
| planner (só leitura) | `z-ai/glm-5.3` | `glm-5.3-flash` → `deepseek-v4.1-flash` |

Config em `agyx-next/loop/config.toml` (prefixo `pi/`). Erros de rate limit caem em
cooldown exponencial e passam para o próximo modelo automaticamente. A chave fica
**apenas** em `~/.config/agyx-loop.env` (fora do git, montada ro no container) —
nada de segredo na imagem.

## Arquivos

| Arquivo | O que é |
|---|---|
| `Dockerfile` | trixie-slim + systemd + git/python3/bwrap/rg/just/go 1.27/node 24 + pi 1.2.0 |
| `pi-models.json` | overlay de modelos NIM para o pi (em `/home/agent/.pi/agent/models.json`) |
| `agyxd` | controle: build/up/install-service/logs/journal/tail/once/shell/status |
| `agyx-loop.service` | unidade **dentro** do container (roda `supervisor.py run` como `agent`) |

## Uso

```bash
cd ~/Github/sh-lucas/honeypot-ops/agyx-loop

./agyxd build            # constrói a imagem (podman build)
./agyxd up               # sobe o container com systemd dentro
./agyxd install-service  # unidade systemd do USUÁRIO no host que mantém o container vivo
```

A unidade do host usa `podman generate systemd --new` com `Restart=always` e
`Linger` habilitado: sobe sozinha no boot e se o container cair. Para desligar:

```bash
./agyxd down             # para container e unidade (a tarefa em andamento volta para a fila)
```

## Acompanhamento (do host, sem entrar no container)

```bash
cd ~/Github/rox-projects/agyx/agyx-next
loop/agyx-loop status    # fila, em andamento, falhas
loop/agyx-loop logs      # supervisor.log ao vivo (ou: ~/.../honeypot-ops/agyx-loop/agyxd tail)
loop/agyx-loop show ID   # histórico de uma tarefa
```

`pause` / `resume` / `retry` / `skip` funcionam normalmente: o estado é arquivo no
repositório montado, compartilhado entre host e container.

## Decisões e limitações

- **Podman, não Docker**: o Docker 29.9.1 desta máquina não tem `--systemd` e o
  AppArmor/`userns` do Pop!_OS bloqueia bwrap dentro dele. O Podman tem suporte
  nativo a systemd-em-container (`--systemd=always`) e funciona rootless.
- **uid 1000**: `--userns=keep-id:uid=1000,gid=1000` mantém o usuário `agent` do
  container com o mesmo uid do dono do repositório no host — permissões e git
  funcionam dos dois lados.
- **Sandbox pass-through dentro do container**: o `loop/bin/sandbox` vira um
  executador com env limpa quando `AGYX_CONTAINER=1` (o AppArmor do host nega os
  mounts do bwrap dentro do container). O isolamento real passa a ser o próprio
  container: sem acesso a outros projetos, `~/.ssh`, docker socket ou segredos do
  host (a chave da NIM entra só via env do serviço, como no design original).
- **Cache de build do Go**: `~/go` e `~/.cache/go-build` do host são montados rw —
  `sqlc`/`swag` vêm de `~/go/bin` e o cache de módulos/build é compartilhado.
- **Duas instâncias do loop**: um clone deste repo também roda numa VPS Oracle
  (K3s, via opencode — ver `REMOTE_RUNNER.md` no agyx-next, contém credenciais em
  texto plano; mova-o para fora do repo antes de qualquer push). A `main` local foi
  sincronizada com a remota em 2026-10-22. Se os dois loops rodarem juntos, cada um
  avança na própria cópia — para consolidar depois:
  `git fetch ssh://lucas@oracle:2222/home/lucas/agyx-next main && git rebase oracle/main`.
- O lock do supervisor é `flock` em `loop/var/supervisor.lock` (compartilhado pelo
  mount) — dois supervisores nunca rodam ao mesmo tempo no mesmo repositório.

## Reconstruir do zero

```bash
./agyxd uninstall-service && ./agyxd down
./agyxd build && ./agyxd up && ./agyxd install-service
```

Estado do loop, worktrees e histórico ficam no repositório — nada se perde ao
reconstruir a imagem ou recriar o container.
