# SOPS/age: bootstrap e recuperação

O repositório pode conter arquivos `*.sops.yaml` criptografados, mas nunca uma
chave privada. As identidades já geradas nesta máquina são:

- pessoal: `~/.config/sops/age/keys.txt`;
- host/cluster: `~/.config/sops/age/oracle-host-key.txt`.

A segunda é a identidade configurada no NixOS. O mesmo arquivo precisa ser
instalado no host como `/var/lib/sops-nix/key.txt`, com modo `0600` e dono
`root`; não gere outra chave sem atualizar o recipient e recriptografar os
arquivos. As chaves não têm passphrase criada automaticamente. Proteja os
backups com o mecanismo pessoal existente ou, ao criar uma cópia, use uma
passphrase interativa (`age -p`); nunca coloque passphrases no Git, no Nix
store ou no chat.

O arquivo `registries.sops.yaml` é descriptografado pelo sops-nix e
materializado em `/etc/rancher/k3s/registries.yaml`. Antes do primeiro switch,
instale a chave host no caminho acima e copie o arquivo SOPS junto com o
flake. A rotina de deploy só deve transferir o arquivo criptografado; a
instalação da chave privada é uma etapa manual protegida.

O Flux usa o Secret `sops-age` no namespace `flux-system` para descriptografar
os manifests Kubernetes. Esse Secret deve existir antes da reconciliação dos
arquivos `*.sops.yaml`, criado pelo operador a partir da chave host. Depois
disso, o Flux descriptografa os manifests e aplica Secrets comuns no cluster.
SOPS protege os arquivos no Git; a proteção dos Secrets dentro do cluster
continua dependendo do Kubernetes e do host.

## Primeira ativação

Execute a partir da raiz do repositório. Os passos remotos abaixo são manuais;
não foram executados durante a implementação. Faça backup das duas chaves
antes de continuar. Não publique os manifests antes de preparar o Flux.

1. Envie a chave host e instale-a no VPS (o segundo comando pede sudo):

   ```sh
   scp "$HOME/.config/sops/age/oracle-host-key.txt" lucas@oracle:oracle-host-key.txt
   ssh -t lucas@oracle 'sudo install -d -m 0700 /var/lib/sops-nix && sudo install -m 0600 -o root -g root oracle-host-key.txt /var/lib/sops-nix/key.txt && rm oracle-host-key.txt'
   ```

2. Confirme que o kubeconfig aponta para o cluster Oracle. Crie a chave de
   descriptografia do Flux e configure a Kustomization principal **já existente**:

   ```sh
   export KUBECONFIG="$PWD/kubernetes/kubeconfig.yaml"
   kubectl config current-context
   kubectl -n flux-system create secret generic sops-age \
     --from-file=age.agekey="$HOME/.config/sops/age/oracle-host-key.txt" \
     --dry-run=client -o yaml | kubectl apply --server-side -f -
   kubectl -n flux-system patch kustomization flux-system --type=merge \
     -p '{"spec":{"decryption":{"provider":"sops","secretRef":{"name":"sops-age"}}}}'
   ```

   A saída intermediária contém a chave privada: mantenha o pipe e não use
   `tee` nem tracing de shell. Só criar o Secret não basta: a Kustomization
   principal precisa saber descriptografar antes de ler sua própria atualização.

3. Revise e publique os arquivos criptografados e configurações. Confira
   `kubectl -n flux-system get kustomizations`: `flux-system`, `infra` e `apps`
   devem ficar Ready. Aplique a configuração NixOS pelo fluxo habitual somente
   depois da instalação da chave. `just deploy` copia o arquivo criptografado.

4. No VPS, confira `systemctl status sops-install-secrets k3s` e, com acesso
   administrativo, a existência e permissões do destino de
   `/etc/rancher/k3s/registries.yaml`, sem imprimir seu conteúdo. Valide os apps
   e programe um reboot para confirmar a recuperação. Reboot não foi testado aqui.

Em um cluster novo, restaure o acesso Kubernetes e a credencial Git do Flux
(`flux-system`) antes destes passos. Essa credencial Git não foi encontrada
como fonte local e continua sendo parte do bootstrap externo. O token do
cloudflared aposentado permanece ignorado e fora desta migração.

## Uso no computador e recuperação

O ambiente Nix do projeto fornece `age`, `just`, `micro` e `sops`. A interface
normal não exige entrar no shell nem chamar SOPS diretamente:

```sh
just secret-edit kubernetes/apps/checkup/secret.sops.yaml
just secret-create kubernetes/apps/checkup/another.sops.yaml checkup-extra checkup
just check
```

`just check` valida o justfile, todos os arquivos SOPS, os manifests Kubernetes
e o flake NixOS sem fazer deploy. Para checar apenas a criptografia, use
`just secret-check`. Os aliases curtos são `just se`, `just sc` e
`just secrets-check`. Os dois
primeiros comandos abrem o conteúdo descriptografado no `micro`; ao sair, SOPS
recriptografa e valida o arquivo. Na criação Kubernetes, `name` e `namespace`
são argumentos opcionais; sem eles, vêm do nome do arquivo e do diretório pai.
O comando abre um esqueleto com `stringData` e só grava o arquivo final quando
a edição termina com YAML válido e todos os placeholders `replace-me` foram
substituídos. Inclua o novo arquivo no `kustomization.yaml` correspondente para
que o Flux o aplique.

O caminho é recebido como argumento direto,
precisa terminar em `.sops.yaml`, ficar dentro deste repositório e corresponder
a uma regra de `.sops.yaml`. Para escolher outro editor apenas nessa execução,
use, por exemplo, `SOPS_EDITOR=vim just secret-edit caminho.sops.yaml`.

Os arquivos plaintext antigos continuam ignorados. Não use o editor comum para
abrir o ciphertext: ele contém metadados SOPS e valores criptografados.

O backup `secrets/kubeconfig.sops.yaml` tem apenas o recipient pessoal. Para
restaurá-lo sem abrir permissões de leitura:

```sh
(umask 077; sops decrypt secrets/kubeconfig.sops.yaml > kubernetes/kubeconfig.yaml)
```

Esse comando substitui o kubeconfig local; use outro destino se precisar
preservá-lo. Ele restaura o acesso salvo, não recria um cluster perdido.

Para criar um backup da chave pessoal protegido por senha, escolha um destino
privado fora deste repositório e use `age -p -o DESTINO keys.txt`, informando
o caminho real de `keys.txt`. A senha será solicitada no terminal. Guarde uma
cópia recuperável fora deste computador e teste sua restauração. As chaves
operacionais atuais continuam protegidas pelas permissões do arquivo, sem senha.

Para verificar uma cópia sem exibir o conteúdo:

```sh
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" \
  sops -d nixos/secrets/registries.sops.yaml >/dev/null
```

Nos secrets compartilhados, as duas identidades são recipients válidos (OR): a perda da identidade host
não invalida a recuperação pela identidade pessoal, desde que o backup da
chave pessoal esteja disponível.
