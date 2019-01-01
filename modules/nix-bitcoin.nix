{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nix-bitcoin;
  minimalPackages = with pkgs; [
    tor
    bitcoin
    clightning
    nodeinfo
    jq
  ];
  allPackages = with pkgs; [
    liquidd
    lightning-charge.package
    nanopos.package
    spark-wallet.package
    nodejs-8_x
    nginx
  ];
  operatorCopySSH = pkgs.writeText "operator-copy-ssh.sh" ''
    mkdir -p ${config.users.users.operator.home}/.ssh
    if [ -e "${config.users.users.root.home}/.vbox-nixops-client-key" ]; then
      cp ${config.users.users.root.home}/.vbox-nixops-client-key ${config.users.users.operator.home}/.ssh/authorized_keys
    fi
    if [ -e "/etc/ssh/authorized_keys.d/root" ]; then
      cat /etc/ssh/authorized_keys.d/root >> ${config.users.users.operator.home}/.ssh/authorized_keys
    fi
    chown -R operator ${config.users.users.operator.home}/.ssh
  '';
in {
  imports =
    [
      ./bitcoind.nix
      ./clightning.nix
      ./lightning-charge.nix
      ./nanopos.nix
      ./nix-bitcoin-webindex.nix
      ./liquid.nix
      ./spark-wallet.nix
    ];

  options.services.nix-bitcoin = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        If enabled, the nix-bitcoin service will be installed.
      '';
    };
    modules = mkOption {
      type = types.enum [ "minimal" "all" ];
      default = "minimal";
      description = ''
        If enabled, the nix-bitcoin service will be installed.
      '';
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.enable = true;

    # Tor
    services.tor.enable = true;
    services.tor.client.enable = true;

    # Tor SSH service
    services.tor.hiddenServices.sshd = {
      map = [{
        port = 22;
      }];
      version = 3;
    };

    # bitcoind
    services.bitcoind.enable = true;
    services.bitcoind.listen = true;
    services.bitcoind.proxy = config.services.tor.client.socksListenAddress;
    services.bitcoind.port = 8333;
    services.bitcoind.rpcuser = "bitcoinrpc";
    services.bitcoind.extraConfig = ''
      assumevalid=0000000000000000000726d186d6298b5054b9a5c49639752294b322a305d240
      addnode=ecoc5q34tmbq54wl.onion
      discover=0
    '';
    services.bitcoind.prune = 2000;
    services.bitcoind.dbCache = 1000;
    services.tor.hiddenServices.bitcoind = {
      map = [{
        port = config.services.bitcoind.port;
      }];
      version = 3;
    };

    # Add bitcoinrpc group
    users.groups.bitcoinrpc = {};

    # clightning
    services.clightning = {
      enable = true;
      bitcoin-rpcuser = config.services.bitcoind.rpcuser;
    };
    services.tor.hiddenServices.clightning = {
      map = [{
        port = 9375; toPort = 9375;
      }];
      version = 3;
    };

    # Create user operator which can use bitcoin-cli and lightning-cli
    users.users.operator = {
      isNormalUser = true;
      extraGroups = [ "clightning" config.services.bitcoind.group ]
        ++ (if config.services.liquidd.enable then [ config.services.liquidd.group ] else [ ]);

    };
    environment.interactiveShellInit = ''
      alias bitcoin-cli='bitcoin-cli -datadir=${config.services.bitcoind.dataDir}'
      alias lightning-cli='sudo -u clightning lightning-cli --lightning-dir=${config.services.clightning.dataDir}'
    '' + (if config.services.liquidd.enable then ''
      alias liquid-cli='liquid-cli -datadir=${config.services.liquidd.dataDir}'
    '' else "");
    # Unfortunately c-lightning doesn't allow setting the permissions of the rpc socket
    # https://github.com/ElementsProject/lightning/issues/1366
    security.sudo.configFile = ''
      operator    ALL=(clightning) NOPASSWD: ALL
    '';

    # Give root ssh access to the operator account
    systemd.services.copy-root-authorized-keys = {
      description = "Copy root authorized keys";
      wantedBy = [ "multi-user.target" ];
      path  = [ ];
      serviceConfig = {
        ExecStart = "${pkgs.bash}/bin/bash \"${operatorCopySSH}\"";
        user = "root";
        type = "oneshot";
      };
    };

    services.liquidd.enable = cfg.modules == "all";
    services.liquidd.rpcuser = "liquidrpc";
    services.liquidd.prune = 1000;

    services.lightning-charge.enable = cfg.modules == "all";
    services.nanopos.enable = cfg.modules == "all";
    services.nix-bitcoin-webindex.enable = cfg.modules == "all";
    services.clightning.autolisten = cfg.modules == "all";
    services.spark-wallet.enable = cfg.modules == "all";
    services.tor.hiddenServices.spark-wallet = {
      map = [{
        port = 80; toPort = 9737;
      }];
      version = 3;
    };
    environment.systemPackages = if (cfg.modules == "all") then (minimalPackages ++ allPackages) else minimalPackages;
  };
}