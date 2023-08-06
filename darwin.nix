# SPDX-FileCopyrightText: 2023 Denbeigh Stevens <https://www.denbeighstevens.com/>
#
# SPDX-License-Identifier: MPL-2.0

self:

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  description = "a daemon that asynchronously copies paths to a remote store";
  cfg = config.services.upload-daemon;
  upload-paths = pkgs.writeShellScript "upload-paths" ''
    nix sign-paths -r -k ${cfg.post-build-hook.secretKey} $OUT_PATHS
    ${pkgs.netcat}/bin/nc -U ${cfg.socket} -N <<< $OUT_PATHS || echo "Uploading failed"
  '';
in
{
  options.services.upload-daemon = with types; {
    enable = mkEnableOption description;
    targets = mkOption {
      description = "List of stores to upload paths to";
      type = listOf str;
    };
    port = mkOption {
      description = "Port to listen for paths to upload";
      type = nullOr port;
      default = null;
    };
    socket = mkOption {
      description = "UNIX socket to listen on";
      type = nullOr path;
      default = "/run/upload-daemon/upload.sock";
    };
    prometheusPort = mkOption {
      description = "Port that prometheus endpoint listens on";
      type = nullOr port;
      default = 8082;
    };
    package = mkOption {
      description = "Package containing upload-daemon";
      type = package;
      default = self.defaultPackage.${pkgs.stdenv.system};
    };
    post-build-hook = {
      enable = mkEnableOption "post-build-hook that uploads the built path to a remote store";
      secretKey = mkOption {
        type = path;
        description = "Path to the key with which to sign the paths";
      };
    };
    workers = mkOption {
      description = "Number of nix-copies to run at the same time, null means use the number of CPUs";
      type = nullOr int;
      default = null;
      example = 4;
    };
    user = mkOption {
      description = "User to run daemon as";
      type = nullOr str;
      default = null;
      example = "upload-daemon";
    };
  };
  config = mkIf cfg.enable {
    users.users.${cfg.user} = {
      uid = 772;
      home = "/Users/${cfg.user}";
      createHome = true;
      description = "Runs the upload-daemon service";
      # daemon group required to write to /run/
      gid = 1;
    };

    users.knownUsers = [ cfg.user ];

    launchd.daemons.upload-daemon = {
      script = ''
        workers=${if cfg.workers == null then "$(nproc)" else toString cfg.workers}

        ${cfg.package}/bin/upload-daemon \
        ${lib.concatMapStringsSep " \\\n" (target: "--target '${target}'") cfg.targets} \
        ${lib.optionalString (! isNull cfg.port) "--port ${toString cfg.port}"} \
        ${lib.optionalString (! isNull cfg.socket) "--unix \"${toString cfg.socket}\""} \
        ${lib.optionalString (! isNull cfg.prometheusPort) "--stat-port ${toString cfg.prometheusPort}"} \
        -j "$workers" \
        +RTS -N"$workers"
      '';
      serviceConfig = {
        UserName = cfg.user;
        GroupName = "daemon";
        KeepAlive = true;
        StandardOutPath = "/Users/${cfg.user}/log.out";
        StandardErrorPath = "/Users/${cfg.user}/log.err";
        WorkingDirectory = "/Users/${cfg.user}";
      };
    };
    nix.extraOptions = lib.optionalString cfg.post-build-hook.enable "post-build-hook = ${upload-paths}";
  };
}
