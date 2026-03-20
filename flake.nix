{
  description = "Choir - MoonBit agent orchestration server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        moonbitBinary =
          {
            x86_64-linux = {
              url = "https://cli.moonbitlang.com/binaries/latest/moonbit-linux-x86_64.tar.gz";
              hash = "sha256-EUkAeuLqL4GZOq2OAR2qFRjbOz5Mg4+5OWh0++QIZq4=";
            };
            aarch64-darwin = {
              url = "https://cli.moonbitlang.com/binaries/latest/moonbit-darwin-aarch64.tar.gz";
              hash = "sha256-HVfJDlZjBWqIB2Vfmum96TSqblJKyOAEarCTgxP/6KI=";
            };
          }
          .${system};

        moonbitTarball = pkgs.fetchurl {
          url = moonbitBinary.url;
          hash = moonbitBinary.hash;
        };

        coreTarball = pkgs.fetchurl {
          url = "https://cli.moonbitlang.com/cores/core-latest.tar.gz";
          hash = "sha256-uBzb9dpP+vSIaj+ifL52wLTLxgQNMfJJ+Zp5ENAstlo=";
        };

        asyncSrc = pkgs.fetchFromGitHub {
          owner = "moonbitlang";
          repo = "async";
          rev = "v0.4.0";
          hash = "sha256-aaxBSny1TSyuFBSrnqBpohAiD4pleW4GEakcaVTah/c=";
        };

        moonbitToolchain = pkgs.stdenvNoCC.mkDerivation {
          pname = "moonbit-toolchain";
          version = "latest";
          dontUnpack = true;
          nativeBuildInputs = [
            pkgs.gnutar
            pkgs.patchelf
          ];
          installPhase = ''
            runHook preInstall

            mkdir -p "$out/lib"
            tar xf ${moonbitTarball} --directory="$out"
            tar xf ${coreTarball} --directory="$out/lib"

            if [ -d "$out/bin" ]; then
              find "$out/bin" -type f -exec chmod +x {} +
            fi
            if [ -f "$out/bin/internal/tcc" ]; then
              chmod +x "$out/bin/internal/tcc"
            fi

            moon_rpath="${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}"
            moon_interp="${pkgs.stdenv.cc.bintools.dynamicLinker}"

            for exe in \
              "$out/bin/moon" \
              "$out/bin/moondoc" \
              "$out/bin/moonc" \
              "$out/bin/moon-ide" \
              "$out/bin/moonrun" \
              "$out/bin/moonbit-lsp" \
              "$out/bin/mooninfo" \
              "$out/bin/mooncake" \
              "$out/bin/moonfmt" \
              "$out/bin/moon_cove_report" \
              "$out/bin/moon-wasm-opt" \
              "$out/bin/internal/tcc"
            do
              if [ -f "$exe" ]; then
                patchelf --set-interpreter "$moon_interp" --set-rpath "$moon_rpath" "$exe" || true
              fi
            done

            runHook postInstall
          '';
        };

      in
      {
        packages = {
          moonbit-toolchain = moonbitToolchain;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            moonbitToolchain
            pkgs.clang
            pkgs.pkg-config
            pkgs.libuv
            pkgs.openssl
            pkgs.git
            pkgs.gh
            pkgs.tmux
            pkgs.zellij
            pkgs.watchexec
            pkgs.entr
          ];

          shellHook = ''
            local_moon_home="$PWD/.nix-moon"
            if [ ! -d "$local_moon_home/bin" ]; then
              cp -R ${moonbitToolchain} "$local_moon_home"
              chmod -R u+w "$local_moon_home" || true
            fi
            export PATH="$local_moon_home/bin:$PATH"
            export MOON_HOME="$local_moon_home"
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [
              pkgs.openssl
              pkgs.libuv
              pkgs.stdenv.cc.cc.lib
            ]}:''${LD_LIBRARY_PATH:-}"
            mkdir -p .mooncakes/moonbitlang
            if [ ! -e .mooncakes/moonbitlang/async ]; then
              cp -R ${asyncSrc} .mooncakes/moonbitlang/async
              chmod -R u+w .mooncakes/moonbitlang/async || true
            fi
            touch .mooncakes/.moon-lock
            if [ ! -e "$local_moon_home/lib/core/_build/native/release/bundle/prelude/prelude.mi" ]; then
              moon -C "$local_moon_home/lib/core" bundle --warn-list -a --all
              moon -C "$local_moon_home/lib/core" bundle --warn-list -a --target wasm-gc --quiet
            fi
            moon update >/dev/null 2>&1 || true
            echo "Choir dev shell"
            echo "Open-source runtime deps are available."
            echo "Install proprietary agent CLIs separately: claude, gemini, moon pilot."
          '';
        };
      }
    );
}
