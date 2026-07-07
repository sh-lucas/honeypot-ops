.PHONY: deploy copy switch

deploy: copy switch

copy:
	ssh lucas@oracle "mkdir -p /tmp/nixos-config"
	scp nixos/flake.nix nixos/configuration.nix nixos/hardware-configuration.nix nixos/disko.nix nixos/flake.lock lucas@oracle:/tmp/nixos-config/

switch:
	ssh -t lucas@oracle "sudo cp -r /tmp/nixos-config/* /etc/nixos/ && sudo nixos-rebuild switch --flake /etc/nixos#oracle && rm -rf /tmp/nixos-config"

gkcfg:
	ssh lucas@oracle "cat /etc/rancher/k3s/k3s.yaml" > kubernetes/kubeconfig.yaml
	sed -i 's/127.0.0.1/oracle/g' kubernetes/kubeconfig.yaml
	@echo "Kubeconfig baixado e ajustado para o hostname oracle. Use com:"
	@echo 'export KUBECONFIG=$$(pwd)/kubernetes/kubeconfig.yaml'
