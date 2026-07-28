{
  description = "Wallstats macOS runtime and development tools";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      for_all_systems = nixpkgs.lib.genAttrs systems;
      # nixpkgs 0.6.1 predates M5 support and crashes before producing a sample.
      macmon_overlay = final: previous: {
        macmon =
          let
            source = final.fetchFromGitHub {
              owner = "vladkens";
              repo = "macmon";
              tag = "v0.8.0";
              hash = "sha256-9UD/PXmMln5RiUQXjp2GV3m1R2IQ5ItvoOfpkqGNg/I=";
            };
          in
          previous.macmon.overrideAttrs (_: {
            version = "0.8.0";
            src = source;
            cargoDeps = final.rustPlatform.fetchCargoVendor {
              src = source;
              hash = "sha256-hgZiXMvQwXDyEh0yVAftJEDk9i2e+Drgq11q9ze/mUc=";
            };
          });
      };
      packages_for = system: import nixpkgs {
        inherit system;
        overlays = [ macmon_overlay ];
      };
    in
    {
      packages = for_all_systems (system:
        let
          pkgs = packages_for system;
          runtime_path = pkgs.lib.makeBinPath ([
            pkgs.rust-script
            pkgs.cargo
            pkgs.rustc
            pkgs.stdenv.cc
            pkgs.stdenv.cc.bintools
            pkgs.bash
            pkgs.coreutils
            pkgs.findutils
            pkgs.gawk
            pkgs.gitMinimal
            pkgs.gnugrep
            pkgs.gnumake
            pkgs.gnused
            pkgs.libiconv
            pkgs.pkg-config
          ] ++ pkgs.lib.optionals (system == "aarch64-darwin") [
            pkgs.macmon
          ]);
          wrapper_source = pkgs.writeText "wallstats-rust-script.c" ''
            #include <errno.h>
            #include <stdio.h>
            #include <stdlib.h>
            #include <string.h>
            #include <sys/types.h>
            #include <unistd.h>

            struct environment_entry {
                const char *name;
                const char *value;
            };

            int main(int argc, char **argv) {
                (void)argc;

                static const char rust_script[] = "${pkgs.rust-script}/bin/rust-script";
                static const struct environment_entry environment[] = {
                    { "PATH", "${runtime_path}:/usr/bin:/bin:/usr/sbin:/sbin" },
                    { "SHELL", "${pkgs.bash}/bin/bash" },
                    { "CARGO", "${pkgs.cargo}/bin/cargo" },
                    { "RUSTC", "${pkgs.rustc}/bin/rustc" },
                    { "RUSTDOC", "${pkgs.rustc}/bin/rustdoc" },
                    { "CC", "${pkgs.stdenv.cc}/bin/cc" },
                    { "CXX", "${pkgs.stdenv.cc}/bin/c++" },
                    { "LD", "${pkgs.stdenv.cc.bintools}/bin/ld" },
                    { "AR", "${pkgs.stdenv.cc.bintools}/bin/ar" },
                    { "RANLIB", "${pkgs.stdenv.cc.bintools}/bin/ranlib" },
                    { "PKG_CONFIG", "${pkgs.pkg-config}/bin/pkg-config" },
                    { "LIBRARY_PATH", "${pkgs.libiconv}/lib" },
                    { "NIX_LDFLAGS", "-L${pkgs.libiconv}/lib" },
                    { "CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER", "${pkgs.stdenv.cc}/bin/cc" },
                    { "CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER", "${pkgs.stdenv.cc}/bin/cc" },
                    { "SSL_CERT_FILE", "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" },
                    { "GIT_SSL_CAINFO", "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" },
                    { "CARGO_HTTP_CAINFO", "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" },
                };

                for (size_t index = 0; index < sizeof(environment) / sizeof(environment[0]); index++) {
                    if (setenv(environment[index].name, environment[index].value, 1) != 0) {
                        fprintf(stderr, "wallstats-rust-script: cannot set %s: %s\n",
                                environment[index].name, strerror(errno));
                        return 126;
                    }
                }

                if (setpgid(0, 0) != 0) {
                    const int error = errno;
                    if (getpgrp() != getpid()) {
                        fprintf(stderr, "wallstats-rust-script: cannot establish process group: %s\n",
                                strerror(error));
                        return 126;
                    }
                }

                execv(rust_script, argv);
                const int error = errno;
                fprintf(stderr, "wallstats-rust-script: cannot execute %s: %s\n",
                        rust_script, strerror(error));
                return error == ENOENT ? 127 : 126;
            }
          '';
          runtime = pkgs.runCommandCC "wallstats-runtime-0.1.0" { } ''
            mkdir -p "$out/bin"
            "$CC" -O2 -Wall -Wextra -Werror \
              ${wrapper_source} \
              -o "$out/bin/wallstats-rust-script"
          '';
        in
        {
          inherit runtime;
          xcodegen = pkgs.xcodegen;
          default = runtime;
        });

      devShells = for_all_systems (system:
        let
          pkgs = packages_for system;
          development_tools = [
            pkgs.cargo
            pkgs.clippy
            pkgs.rust-script
            pkgs.rustc
            pkgs.rustfmt
            pkgs.xcodegen
          ] ++ pkgs.lib.optionals (system == "aarch64-darwin") [
            pkgs.macmon
          ];
        in
        {
          default = pkgs.mkShell {
            packages = development_tools;
            shellHook = ''
              case "''${DEVELOPER_DIR-}" in
                /nix/store/*) unset DEVELOPER_DIR ;;
              esac
              case "''${SDKROOT-}" in
                /nix/store/*) unset SDKROOT ;;
              esac
              export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${pkgs.lib.makeBinPath development_tools}:$PATH"
            '';
          };
        });
    };
}
