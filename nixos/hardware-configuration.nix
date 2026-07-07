{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "virtio_pci" "virtio_scsi" "usbhid" "usb_storage" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # Grub or systemd-boot. Let's use systemd-boot since UEFI is enabled.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Oracle VM serial console setup
  boot.kernelParams = [ "console=tty1" "console=ttyAMA0" ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
